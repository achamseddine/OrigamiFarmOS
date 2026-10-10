"""Medicine & farm pharmacy management (database/MEDICINE-PHARMACY-SCHEMA.md,
database/MEDICINE-NOTIFICATION-RULES.md).

What the farm owns, in which lot, until when, what is *eligible* to use,
what must always be kept, and when to reorder — maintained even when no
animal is sick. Inventory stays the ledger: a medicine lot's on-hand
moves only with a posted `inventory_transactions` row, and eligibility
is computed from lot facts on read:

    eligible = on hand − quarantined − blocked − recalled − expired
               − storage-noncompliant − past its after-opening use-by

Stock alerts are logistics findings, never treatment advice: "fever
support stock low" means the configured product is below the farm's own
policy. Stocking a medicine never authorises its use; an administration
is bound to a prescription (treatment) or an approved protocol step when
the product requires one, consumes the exact lot, applies the product's
authorised withdrawal rule and re-evaluates the thresholds at once.
"""
from __future__ import annotations

import math
from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core import permissions as perms
from app.domain import models
from app.domain import pharmacy_models as pm
from app.feeding import uom
from app.repositories.base import ensure_utc, new_id, now, write_event
from app.services import feeding_program_service as programs
from app.services.feed_inventory_service import FeedError


class PharmacyError(FeedError):
    """A pharmacy rule refused the operation; answered like a feed rule."""


CATEGORIES = (
    ("FEVER_SUPPORT", "Fever support", "دعم الحمّى"), ("PAIN_INFLAMMATION", "Pain & inflammation", "الألم والالتهاب"),
    ("COLIC_SUPPORT", "Colic support", "دعم المغص"), ("IV_FLUID", "IV fluids", "سوائل وريدية"), ("ELECTROLYTE", "Electrolytes", "إلكتروليتات"),
    ("ANTIBIOTIC", "Antibiotics", "مضادات حيوية"), ("ANTIPARASITIC", "Antiparasitics", "مضادات الطفيليات"), ("VACCINE", "Vaccines", "لقاحات"),
    ("WOUND_CARE", "Wound care", "العناية بالجروح"), ("OTHER", "Other", "أخرى"),
)
INGREDIENTS = (
    ("oxytetracycline", "Oxytetracycline"), ("flunixin_meglumine", "Flunixin meglumine"), ("sodium_chloride", "Sodium chloride"),
    ("ivermectin", "Ivermectin"), ("penicillin_g", "Penicillin G"), ("dextrose", "Dextrose"), ("calcium_borogluconate", "Calcium borogluconate"),
    ("meloxicam", "Meloxicam"), ("clostridial_toxoid", "Clostridial toxoid"), ("glucose_electrolyte", "Glucose / electrolyte"),
)
ADJUSTMENT_REASONS = ("adjustment", "waste", "return", "count_correction", "transfer")
SEVERITY = {
    "OUT_OF_STOCK": "critical", "CRITICAL_STOCK": "high", "BELOW_MINIMUM_STOCK": "medium", "LOW_DAYS_COVER": "medium",
    "EXPIRED_STOCK": "medium", "EXPIRING_SOON": "low", "RECALL_AFFECTED": "high", "STORAGE_EXCEPTION": "high",
}
EVENT_FOR_ALERT = {
    "OUT_OF_STOCK": "medicine_out_of_stock", "CRITICAL_STOCK": "medicine_stock_critical", "BELOW_MINIMUM_STOCK": "medicine_stock_below_minimum",
    "LOW_DAYS_COVER": "medicine_stock_below_minimum", "EXPIRED_STOCK": "medicine_expired", "EXPIRING_SOON": "medicine_expiring_soon",
    "RECALL_AFFECTED": "medicine_recall_affected", "STORAGE_EXCEPTION": "medicine_storage_exception_detected",
}
SAFETY = "A stock alert is a logistics finding against the farm's own policy, not treatment advice."


# ------------------------------------------------------------ reference
def ensure_pharmacy_reference_data(db: Session) -> None:
    have = {c.code for c in db.scalars(select(pm.MedicineCategory))}
    for code, name, name_ar in CATEGORIES:
        if code not in have:
            db.add(pm.MedicineCategory(id=new_id(), code=code, name=name, name_ar=name_ar, active=True))
    have_i = {i.code for i in db.scalars(select(pm.MedicineActiveIngredient))}
    for code, name in INGREDIENTS:
        if code not in have_i:
            db.add(pm.MedicineActiveIngredient(id=new_id(), code=code, name=name, active=True))
    db.flush()


def category_by_code(db: Session, code: str) -> pm.MedicineCategory:
    row = db.scalar(select(pm.MedicineCategory).where(pm.MedicineCategory.code == code.upper()))
    if row is None:
        raise PharmacyError(f"Unknown medicine category '{code}'")
    return row


def ingredient_by_code(db: Session, code: str, name: str | None = None) -> pm.MedicineActiveIngredient:
    key = code.strip().lower().replace(" ", "_")
    row = db.scalar(select(pm.MedicineActiveIngredient).where(pm.MedicineActiveIngredient.code == key))
    if row is None:
        row = pm.MedicineActiveIngredient(id=new_id(), code=key, name=name or code, active=True)
        db.add(row)
        db.flush()
    return row


# -------------------------------------------------------------- products
def get_product(db: Session, item_id: str, farm_id: str) -> pm.MedicineProduct:
    p = db.get(pm.MedicineProduct, item_id)
    if p is None or p.farm_id != farm_id:
        raise PharmacyError("Medicine not found", 404)
    return p


def item_of(db: Session, product: pm.MedicineProduct) -> models.InventoryItem:
    item = db.get(models.InventoryItem, product.inventory_item_id)
    if item is None:
        raise PharmacyError("The medicine's inventory item no longer exists", 404)
    return item


def _apply_product_fields(db: Session, product: pm.MedicineProduct, fields: dict) -> None:
    simple = {
        "generic_name", "brand_name", "dosage_form", "strength_value", "strength_uom", "strength_basis", "administration_routes",
        "prescription_required", "antimicrobial", "controlled_medicine", "cold_chain_required", "storage_min_c", "storage_max_c",
        "opened_shelf_life_days", "default_pack_size", "pack_uom", "manufacturer_name", "authorization_reference", "species_codes",
        "lot_tracking_exception", "active",
    }
    for k, v in fields.items():
        if k in simple and v is not None:
            setattr(product, k, v)
    if fields.get("withdrawal_rules") is not None:
        rules = fields["withdrawal_rules"]
        for key in ("milk_days", "meat_days", "egg_days"):
            if key in rules and (rules[key] is None or float(rules[key]) < 0):
                raise PharmacyError(f"withdrawal_rules.{key} must be zero or more days")
        product.withdrawal_rules_json = rules
    if product.dosage_form not in pm.DOSAGE_FORMS:
        raise PharmacyError(f"dosage_form must be one of {list(pm.DOSAGE_FORMS)}")
    for r in product.administration_routes or []:
        if r not in pm.ROUTES:
            raise PharmacyError(f"administration route '{r}' must be one of {list(pm.ROUTES)}")
    if fields.get("category_codes") is not None:
        product.categories.clear()
        for code in fields["category_codes"]:
            product.categories.append(pm.MedicineProductCategory(category_id=category_by_code(db, code).id))
    if fields.get("ingredients") is not None:
        product.ingredients.clear()
        for ing in fields["ingredients"]:
            ing = ing if isinstance(ing, dict) else ing.model_dump()
            row = ingredient_by_code(db, ing["code"], ing.get("name"))
            product.ingredients.append(pm.MedicineProductIngredient(
                active_ingredient_id=row.id, concentration_value=ing.get("concentration_value"),
                concentration_uom=ing.get("concentration_uom"), concentration_basis=ing.get("concentration_basis"),
            ))


def create_product(db: Session, farm_id: str, *, inventory_item_id: str | None = None, name: str | None = None, unit: str | None = None,
                   supplier_label: str | None = None, unit_cost: float | None = None, user_id: str, **fields) -> pm.MedicineProduct:
    """A medicine the farm stocks (§2): over an existing inventory item or
    a new one. The item is the stock truth; this row adds what the
    medicine is and how it must be handled."""
    if inventory_item_id:
        item = db.get(models.InventoryItem, inventory_item_id)
        if item is None or item.farm_id != farm_id:
            raise PharmacyError("Inventory item not found", 404)
        if db.get(pm.MedicineProduct, item.id) is not None:
            raise PharmacyError("This inventory item is already a medicine product")
        if name:
            item.name = name
        item.category = "medicine"
    else:
        if not name or not name.strip():
            raise PharmacyError("A medicine needs a name")
        item = models.InventoryItem(id=new_id(), farm_id=farm_id, name=name.strip(), category="medicine", unit=unit or "items",
                                    current_qty=0, reorder_level=0, supplier_label=supplier_label, unit_cost=unit_cost)
        db.add(item)
        db.flush()
    product = pm.MedicineProduct(inventory_item_id=item.id, farm_id=farm_id, created_by=user_id, created_at=now(), updated_at=now())
    db.add(product)
    _apply_product_fields(db, product, fields)
    db.flush()
    write_event(db, farm_id=farm_id, entity_type="medicine_product", entity_id=product.inventory_item_id, event_type="medicine_product_configured",
                payload={"name": item.name, "dosage_form": product.dosage_form, "prescription_required": product.prescription_required,
                         "categories": [c.category.code for c in product.categories]}, created_by=user_id)
    return product


def update_product(db: Session, product: pm.MedicineProduct, changes: dict, *, user_id: str) -> pm.MedicineProduct:
    _apply_product_fields(db, product, changes)
    product.updated_at = now()
    db.flush()
    write_event(db, farm_id=product.farm_id, entity_type="medicine_product", entity_id=product.inventory_item_id, event_type="medicine_product_configured",
                payload={"changed": sorted(k for k, v in changes.items() if v is not None)}, created_by=user_id)
    return product


# ------------------------------------------------------------------ lots
def get_lot(db: Session, lot_id: str, farm_id: str) -> pm.InventoryLot:
    lot = db.get(pm.InventoryLot, lot_id)
    if lot is None or lot.farm_id != farm_id:
        raise PharmacyError("Lot not found", 404)
    return lot


def _detail(lot: pm.InventoryLot) -> pm.MedicineLotDetail:
    if lot.medicine is None:
        lot.medicine = pm.MedicineLotDetail(storage_status="COMPLIANT", cold_chain_exception=False)
    return lot.medicine


def lot_expired(lot: pm.InventoryLot, at: datetime | None = None) -> bool:
    at = at or now()
    if lot.expiry_date is not None and ensure_utc(lot.expiry_date) <= at:
        return True
    d = lot.medicine
    return d is not None and d.use_by_after_opening is not None and ensure_utc(d.use_by_after_opening) <= at


def refresh_lot_status(lot: pm.InventoryLot, at: datetime | None = None) -> None:
    """Expiry and depletion are facts, reflected on read (as feed lots do),
    so a lot that expired overnight is ineligible this morning untouched."""
    if lot.status == "active" and lot_expired(lot, at):
        lot.status = "expired"
    elif lot.status == "active" and lot.quantity_on_hand <= 0.0005:
        lot.status = "depleted"
    elif lot.status == "depleted" and lot.quantity_on_hand > 0.0005:
        lot.status = "active"


def ineligibility(lot: pm.InventoryLot, at: datetime | None = None) -> str | None:
    """Why this lot does not count (§7), or None when it is eligible."""
    refresh_lot_status(lot, at)
    if lot.status in ("quarantined", "blocked", "recalled", "expired"):
        return lot.status
    if lot.status == "depleted" or lot.quantity_on_hand <= 0:
        return "depleted"
    d = lot.medicine
    if d is not None:
        if d.storage_status != "COMPLIANT":
            return "storage_exception"
        if d.cold_chain_exception:
            return "cold_chain_exception"
    return None


def _unique_lot_code(db: Session, item_id: str, base: str) -> str:
    code, n = base, 2
    while db.scalar(select(pm.InventoryLot.id).where(pm.InventoryLot.inventory_item_id == item_id, pm.InventoryLot.lot_code == code)):
        code = f"{base}-{n}"
        n += 1
    return code


def receive_lot(db: Session, product: pm.MedicineProduct, *, quantity: float, unit: str | None = None, lot_code: str | None = None,
                expiry_date: datetime | None = None, unit_cost: float | None = None, supplier_id: str | None = None, supplier_label: str | None = None,
                location_id: str | None = None, rejected_quantity: float = 0, source_type: str = "purchased", reference: str | None = None,
                notes: str | None = None, received_at: datetime | None = None, storage_status: str = "COMPLIANT", cold_chain_exception: bool = False,
                user_id: str) -> pm.InventoryLot:
    """Goods receipt: each receipt records the medicine lot and expiry
    (acceptance 2) unless the product carries a recorded exception."""
    item = item_of(db, product)
    if quantity <= 0:
        raise PharmacyError("Received quantity must be greater than zero.")
    if rejected_quantity < 0 or rejected_quantity > quantity:
        raise PharmacyError("Rejected quantity must be between zero and the received quantity.")
    if not product.lot_tracking_exception:
        if not lot_code or not lot_code.strip():
            raise PharmacyError("A medicine receipt must record the manufacturer's lot number.")
        if expiry_date is None:
            raise PharmacyError("A medicine receipt must record the expiry date.")
    if storage_status not in pm.STORAGE_STATUSES:
        raise PharmacyError(f"storage_status must be one of {list(pm.STORAGE_STATUSES)}")
    if source_type not in ("purchased", "opening_balance", "donation", "return"):
        raise PharmacyError("source_type must be purchased, opening_balance, donation or return")
    try:
        qty = uom.convert(quantity, unit or item.unit, item.unit)
        rejected = uom.convert(rejected_quantity, unit or item.unit, item.unit)
    except uom.IncompatibleUnits as e:
        raise PharmacyError(str(e)) from e
    accepted = qty - rejected
    when = ensure_utc(received_at) if received_at else now()
    lot = pm.InventoryLot(
        id=new_id(), farm_id=product.farm_id, inventory_item_id=item.id,
        lot_code=_unique_lot_code(db, item.id, (lot_code or f"{item.name[:20].upper()}-{when:%Y%m%d}").strip()),
        source_type=source_type, supplier_id=supplier_id, supplier_label=supplier_label or item.supplier_label, location_id=location_id,
        received_at=when, expiry_date=ensure_utc(expiry_date) if expiry_date else None, received_quantity=qty, accepted_quantity=accepted,
        rejected_quantity=rejected, quantity_on_hand=accepted, unit=item.unit, unit_cost=unit_cost if unit_cost is not None else item.unit_cost,
        status="active" if accepted > 0 else "depleted", reference=reference, notes=notes, created_by=user_id, created_at=now(),
    )
    lot.medicine = pm.MedicineLotDetail(storage_status=storage_status, cold_chain_exception=cold_chain_exception)
    db.add(lot)
    db.flush()
    # `product.lots` is a view over the item's lots; a collection loaded
    # before this receipt would not include it, and eligibility is read
    # from that collection — so forget it and let it reload.
    db.expire(product, ["lots"])
    if accepted > 0:
        db.add(models.InventoryTransaction(
            id=new_id(), item_id=item.id, direction="in", quantity=accepted, unit_cost=lot.unit_cost,
            reason={"purchased": "purchase", "opening_balance": "opening_balance"}.get(source_type, source_type),
            linked_entity_type="inventory_lot", linked_entity_id=lot.id, inventory_lot_id=lot.id, created_at=when,
        ))
        item.current_qty = (item.current_qty or 0) + accepted
        if source_type == "purchased":
            item.last_purchase = when
            if unit_cost is not None:
                item.unit_cost = unit_cost
    write_event(db, farm_id=product.farm_id, entity_type="inventory_lot", entity_id=lot.id, event_type="medicine_lot_received",
                payload={"inventory_item_id": item.id, "lot_code": lot.lot_code, "received": qty, "accepted": accepted, "rejected": rejected,
                         "expiry_date": lot.expiry_date.isoformat() if lot.expiry_date else None, "unit": item.unit}, created_by=user_id)
    if storage_status != "COMPLIANT" or cold_chain_exception:
        write_event(db, farm_id=product.farm_id, entity_type="inventory_lot", entity_id=lot.id, event_type="medicine_storage_exception_detected",
                    payload={"lot_code": lot.lot_code, "storage_status": storage_status, "cold_chain_exception": cold_chain_exception}, created_by=user_id)
    evaluate_item(db, product, user_id=user_id)
    return lot


def set_lot_status(db: Session, lot: pm.InventoryLot, status: str, *, reason: str | None, recall_reference: str | None = None, user_id: str) -> pm.InventoryLot:
    if status not in ("active", "quarantined", "blocked", "recalled"):
        raise PharmacyError("status must be active, quarantined, blocked or recalled")
    if status in ("quarantined", "blocked", "recalled") and not (reason and reason.strip()):
        raise PharmacyError("Say why the lot is being taken out of use.")
    previous = lot.status
    d = _detail(lot)
    lot.status = status
    if status == "quarantined":
        d.quarantine_reason = reason
    elif status == "recalled":
        d.recalled_at = now()
        d.recall_reference = recall_reference
    elif status == "active":
        d.quarantine_reason = None
        refresh_lot_status(lot)
    event = {"quarantined": "medicine_lot_quarantined", "recalled": "medicine_lot_recalled", "blocked": "medicine_lot_blocked", "active": "medicine_lot_released"}[status]
    write_event(db, farm_id=lot.farm_id, entity_type="inventory_lot", entity_id=lot.id, event_type=event,
                payload={"from": previous, "to": lot.status, "reason": reason, "recall_reference": recall_reference}, created_by=user_id)
    evaluate_item(db, get_product(db, lot.inventory_item_id, lot.farm_id), user_id=user_id)
    return lot


def set_storage_status(db: Session, lot: pm.InventoryLot, *, storage_status: str, cold_chain_exception: bool, note: str | None, user_id: str) -> pm.InventoryLot:
    if storage_status not in pm.STORAGE_STATUSES:
        raise PharmacyError(f"storage_status must be one of {list(pm.STORAGE_STATUSES)}")
    d = _detail(lot)
    d.storage_status = storage_status
    d.cold_chain_exception = cold_chain_exception
    d.storage_note = note
    event = "medicine_storage_exception_detected" if (storage_status != "COMPLIANT" or cold_chain_exception) else "medicine_storage_exception_cleared"
    write_event(db, farm_id=lot.farm_id, entity_type="inventory_lot", entity_id=lot.id, event_type=event,
                payload={"lot_code": lot.lot_code, "storage_status": storage_status, "cold_chain_exception": cold_chain_exception, "note": note}, created_by=user_id)
    evaluate_item(db, get_product(db, lot.inventory_item_id, lot.farm_id), user_id=user_id)
    return lot


def open_lot(db: Session, lot: pm.InventoryLot, *, opened_at: datetime | None = None, user_id: str) -> pm.InventoryLot:
    """First use of a multi-dose container: the after-opening shelf life
    (§6) starts now, and the lot stops being eligible when it runs out."""
    product = get_product(db, lot.inventory_item_id, lot.farm_id)
    d = _detail(lot)
    if d.opened_at is not None:
        return lot
    d.opened_at = ensure_utc(opened_at) if opened_at else now()
    if product.opened_shelf_life_days:
        d.use_by_after_opening = d.opened_at + timedelta(days=product.opened_shelf_life_days)
    refresh_lot_status(lot)
    write_event(db, farm_id=lot.farm_id, entity_type="inventory_lot", entity_id=lot.id, event_type="medicine_lot_opened",
                payload={"lot_code": lot.lot_code, "opened_at": d.opened_at.isoformat(), "use_by_after_opening": d.use_by_after_opening.isoformat() if d.use_by_after_opening else None},
                created_by=user_id)
    evaluate_item(db, product, user_id=user_id)
    return lot


def adjust(db: Session, product: pm.MedicineProduct, *, lot: pm.InventoryLot, delta: float, reason: str, explanation: str, user_id: str) -> models.InventoryTransaction:
    """An auditable correction on one lot: a count, a breakage, a return.
    Never below zero, never without an explanation."""
    if not explanation or not explanation.strip():
        raise PharmacyError("An adjustment needs an explanation.")
    if delta == 0:
        raise PharmacyError("Adjustment quantity cannot be zero.")
    if reason not in ADJUSTMENT_REASONS:
        raise PharmacyError(f"reason must be one of {list(ADJUSTMENT_REASONS)}")
    if lot.inventory_item_id != product.inventory_item_id:
        raise PharmacyError("That lot belongs to another medicine.")
    if lot.quantity_on_hand + delta < -0.0005:
        raise PharmacyError(f"Only {lot.quantity_on_hand:g} {lot.unit} on hand in lot {lot.lot_code}; stock cannot go negative.")
    item = item_of(db, product)
    lot.quantity_on_hand = round(lot.quantity_on_hand + delta, 6)
    refresh_lot_status(lot)
    tx = models.InventoryTransaction(
        id=new_id(), item_id=item.id, direction="in" if delta > 0 else "out", quantity=abs(delta), unit_cost=lot.unit_cost, reason=reason,
        linked_entity_type="inventory_lot", linked_entity_id=lot.id, inventory_lot_id=lot.id, created_at=now(),
    )
    db.add(tx)
    item.current_qty = (item.current_qty or 0) + delta
    write_event(db, farm_id=product.farm_id, entity_type="medicine_product", entity_id=product.inventory_item_id, event_type="pharmacy_stock_adjusted",
                payload={"lot_code": lot.lot_code, "delta": delta, "unit": lot.unit, "reason": reason, "explanation": explanation}, created_by=user_id)
    evaluate_item(db, product, user_id=user_id)
    return tx


def lot_dict(db: Session, lot: pm.InventoryLot) -> dict:
    d = lot.medicine
    why = ineligibility(lot)
    return {
        "id": lot.id, "inventory_item_id": lot.inventory_item_id, "lot_code": lot.lot_code, "source_type": lot.source_type,
        "supplier_id": lot.supplier_id, "supplier_label": lot.supplier_label, "location_id": lot.location_id, "received_at": lot.received_at,
        "expiry_date": lot.expiry_date, "received_quantity": lot.received_quantity, "accepted_quantity": lot.accepted_quantity,
        "rejected_quantity": lot.rejected_quantity, "quantity_on_hand": lot.quantity_on_hand, "unit": lot.unit, "unit_cost": lot.unit_cost,
        "status": lot.status, "eligible": why is None, "ineligible_reason": why, "reference": lot.reference, "notes": lot.notes,
        "opened_at": d.opened_at if d else None, "use_by_after_opening": d.use_by_after_opening if d else None,
        "storage_status": d.storage_status if d else "COMPLIANT", "cold_chain_exception": bool(d.cold_chain_exception) if d else False,
        "storage_note": d.storage_note if d else None, "quarantine_reason": d.quarantine_reason if d else None,
        "recalled_at": d.recalled_at if d else None, "recall_reference": d.recall_reference if d else None,
    }


# ------------------------------------------------------------------ stock
def stock_breakdown(db: Session, product: pm.MedicineProduct, *, location_id: str | None = None, warning_days: int = 60, at: datetime | None = None) -> dict:
    """On hand against eligible (§7), with every excluded quantity named
    and the expiry picture the dashboard shows (§10)."""
    at = at or now()
    lots = [l for l in product.lots if location_id is None or l.location_id == location_id]
    out = {"on_hand": 0.0, "eligible": 0.0, "quarantined": 0.0, "blocked": 0.0, "recalled": 0.0, "expired": 0.0, "storage_exception": 0.0,
           "lot_count": 0, "eligible_lot_count": 0, "earliest_expiry": None, "expiring_quantity": 0.0, "expiring_lots": []}
    horizon = at + timedelta(days=warning_days)
    for lot in lots:
        qty = lot.quantity_on_hand
        if qty <= 0.0005:
            continue
        out["on_hand"] += qty
        out["lot_count"] += 1
        why = ineligibility(lot, at)
        if why is None:
            out["eligible"] += qty
            out["eligible_lot_count"] += 1
            exp = ensure_utc(lot.expiry_date) if lot.expiry_date else None
            d = lot.medicine
            if d is not None and d.use_by_after_opening is not None:
                ub = ensure_utc(d.use_by_after_opening)
                exp = ub if exp is None else min(exp, ub)
            if exp is not None:
                if out["earliest_expiry"] is None or exp < out["earliest_expiry"]:
                    out["earliest_expiry"] = exp
                if exp <= horizon:
                    out["expiring_quantity"] += qty
                    out["expiring_lots"].append({"lot_id": lot.id, "lot_code": lot.lot_code, "quantity": qty, "expiry_date": exp})
        elif why == "expired":
            out["expired"] += qty
        elif why in ("storage_exception", "cold_chain_exception"):
            out["storage_exception"] += qty
        elif why in ("quarantined", "blocked", "recalled"):
            out[why] += qty
    for k in ("on_hand", "eligible", "quarantined", "blocked", "recalled", "expired", "storage_exception", "expiring_quantity"):
        out[k] = round(out[k], 6)
    return out


def policy_for(db: Session, product: pm.MedicineProduct, location_id: str | None = None) -> pm.PharmacyStockPolicy | None:
    return db.scalar(select(pm.PharmacyStockPolicy).where(
        pm.PharmacyStockPolicy.inventory_item_id == product.inventory_item_id, pm.PharmacyStockPolicy.location_id.is_(None) if location_id is None else pm.PharmacyStockPolicy.location_id == location_id,
    ))


def policies_for(db: Session, product: pm.MedicineProduct) -> list[pm.PharmacyStockPolicy]:
    return list(db.scalars(select(pm.PharmacyStockPolicy).where(pm.PharmacyStockPolicy.inventory_item_id == product.inventory_item_id, pm.PharmacyStockPolicy.active.is_(True))))


def stock_status(eligible: float, policy: pm.PharmacyStockPolicy | None) -> str:
    """OK / LOW / CRITICAL / OUT from the farm's thresholds
    (MEDICINE-NOTIFICATION-RULES.md §Severity)."""
    if policy is None:
        return "OUT" if eligible <= 0 else "OK"
    if eligible <= 0:
        if policy.essential:
            return "OUT"
        if policy.critical_stock_base is not None:
            return "CRITICAL"
        return "LOW" if policy.minimum_stock_base else "OK"
    if policy.critical_stock_base is not None and eligible <= policy.critical_stock_base:
        return "CRITICAL"
    if policy.minimum_stock_base is not None and eligible < policy.minimum_stock_base:
        return "LOW"
    return "OK"


def recommended_reorder(product: pm.MedicineProduct, policy: pm.PharmacyStockPolicy | None, eligible: float, incoming: float = 0) -> float:
    """recommended = max(0, target − eligible − confirmed incoming), rounded
    up to the pack size (§9). Never a purchase order."""
    if policy is None or policy.target_stock_base is None:
        return 0.0
    need = max(0.0, policy.target_stock_base - eligible - incoming)
    if need > 0 and product.default_pack_size and product.default_pack_size > 0:
        need = math.ceil(need / product.default_pack_size - 1e-9) * product.default_pack_size
    return round(need, 6)


def average_daily_consumption(db: Session, product: pm.MedicineProduct, *, days: int = 30) -> float:
    since = now() - timedelta(days=days)
    used = db.scalar(select(func.sum(models.InventoryTransaction.quantity)).where(
        models.InventoryTransaction.item_id == product.inventory_item_id, models.InventoryTransaction.direction == "out",
        models.InventoryTransaction.reason == "administration", models.InventoryTransaction.created_at >= since)) or 0
    return round(float(used) / days, 6)


# ----------------------------------------------------------------- policy
def upsert_policy(db: Session, product: pm.MedicineProduct, *, location_id: str | None = None, user_id: str, **fields) -> pm.PharmacyStockPolicy:
    for key in ("minimum_stock_base", "target_stock_base", "critical_stock_base", "minimum_days_cover", "lead_time_days"):
        v = fields.get(key)
        if v is not None and v < 0:
            raise PharmacyError(f"{key} must be zero or more")
    mn, cr, tg = fields.get("minimum_stock_base"), fields.get("critical_stock_base"), fields.get("target_stock_base")
    if cr is not None and mn is not None and cr > mn:
        raise PharmacyError("The critical level cannot be above the minimum.")
    if tg is not None and mn is not None and tg < mn:
        raise PharmacyError("The target level cannot be below the minimum.")
    if fields.get("expiry_warning_days") is not None and fields["expiry_warning_days"] < 0:
        raise PharmacyError("expiry_warning_days must be zero or more")
    if location_id and db.get(models.Location, location_id) is None:
        raise PharmacyError("Location not found", 404)
    policy = policy_for(db, product, location_id)
    created = policy is None
    if created:
        policy = pm.PharmacyStockPolicy(id=new_id(), farm_id=product.farm_id, inventory_item_id=product.inventory_item_id, location_id=location_id, version=0)
        db.add(policy)
    for k in ("essential", "minimum_stock_base", "target_stock_base", "critical_stock_base", "minimum_days_cover", "lead_time_days",
              "preferred_supplier_id", "alert_enabled", "expiry_warning_days", "auto_draft_requisition", "active"):
        if k in fields:
            setattr(policy, k, fields[k])
    policy.version = (policy.version or 0) + 1
    policy.updated_by = user_id
    policy.updated_at = now()
    db.flush()
    write_event(db, farm_id=product.farm_id, entity_type="medicine_product", entity_id=product.inventory_item_id, event_type="essential_medicine_policy_changed",
                payload={"policy_id": policy.id, "version": policy.version, "essential": policy.essential, "minimum": policy.minimum_stock_base,
                         "critical": policy.critical_stock_base, "target": policy.target_stock_base, "location_id": location_id, "created": created}, created_by=user_id)
    evaluate_item(db, product, user_id=user_id)
    return policy


def policy_dict(p: pm.PharmacyStockPolicy | None) -> dict | None:
    if p is None:
        return None
    return {
        "id": p.id, "inventory_item_id": p.inventory_item_id, "location_id": p.location_id, "essential": p.essential,
        "minimum_stock_base": p.minimum_stock_base, "target_stock_base": p.target_stock_base, "critical_stock_base": p.critical_stock_base,
        "minimum_days_cover": p.minimum_days_cover, "lead_time_days": p.lead_time_days, "preferred_supplier_id": p.preferred_supplier_id,
        "alert_enabled": p.alert_enabled, "expiry_warning_days": p.expiry_warning_days, "auto_draft_requisition": p.auto_draft_requisition,
        "active": p.active, "version": p.version, "updated_by": p.updated_by, "updated_at": p.updated_at,
    }


# ----------------------------------------------------------------- alerts
def _open_alert(db: Session, farm_id: str, key: str) -> pm.PharmacyStockAlert | None:
    return db.scalar(select(pm.PharmacyStockAlert).where(
        pm.PharmacyStockAlert.farm_id == farm_id, pm.PharmacyStockAlert.deduplication_key == key, pm.PharmacyStockAlert.status != "resolved"))


def _raise_alert(db: Session, product: pm.MedicineProduct, *, alert_type: str, location_id: str | None, policy: pm.PharmacyStockPolicy | None,
                 breakdown: dict, explanation: str, reorder: float = 0.0, user_id: str) -> tuple[pm.PharmacyStockAlert, bool]:
    """One open alert per condition (§8): a repeat scan refreshes the
    figures on the existing row instead of raising a twin."""
    key = f"{product.inventory_item_id}|{location_id or '*'}|{alert_type}|v{policy.version if policy else 0}"
    existing = _open_alert(db, product.farm_id, key)
    if existing is None:
        # The same condition under an older policy version is superseded.
        for stale in db.scalars(select(pm.PharmacyStockAlert).where(
                pm.PharmacyStockAlert.farm_id == product.farm_id, pm.PharmacyStockAlert.inventory_item_id == product.inventory_item_id,
                pm.PharmacyStockAlert.alert_type == alert_type, pm.PharmacyStockAlert.status != "resolved",
                pm.PharmacyStockAlert.location_id.is_(None) if location_id is None else pm.PharmacyStockAlert.location_id == location_id)):
            stale.status = "resolved"
            stale.resolved_at = now()
            stale.resolution_note = "policy changed"
    row = existing or pm.PharmacyStockAlert(
        id=new_id(), farm_id=product.farm_id, inventory_item_id=product.inventory_item_id, location_id=location_id, alert_type=alert_type,
        severity=SEVERITY[alert_type], detected_at=now(), status="open", deduplication_key=key,
    )
    row.last_seen_at = now()
    row.eligible_available_base = breakdown["eligible"]
    row.minimum_stock_base = policy.minimum_stock_base if policy else None
    row.target_stock_base = policy.target_stock_base if policy else None
    row.earliest_expiry_date = breakdown["earliest_expiry"]
    row.expiring_quantity = breakdown["expiring_quantity"] if alert_type == "EXPIRING_SOON" else (breakdown["expired"] if alert_type == "EXPIRED_STOCK" else None)
    row.recommended_reorder_base = reorder or None
    row.explanation = explanation
    if existing is None:
        db.add(row)
        db.flush()
        write_event(db, farm_id=product.farm_id, entity_type="medicine_product", entity_id=product.inventory_item_id, event_type=EVENT_FOR_ALERT[alert_type],
                    payload={"alert_id": row.id, "alert_type": alert_type, "severity": row.severity, "eligible": breakdown["eligible"],
                             "minimum": row.minimum_stock_base, "recommended_reorder": row.recommended_reorder_base, "location_id": location_id}, created_by=user_id)
        if reorder > 0 and alert_type in pm.STOCK_ALERT_TYPES:
            write_event(db, farm_id=product.farm_id, entity_type="medicine_product", entity_id=product.inventory_item_id, event_type="medicine_reorder_required",
                        payload={"alert_id": row.id, "recommended_reorder": reorder, "unit": item_of(db, product).unit}, created_by=user_id)
    return row, existing is None


def _resolve_alerts(db: Session, product: pm.MedicineProduct, *, alert_types: tuple[str, ...], location_id: str | None, reason: str, user_id: str) -> list[pm.PharmacyStockAlert]:
    rows = db.scalars(select(pm.PharmacyStockAlert).where(
        pm.PharmacyStockAlert.farm_id == product.farm_id, pm.PharmacyStockAlert.inventory_item_id == product.inventory_item_id,
        pm.PharmacyStockAlert.alert_type.in_(alert_types), pm.PharmacyStockAlert.status != "resolved",
        pm.PharmacyStockAlert.location_id.is_(None) if location_id is None else pm.PharmacyStockAlert.location_id == location_id)).all()
    for a in rows:
        a.status = "resolved"
        a.resolved_at = now()
        a.resolution_note = reason
        if a.alert_type in pm.STOCK_ALERT_TYPES or a.alert_type == "LOW_DAYS_COVER":
            write_event(db, farm_id=product.farm_id, entity_type="medicine_product", entity_id=product.inventory_item_id, event_type="medicine_stock_recovered",
                        payload={"alert_id": a.id, "alert_type": a.alert_type, "reason": reason}, created_by=user_id)
        for t in db.scalars(select(models.Task).where(models.Task.source_type == "pharmacy_requisition", models.Task.source_id == a.id, models.Task.status == "open")):
            # The shortage is gone; the draft requisition is closed, not deleted.
            t.status = "done"
    return rows


def evaluate_item(db: Session, product: pm.MedicineProduct, *, user_id: str = "system", at: datetime | None = None) -> list[pm.PharmacyStockAlert]:
    """Re-evaluates one medicine against its policies and its lots
    (MEDICINE-NOTIFICATION-RULES.md): raises or refreshes the alerts whose
    condition holds, resolves the ones whose condition cleared."""
    at = at or now()
    item = item_of(db, product)
    farm_policy = policy_for(db, product, None)
    warning_days = farm_policy.expiry_warning_days if farm_policy else 60
    alerts_enabled = farm_policy.alert_enabled if farm_policy else True
    whole = stock_breakdown(db, product, warning_days=warning_days, at=at)
    name = item.name
    out: list[pm.PharmacyStockAlert] = []

    # Conditions of the lots themselves, whatever the thresholds say.
    conditions = {
        "EXPIRED_STOCK": (whole["expired"] > 0, f"{name}: {whole['expired']:g} {item.unit} on hand is expired or past its after-opening use-by and does not count toward the minimum. Remove it from the shelf and record the disposal."),
        "EXPIRING_SOON": (whole["expiring_quantity"] > 0, f"{name}: {whole['expiring_quantity']:g} {item.unit} expires within {warning_days} days"
                          + (f" (earliest {whole['earliest_expiry']:%Y-%m-%d})" if whole["earliest_expiry"] else "") + ". Use it first or plan its replacement."),
        "RECALL_AFFECTED": (whole["recalled"] > 0, f"{name}: {whole['recalled']:g} {item.unit} on hand belongs to a recalled lot. It is blocked from use; return or dispose of it per the recall."),
        "STORAGE_EXCEPTION": (whole["storage_exception"] > 0, f"{name}: {whole['storage_exception']:g} {item.unit} is held under a storage or cold-chain exception and is not eligible until a person clears it."),
    }
    for alert_type, (holds, text) in conditions.items():
        if holds and alerts_enabled:
            row, _ = _raise_alert(db, product, alert_type=alert_type, location_id=None, policy=farm_policy, breakdown=whole, explanation=text, user_id=user_id)
            out.append(row)
        else:
            _resolve_alerts(db, product, alert_types=(alert_type,), location_id=None, reason="condition cleared", user_id=user_id)

    # Threshold conditions, per policy (farm-wide or per location).
    for policy in policies_for(db, product):
        loc = policy.location_id
        bd = whole if loc is None else stock_breakdown(db, product, location_id=loc, warning_days=policy.expiry_warning_days, at=at)
        if not policy.alert_enabled:
            _resolve_alerts(db, product, alert_types=pm.STOCK_ALERT_TYPES + ("LOW_DAYS_COVER",), location_id=loc, reason="alerts disabled by policy", user_id=user_id)
            continue
        status = stock_status(bd["eligible"], policy)
        reorder = recommended_reorder(product, policy, bd["eligible"])
        raise_type = {"OUT": "OUT_OF_STOCK", "CRITICAL": "CRITICAL_STOCK", "LOW": "BELOW_MINIMUM_STOCK"}.get(status)
        figures = (f"eligible {bd['eligible']:g} {item.unit} (on hand {bd['on_hand']:g}; excluded: expired {bd['expired']:g}, quarantined {bd['quarantined']:g}, "
                   f"blocked {bd['blocked']:g}, recalled {bd['recalled']:g}, storage exception {bd['storage_exception']:g})")
        if raise_type and (policy.essential or policy.minimum_stock_base is not None or policy.critical_stock_base is not None):
            head = {"OUT": "is out of eligible stock", "CRITICAL": f"is at a critical level (≤ {policy.critical_stock_base:g} {item.unit})",
                    "LOW": f"is below the farm's minimum of {policy.minimum_stock_base:g} {item.unit}"}[status]
            text = f"{name} {head}: {figures}." + (f" Recommended reorder {reorder:g} {item.unit} to reach the target of {policy.target_stock_base:g}." if reorder > 0 else "") + f" {SAFETY}"
            row, created = _raise_alert(db, product, alert_type=raise_type, location_id=loc, policy=policy, breakdown=bd, explanation=text, reorder=reorder, user_id=user_id)
            out.append(row)
            _resolve_alerts(db, product, alert_types=tuple(t for t in pm.STOCK_ALERT_TYPES if t != raise_type), location_id=loc, reason=f"superseded by {raise_type}", user_id=user_id)
            if created and policy.auto_draft_requisition and reorder > 0:
                create_requisition(db, row, user_id=user_id)
        else:
            _resolve_alerts(db, product, alert_types=pm.STOCK_ALERT_TYPES, location_id=loc, reason="eligible stock back above the threshold", user_id=user_id)
        daily = average_daily_consumption(db, product)
        if policy.minimum_days_cover and daily > 0 and bd["eligible"] / daily < policy.minimum_days_cover:
            text = (f"{name}: eligible stock covers {bd['eligible'] / daily:.1f} day(s) at the last 30 days' use ({daily:g} {item.unit}/day), "
                    f"below the farm's minimum of {policy.minimum_days_cover:g} days. {SAFETY}")
            row, _ = _raise_alert(db, product, alert_type="LOW_DAYS_COVER", location_id=loc, policy=policy, breakdown=bd, explanation=text, reorder=reorder, user_id=user_id)
            out.append(row)
        else:
            _resolve_alerts(db, product, alert_types=("LOW_DAYS_COVER",), location_id=loc, reason="days of cover back above the minimum", user_id=user_id)
    return out


def evaluate_farm(db: Session, farm_id: str, *, user_id: str = "system", at: datetime | None = None) -> dict:
    """The scheduled pharmacy scan: every medicine, every lot's expiry
    boundary, every policy. Idempotent."""
    products = db.scalars(select(pm.MedicineProduct).where(pm.MedicineProduct.farm_id == farm_id, pm.MedicineProduct.active.is_(True))).all()
    raised = 0
    for p in products:
        raised += len(evaluate_item(db, p, user_id=user_id, at=at))
    open_count = db.scalar(select(func.count(pm.PharmacyStockAlert.id)).where(pm.PharmacyStockAlert.farm_id == farm_id, pm.PharmacyStockAlert.status != "resolved")) or 0
    return {"evaluated_at": at or now(), "medicines": len(products), "conditions": raised, "open_alerts": open_count}


def acknowledge_alert(db: Session, alert: pm.PharmacyStockAlert, *, user_id: str) -> pm.PharmacyStockAlert:
    """Records that a person saw it; the stock condition is untouched."""
    if alert.status == "resolved":
        raise PharmacyError("This alert is already resolved.")
    alert.status = "acknowledged"
    alert.acknowledged_by = user_id
    alert.acknowledged_at = now()
    return alert


def resolve_alert_manually(db: Session, alert: pm.PharmacyStockAlert, *, note: str | None, user_id: str) -> pm.PharmacyStockAlert:
    if alert.status == "resolved":
        raise PharmacyError("This alert is already resolved.")
    if not note or not note.strip():
        raise PharmacyError("Say why this alert is being closed — the stock condition has not changed.")
    alert.status = "resolved"
    alert.resolved_at = now()
    alert.resolution_note = note.strip()
    write_event(db, farm_id=alert.farm_id, entity_type="medicine_product", entity_id=alert.inventory_item_id, event_type="pharmacy_alert_closed",
                payload={"alert_id": alert.id, "alert_type": alert.alert_type, "note": note, "manual": True}, created_by=user_id)
    return alert


def create_requisition(db: Session, alert: pm.PharmacyStockAlert, *, user_id: str) -> tuple[models.Task, bool]:
    """One DRAFT requisition per unresolved shortage (§9): a task for the
    buyer to act on, never a purchase order and never approved here."""
    if alert.alert_type not in pm.STOCK_ALERT_TYPES and alert.alert_type != "LOW_DAYS_COVER":
        raise PharmacyError("Only a stock shortage can open a requisition.")
    if alert.status == "resolved":
        raise PharmacyError("This alert is resolved; the shortage is gone.")
    if alert.requisition_task_id:
        task = db.get(models.Task, alert.requisition_task_id)
        if task is not None and task.status == "open":
            return task, False
    product = get_product(db, alert.inventory_item_id, alert.farm_id)
    item = item_of(db, product)
    policy = policy_for(db, product, alert.location_id)
    qty = alert.recommended_reorder_base or recommended_reorder(product, policy, alert.eligible_available_base or 0)
    if qty <= 0:
        raise PharmacyError("No reorder quantity: set a target stock level on the policy first.")
    supplier = db.get(models.Supplier, policy.preferred_supplier_id) if policy and policy.preferred_supplier_id else None
    task = models.Task(
        id=new_id(), farm_id=alert.farm_id, title=f"Draft requisition: {item.name} × {qty:g} {item.unit}",
        description=(f"DRAFT purchase requisition from pharmacy alert {alert.alert_type}: eligible {alert.eligible_available_base or 0:g} {item.unit}, "
                     f"minimum {alert.minimum_stock_base or 0:g}, target {alert.target_stock_base or 0:g}."
                     + (f" Preferred supplier: {supplier.name}." if supplier else "") + " Needs approval before any order is placed."),
        due_at=now() + timedelta(days=max(1, int(policy.lead_time_days or 2)) if policy else 2), priority="high" if alert.severity in ("critical", "high") else "medium",
        status="open", source_type="pharmacy_requisition", source_id=alert.id,
    )
    db.add(task)
    db.flush()
    alert.requisition_task_id = task.id
    write_event(db, farm_id=alert.farm_id, entity_type="medicine_product", entity_id=alert.inventory_item_id, event_type="medicine_reorder_required",
                payload={"alert_id": alert.id, "task_id": task.id, "recommended_reorder": qty, "unit": item.unit, "draft": True}, created_by=user_id)
    return task, True


def alert_dict(db: Session, a: pm.PharmacyStockAlert) -> dict:
    item = db.get(models.InventoryItem, a.inventory_item_id)
    return {
        "id": a.id, "inventory_item_id": a.inventory_item_id, "medicine_name": item.name if item else None, "unit": item.unit if item else None,
        "location_id": a.location_id, "alert_type": a.alert_type, "severity": a.severity, "detected_at": a.detected_at, "last_seen_at": a.last_seen_at,
        "eligible_available_base": a.eligible_available_base, "minimum_stock_base": a.minimum_stock_base, "target_stock_base": a.target_stock_base,
        "earliest_expiry_date": a.earliest_expiry_date, "expiring_quantity": a.expiring_quantity, "recommended_reorder_base": a.recommended_reorder_base,
        "explanation": a.explanation, "status": a.status, "acknowledged_by": a.acknowledged_by, "acknowledged_at": a.acknowledged_at,
        "resolved_at": a.resolved_at, "resolution_note": a.resolution_note, "deduplication_key": a.deduplication_key, "requisition_task_id": a.requisition_task_id,
    }


# --------------------------------------------------------- administration
def _subject(db: Session, subject_type: str, subject_id: str, farm_id: str):
    if subject_type not in ("animal", "group"):
        raise PharmacyError("subject_type must be animal or group")
    subject = db.get(models.Animal, subject_id) if subject_type == "animal" else db.get(models.Flock, subject_id)
    if subject is None or subject.farm_id != farm_id:
        raise PharmacyError("Subject not found", 404)
    return subject


def eligible_lots(db: Session, product: pm.MedicineProduct, *, location_id: str | None = None, at: datetime | None = None) -> list[pm.InventoryLot]:
    """First-expiry-first-out order among lots that count (§7)."""
    at = at or now()
    rows = [l for l in product.lots if ineligibility(l, at) is None and (location_id is None or l.location_id == location_id)]
    far = datetime.max.replace(tzinfo=at.tzinfo)
    rows.sort(key=lambda l: (ensure_utc(l.expiry_date) if l.expiry_date else far, ensure_utc(l.received_at)))
    return rows


def administer(db: Session, farm_id: str, *, subject_type: str, subject_id: str, inventory_item_id: str, lot_id: str | None = None,
               dose_quantity: float, dose_unit: str, route_code: str, head_count: int | None = None, quantity_consumed: float | None = None,
               treatment_id: str | None = None, protocol_run_step_id: str | None = None, administered_at: datetime | None = None,
               reason: str | None = None, notes: str | None = None, user_id: str) -> pm.MedicationAdministration:
    """A dose actually given (§11), atomically: authorisation and
    treatment context, lot eligibility, the record, the exact-lot
    consumption, the product's authorised withdrawal, the event, and the
    threshold re-evaluation."""
    product = get_product(db, inventory_item_id, farm_id)
    item = item_of(db, product)
    if not product.active:
        raise PharmacyError(f"{item.name} is retired and cannot be administered.")
    subject = _subject(db, subject_type, subject_id, farm_id)
    at = ensure_utc(administered_at) if administered_at else now()
    if dose_quantity <= 0:
        raise PharmacyError("Dose must be greater than zero.")
    if route_code not in pm.ROUTES:
        raise PharmacyError(f"route_code must be one of {list(pm.ROUTES)}")
    if product.administration_routes and route_code not in product.administration_routes:
        raise PharmacyError(f"{item.name} is authorised for {', '.join(product.administration_routes)} only, not {route_code}.")
    if product.species_codes and subject.species not in product.species_codes:
        raise PharmacyError(f"{item.name} is not authorised for {subject.species}; it is configured for {', '.join(product.species_codes)}.")
    treatment = None
    if treatment_id:
        treatment = db.get(models.Treatment, treatment_id)
        expected_type = "animal" if subject_type == "animal" else "flock"
        if treatment is None or treatment.entity_type != expected_type or treatment.entity_id != subject_id:
            raise PharmacyError("The treatment does not belong to this subject.", 404 if treatment is None else 422)
    if product.prescription_required and treatment is None and not protocol_run_step_id:
        raise PharmacyError(f"{item.name} needs a prescription: record the treatment (veterinarian or manager) or run an approved protocol step first. "
                            "Stock on the shelf never authorises its use.")
    heads = head_count if head_count is not None else (1 if subject_type == "animal" else max(1, int(getattr(subject, "count", 1) or 1)))
    if heads <= 0:
        raise PharmacyError("head_count must be at least one.")
    if quantity_consumed is None:
        if not uom.compatible(dose_unit, item.unit):
            raise PharmacyError(f"The dose is in {dose_unit} and {item.name} is stocked in {item.unit}; give quantity_consumed in {item.unit}.")
        quantity_consumed = round(uom.convert(dose_quantity * heads, dose_unit, item.unit), 6)
    if quantity_consumed <= 0:
        raise PharmacyError("Quantity consumed must be greater than zero.")

    # The exact lot: the one named, if it counts; else first-expiry-first-out.
    if lot_id:
        lot = get_lot(db, lot_id, farm_id)
        if lot.inventory_item_id != product.inventory_item_id:
            raise PharmacyError("That lot belongs to another medicine.")
        why = ineligibility(lot, at)
        if why is not None:
            raise PharmacyError(f"Lot {lot.lot_code} is not eligible ({why.replace('_', ' ')}). Choose an eligible lot.")
        if lot.quantity_on_hand + 0.0005 < quantity_consumed:
            raise PharmacyError(f"Lot {lot.lot_code} has only {lot.quantity_on_hand:g} {item.unit} on hand; {quantity_consumed:g} is needed.")
    else:
        candidates = eligible_lots(db, product, at=at)
        lot = next((l for l in candidates if l.quantity_on_hand + 0.0005 >= quantity_consumed), None)
        if lot is None:
            total = round(sum(l.quantity_on_hand for l in candidates), 6)
            bd = stock_breakdown(db, product, at=at)
            raise PharmacyError(f"No eligible lot of {item.name} holds {quantity_consumed:g} {item.unit} (eligible {total:g}; on hand {bd['on_hand']:g}, "
                                f"of which expired {bd['expired']:g}, quarantined {bd['quarantined']:g}, storage exception {bd['storage_exception']:g}). "
                                "Only eligible stock can be administered.")

    adm = pm.MedicationAdministration(
        id=new_id(), farm_id=farm_id, subject_type=subject_type, subject_id=subject_id, treatment_id=treatment_id, protocol_run_step_id=protocol_run_step_id,
        inventory_item_id=product.inventory_item_id, inventory_lot_id=lot.id, dose_quantity=dose_quantity, dose_unit=dose_unit, route_code=route_code,
        head_count=heads, quantity_consumed=quantity_consumed, unit=item.unit, administered_at=at, administered_by=user_id, reason=reason, notes=notes,
        status="recorded", created_at=now(),
    )
    db.add(adm)
    db.flush()
    tx = models.InventoryTransaction(
        id=new_id(), item_id=item.id, direction="out", quantity=quantity_consumed, unit_cost=lot.unit_cost, reason="administration",
        linked_entity_type="medication_administration", linked_entity_id=adm.id, inventory_lot_id=lot.id, created_at=at,
    )
    db.add(tx)
    adm.inventory_transaction_id = tx.id
    lot.quantity_on_hand = round(lot.quantity_on_hand - quantity_consumed, 6)
    refresh_lot_status(lot)
    item.current_qty = (item.current_qty or 0) - quantity_consumed
    d = _detail(lot)
    if d.opened_at is None and product.opened_shelf_life_days:
        d.opened_at = at
        d.use_by_after_opening = at + timedelta(days=product.opened_shelf_life_days)

    # Withdrawal from the product's authorised rule — never invented here.
    rules = product.withdrawal_rules_json or {}
    milk = at + timedelta(days=float(rules["milk_days"])) if rules.get("milk_days") is not None else None
    meat = at + timedelta(days=float(rules["meat_days"])) if rules.get("meat_days") is not None else None
    adm.withdrawal_milk_until, adm.withdrawal_meat_until = milk, meat
    until = max([x for x in (milk, meat) if x is not None], default=None)
    animals = [subject] if subject_type == "animal" else programs.animals_in_group(db, subject)
    if until is not None:
        for a in animals:
            current = ensure_utc(a.withdrawal_until) if a.withdrawal_until else None
            if current is None or until > current:
                a.withdrawal_until = until
                a.withdrawal_reason = f"Medication: {item.name}"
            if a.status == "healthy":
                a.status = "under_treatment"
    write_event(db, farm_id=farm_id, entity_type=subject_type, entity_id=subject_id, event_type="medication_administered",
                payload={"administration_id": adm.id, "medicine": item.name, "inventory_item_id": item.id, "lot_id": lot.id, "lot_code": lot.lot_code,
                         "dose": dose_quantity, "dose_unit": dose_unit, "route": route_code, "head_count": heads, "quantity_consumed": quantity_consumed,
                         "unit": item.unit, "treatment_id": treatment_id, "protocol_run_step_id": protocol_run_step_id,
                         "withdrawal_milk_until": milk.isoformat() if milk else None, "withdrawal_meat_until": meat.isoformat() if meat else None},
                created_by=user_id)
    evaluate_item(db, product, user_id=user_id)
    return adm


def reverse_administration(db: Session, adm: pm.MedicationAdministration, *, reason: str, user_id: str) -> pm.MedicationAdministration:
    """Puts the quantity back on the exact lot and keeps the original
    record. The withdrawal is not shortened: a mistaken entry does not
    prove the animal was not dosed — the veterinarian corrects that
    explicitly."""
    if adm.status == "reversed":
        raise PharmacyError("This administration is already reversed.")
    if not reason or not reason.strip():
        raise PharmacyError("A reversal needs a reason.")
    product = get_product(db, adm.inventory_item_id, adm.farm_id)
    item = item_of(db, product)
    lot = get_lot(db, adm.inventory_lot_id, adm.farm_id)
    lot.quantity_on_hand = round(lot.quantity_on_hand + adm.quantity_consumed, 6)
    refresh_lot_status(lot)
    item.current_qty = (item.current_qty or 0) + adm.quantity_consumed
    db.add(models.InventoryTransaction(
        id=new_id(), item_id=item.id, direction="in", quantity=adm.quantity_consumed, unit_cost=lot.unit_cost, reason="administration_reversal",
        linked_entity_type="medication_administration", linked_entity_id=adm.id, inventory_lot_id=lot.id, created_at=now(),
    ))
    adm.status = "reversed"
    adm.reversed_at = now()
    adm.reversal_reason = reason.strip()
    write_event(db, farm_id=adm.farm_id, entity_type=adm.subject_type, entity_id=adm.subject_id, event_type="medication_administration_reversed",
                payload={"administration_id": adm.id, "lot_code": lot.lot_code, "quantity": adm.quantity_consumed, "reason": reason}, created_by=user_id)
    evaluate_item(db, product, user_id=user_id)
    return adm


def administration_dict(db: Session, adm: pm.MedicationAdministration) -> dict:
    item = db.get(models.InventoryItem, adm.inventory_item_id)
    lot = db.get(pm.InventoryLot, adm.inventory_lot_id)
    subject = db.get(models.Animal, adm.subject_id) if adm.subject_type == "animal" else db.get(models.Flock, adm.subject_id)
    user = db.get(models.User, adm.administered_by)
    return {
        "id": adm.id, "subject_type": adm.subject_type, "subject_id": adm.subject_id, "subject_name": getattr(subject, "name", None),
        "species": getattr(subject, "species", None), "treatment_id": adm.treatment_id, "protocol_run_step_id": adm.protocol_run_step_id,
        "inventory_item_id": adm.inventory_item_id, "medicine_name": item.name if item else None, "inventory_lot_id": adm.inventory_lot_id,
        "lot_code": lot.lot_code if lot else None, "dose_quantity": adm.dose_quantity, "dose_unit": adm.dose_unit, "route_code": adm.route_code,
        "head_count": adm.head_count, "quantity_consumed": adm.quantity_consumed, "unit": adm.unit, "administered_at": adm.administered_at,
        "administered_by": adm.administered_by, "administered_by_name": user.name if user else None, "inventory_transaction_id": adm.inventory_transaction_id,
        "withdrawal_milk_until": adm.withdrawal_milk_until, "withdrawal_meat_until": adm.withdrawal_meat_until, "reason": adm.reason, "notes": adm.notes,
        "status": adm.status, "reversed_at": adm.reversed_at, "reversal_reason": adm.reversal_reason,
    }


# ------------------------------------------------------------- dashboard
def product_dict(db: Session, product: pm.MedicineProduct, *, with_lots: bool = False) -> dict:
    item = item_of(db, product)
    policy = policy_for(db, product, None)
    bd = stock_breakdown(db, product, warning_days=policy.expiry_warning_days if policy else 60)
    status = stock_status(bd["eligible"], policy)
    open_alerts = db.scalars(select(pm.PharmacyStockAlert).where(
        pm.PharmacyStockAlert.inventory_item_id == product.inventory_item_id, pm.PharmacyStockAlert.status != "resolved")).all()
    out = {
        "inventory_item_id": product.inventory_item_id, "name": item.name, "unit": item.unit, "category": item.category, "current_qty": item.current_qty,
        "supplier_label": item.supplier_label, "unit_cost": item.unit_cost, "generic_name": product.generic_name, "brand_name": product.brand_name,
        "dosage_form": product.dosage_form, "strength_value": product.strength_value, "strength_uom": product.strength_uom, "strength_basis": product.strength_basis,
        "administration_routes": product.administration_routes or [], "prescription_required": product.prescription_required, "antimicrobial": product.antimicrobial,
        "controlled_medicine": product.controlled_medicine, "cold_chain_required": product.cold_chain_required, "storage_min_c": product.storage_min_c,
        "storage_max_c": product.storage_max_c, "opened_shelf_life_days": product.opened_shelf_life_days, "default_pack_size": product.default_pack_size,
        "pack_uom": product.pack_uom, "manufacturer_name": product.manufacturer_name, "authorization_reference": product.authorization_reference,
        "species_codes": product.species_codes or [], "withdrawal_rules": product.withdrawal_rules_json or {}, "lot_tracking_exception": product.lot_tracking_exception,
        "active": product.active, "categories": [{"code": c.category.code, "name": c.category.name, "name_ar": c.category.name_ar} for c in product.categories],
        "ingredients": [{"code": i.ingredient.code, "name": i.ingredient.name, "concentration_value": i.concentration_value, "concentration_uom": i.concentration_uom,
                         "concentration_basis": i.concentration_basis} for i in product.ingredients],
        "stock": {k: v for k, v in bd.items() if k != "expiring_lots"}, "eligible_available": bd["eligible"], "on_hand": bd["on_hand"], "lot_count": bd["lot_count"],
        "earliest_expiry": bd["earliest_expiry"], "expiring_quantity": bd["expiring_quantity"], "storage_exception": bd["storage_exception"] > 0,
        "status": status, "policy": policy_dict(policy), "recommended_reorder": recommended_reorder(product, policy, bd["eligible"]),
        "open_alerts": [{"id": a.id, "alert_type": a.alert_type, "severity": a.severity, "status": a.status, "requisition_task_id": a.requisition_task_id} for a in open_alerts],
        "open_requisition": any(a.requisition_task_id for a in open_alerts), "average_daily_use": average_daily_consumption(db, product),
        "created_at": product.created_at, "updated_at": product.updated_at,
    }
    if with_lots:
        out["lots"] = [lot_dict(db, l) for l in sorted(product.lots, key=lambda l: (ensure_utc(l.expiry_date) if l.expiry_date else datetime.max.replace(tzinfo=now().tzinfo)))]
        out["policies"] = [policy_dict(p) for p in policies_for(db, product)]
        out["alerts"] = [alert_dict(db, a) for a in open_alerts]
        recent = db.scalars(select(pm.MedicationAdministration).where(pm.MedicationAdministration.inventory_item_id == product.inventory_item_id)
                            .order_by(pm.MedicationAdministration.administered_at.desc()).limit(20)).all()
        out["administrations"] = [administration_dict(db, a) for a in recent]
    return out


def dashboard(db: Session, farm_id: str, *, include_inactive: bool = False) -> list[dict]:
    stmt = select(pm.MedicineProduct).where(pm.MedicineProduct.farm_id == farm_id)
    if not include_inactive:
        stmt = stmt.where(pm.MedicineProduct.active.is_(True))
    rows = [product_dict(db, p) for p in db.scalars(stmt)]
    order = {"OUT": 0, "CRITICAL": 1, "LOW": 2, "OK": 3}
    rows.sort(key=lambda r: (0 if (r["policy"] or {}).get("essential") else 1, order.get(r["status"], 9), r["name"]))
    return rows


def summary(db: Session, farm_id: str) -> dict:
    rows = dashboard(db, farm_id)
    alerts = db.scalars(select(pm.PharmacyStockAlert).where(pm.PharmacyStockAlert.farm_id == farm_id, pm.PharmacyStockAlert.status != "resolved")).all()
    by_type: dict[str, int] = {}
    for a in alerts:
        by_type[a.alert_type] = by_type.get(a.alert_type, 0) + 1
    by_status = {s: sum(1 for r in rows if r["status"] == s) for s in ("OK", "LOW", "CRITICAL", "OUT")}
    return {
        "medicines": len(rows), "essential": sum(1 for r in rows if (r["policy"] or {}).get("essential")), "by_status": by_status,
        "open_alerts": len(alerts), "unseen_alerts": sum(1 for a in alerts if a.status == "open"), "alerts_by_type": by_type,
        "expiring_soon": sum(1 for r in rows if r["expiring_quantity"] > 0), "storage_exceptions": sum(1 for r in rows if r["storage_exception"]),
        "open_requisitions": sum(1 for r in rows if r["open_requisition"]),
    }


def pharmacy_signals(db: Session, farm_id: str) -> list:
    """Open pharmacy alerts for the notification bell (logistics, under
    the inventory module). Acknowledged ones leave the bell, not the list."""
    from app.services.signals_service import Signal  # local import: signals imports this module

    out = []
    for a in db.scalars(select(pm.PharmacyStockAlert).where(pm.PharmacyStockAlert.farm_id == farm_id, pm.PharmacyStockAlert.status == "open")):
        item = db.get(models.InventoryItem, a.inventory_item_id)
        out.append(Signal(
            source_type="pharmacy_stock_alert", source_id=a.id, module_code=perms.INVENTORY, notification_type=f"pharmacy_{a.alert_type.lower()}",
            title=f"{item.name if item else 'Medicine'}: {a.alert_type.replace('_', ' ').lower()}", description=a.explanation[:300], priority=a.severity,
            entity_type="medicine_product", entity_id=a.inventory_item_id,
            metadata={"alert_id": a.id, "alert_type": a.alert_type, "eligible": a.eligible_available_base, "recommended_reorder": a.recommended_reorder_base},
        ))
    return out
