"""A crop cycle from planting to its margin (master prompt Package 7;
database/CROPS-SCHEMA.md §4–§8).

    a growing unit (a field, a greenhouse, a tunnel, an orchard block)
      → a crop cycle (the crop planted there, with a farm-wide code)
      → the work done on it: inputs out of stock at their cost, labour
      → the water it was given, and the pumping cost when known
      → its harvests: sellable produce into stock, losses with their reason
      → its produce sold, out of stock, as sales of the farm
      → its margin: what its produce sold for, against what it cost

Nothing is kept on the side: the inputs are inventory movements (`out`,
linked to the work), the harvest is the existing harvest record and its
`in` movement, the sales are the farm's sales (Sales & Finance) linked to
the cycle, and the margin is read from those records each time. A cost
that is not known (an input without a price, labour not priced, pumping
not metered) is named as unknown, never counted as nothing.
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.record_time import CLOCK_TOLERANCE
from app.domain import crop_models as cm
from app.domain import models
from app.feeding import uom
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event
from app.services import finance_service as finance
from app.services.feed_inventory_service import FeedError

EPS = 1e-9
MODULE = "agriculture"
# Stock a crop may use: what the farm buys for its fields (not feed, not medicine, not produce).
NOT_CROP_INPUTS = ("produce", "feed", "medicine")


class CropError(FeedError):
    pass


def _locked_item(db: Session, item_id: str | None) -> models.InventoryItem | None:
    """The stock line, row-locked and read afresh: a copy this session already
    holds is refreshed (`populate_existing`), so the stock check never decides
    on a quantity another transaction has since taken."""
    return db.scalar(select(models.InventoryItem).where(models.InventoryItem.id == item_id)
                     .with_for_update().execution_options(populate_existing=True))


def is_crop_input(db: Session, item: models.InventoryItem) -> bool:
    """Seeds, fertiliser, plant treatments, supplies — not produce, and not
    stock the feed or the pharmacy ledger owns."""
    from app.domain import feed_models as fm
    from app.domain import pharmacy_models as pm

    if (item.category or "").strip().lower() in NOT_CROP_INPUTS:
        return False
    if db.scalar(select(fm.FeedProduct.id).where(fm.FeedProduct.inventory_item_id == item.id)):
        return False
    return db.scalar(select(pm.MedicineProduct.inventory_item_id).where(pm.MedicineProduct.inventory_item_id == item.id)) is None


def crop_inputs(db: Session, farm_id: str) -> list[dict]:
    """The stock a crop cycle can use, for the forms."""
    rows = db.scalars(select(models.InventoryItem).where(models.InventoryItem.farm_id == farm_id).order_by(models.InventoryItem.name))
    return [{"id": i.id, "name": i.name, "category": i.category, "unit": i.unit, "current_qty": i.current_qty, "unit_cost": i.unit_cost}
            for i in rows if is_crop_input(db, i)]


def get_cycle(db: Session, cycle_id: str, farm_id: str) -> models.CropPlanting:
    c = db.get(models.CropPlanting, cycle_id)
    if c is None or c.farm_id != farm_id:
        raise CropError("Crop cycle not found", 404)
    return c


def next_cycle_code(db: Session, farm_id: str, crop: models.Crop, planted: datetime | None) -> str:
    year = (ensure_utc(planted) if planted else now()).year
    stem = "".join(ch for ch in crop.name.upper() if ch.isalnum())[:4] or "CROP"
    n = (db.scalar(select(func.count(models.CropPlanting.id)).where(models.CropPlanting.farm_id == farm_id)) or 0) + 1
    while db.scalar(select(models.CropPlanting.id).where(models.CropPlanting.farm_id == farm_id, models.CropPlanting.cycle_code == f"{stem}-{year}-{n:03d}")):
        n += 1
    return f"{stem}-{year}-{n:03d}"


def _open(cycle: models.CropPlanting) -> None:
    if cycle.status == "closed" or cycle.closed_at is not None:
        raise CropError(f"Crop cycle {cycle.cycle_code or cycle.id} is closed: nothing more is recorded on it.", 409)


# ------------------------------------------------------------ the work
def record_operation(db: Session, user: models.User, cycle: models.CropPlanting, *, operation_type: str, completed_at: datetime | None = None,
                     labour_hours: float | None = None, labour_cost: float | None = None, inputs: list[dict] | None = None,
                     notes: str | None = None) -> cm.FieldOperation:
    """Work done on a crop cycle. Each input leaves stock by its own `out`
    movement at the item's cost; more than is in stock is refused (the
    item's row is locked, so two people cannot both take the last of it)."""
    _open(cycle)
    if operation_type not in cm.OPERATION_TYPES:
        raise CropError(f"operation_type must be one of {list(cm.OPERATION_TYPES)}")
    when = ensure_utc(completed_at) if completed_at else now()
    # Work queued on a tablet keeps its own time; that tablet's clock may run
    # a little ahead of the server's (app/core/record_time.py).
    if when > now() + CLOCK_TOLERANCE:
        raise CropError("Work cannot be recorded in the future.")
    when = min(when, now())
    if labour_hours is not None and labour_hours < 0 or labour_cost is not None and labour_cost < 0:
        raise CropError("Labour hours and cost cannot be negative.")
    op = cm.FieldOperation(id=new_id(), farm_id=cycle.farm_id, crop_planting_id=cycle.id, field_id=cycle.field_id, operation_type=operation_type,
                           completed_at=when, status="completed", labour_hours=labour_hours, labour_cost=labour_cost, performed_by=user.id,
                           notes=(notes or "").strip() or None, created_by=user.id, created_at=now())
    db.add(op)
    seen: set[str] = set()
    for raw in inputs or []:
        item = _locked_item(db, raw.get("inventory_item_id"))
        if item is None or item.farm_id != cycle.farm_id:
            raise CropError("Stock item not found", 404)
        if item.id in seen:
            raise CropError(f"{item.name} is given twice on one piece of work.")
        seen.add(item.id)
        if not is_crop_input(db, item):
            raise CropError(f"{item.name} is {item.category or 'not a crop input'}: a crop uses seeds, fertiliser, plant treatments and supplies.")
        qty = float(raw.get("quantity") or 0)
        if qty <= 0:
            raise CropError(f"Give how much {item.name} was used.")
        unit = raw.get("unit") or item.unit
        try:
            qty_item = uom.convert(qty, unit, item.unit)
        except Exception as exc:  # noqa: BLE001 - a unit pair that cannot convert
            raise CropError(f"{unit} is not a unit {item.name} can be counted in ({item.unit}).") from exc
        if qty_item > (item.current_qty or 0) + EPS:
            raise CropError(f"Not enough {item.name}: {item.current_qty:g} {item.unit} in stock, {qty_item:g} {item.unit} used. "
                            "Record the delivery first.")
        unit_cost = item.unit_cost
        cost = round(qty_item * unit_cost, 4) if unit_cost is not None else None
        tx = models.InventoryTransaction(id=new_id(), item_id=item.id, direction="out", quantity=qty_item, unit_cost=unit_cost, reason="crop_input",
                                         linked_entity_type="field_operation", linked_entity_id=op.id, created_at=when)
        db.add(tx)
        item.current_qty = (item.current_qty or 0) - qty_item
        op.inputs.append(cm.FieldOperationInput(id=new_id(), inventory_item_id=item.id, quantity=qty_item, unit=item.unit, unit_cost=unit_cost,
                                                cost=cost, inventory_transaction_id=tx.id))
    db.flush()
    write_event(db, farm_id=cycle.farm_id, entity_type="crop_cycle", entity_id=cycle.id, event_type="field_operation_completed",
                payload={"operation_id": op.id, "operation_type": operation_type, "inputs": [{"item": i.inventory_item_id, "quantity": i.quantity}
                                                                                              for i in op.inputs]}, created_by=user.id)
    write_audit_log(db, farm_id=cycle.farm_id, user_id=user.id, action="field_operation_recorded", entity_type="field_operation", entity_id=op.id,
                    module_code=MODULE, summary=f"{operation_type} on {cycle.cycle_code or cycle.id}: {len(op.inputs)} input(s)"[:500])
    return op


def reverse_operation(db: Session, user: models.User, op: cm.FieldOperation, *, reason: str) -> cm.FieldOperation:
    """A piece of work recorded by mistake: its inputs go back into stock by
    `in` movements; the work stays on file, reversed, with the reason."""
    if not (reason or "").strip():
        raise CropError("Say why the work is reversed.")
    if op.status == "reversed":
        raise CropError("This work is already reversed.", 409)
    for i in op.inputs:
        item = _locked_item(db, i.inventory_item_id)
        db.add(models.InventoryTransaction(id=new_id(), item_id=item.id, direction="in", quantity=i.quantity, unit_cost=i.unit_cost,
                                           reason="crop_input_reversed", linked_entity_type="field_operation", linked_entity_id=op.id, created_at=now()))
        item.current_qty = (item.current_qty or 0) + i.quantity
    op.status = "reversed"
    op.notes = ((op.notes or "") + f"\nReversed: {reason.strip()}").strip()
    write_audit_log(db, farm_id=op.farm_id, user_id=user.id, action="field_operation_reversed", entity_type="field_operation", entity_id=op.id,
                    module_code=MODULE, summary=f"Work reversed: {reason.strip()}"[:500])
    write_event(db, farm_id=op.farm_id, entity_type="crop_cycle", entity_id=op.crop_planting_id, event_type="field_operation_reversed",
                payload={"operation_id": op.id, "reason": reason.strip()}, created_by=user.id)
    return op


def record_irrigation(db: Session, user: models.User, cycle: models.CropPlanting, *, started_at: datetime, ended_at: datetime | None = None,
                      water_quantity: float | None = None, unit: str | None = "m3", source_code: str | None = None,
                      energy_cost: float | None = None) -> cm.IrrigationEvent:
    _open(cycle)
    start = ensure_utc(started_at)
    end = ensure_utc(ended_at) if ended_at else None
    if start > now() + CLOCK_TOLERANCE or (end is not None and (end < start or end > now() + CLOCK_TOLERANCE)):
        raise CropError("Irrigation ends after it starts, and not in the future.")
    if water_quantity is not None and water_quantity < 0 or energy_cost is not None and energy_cost < 0:
        raise CropError("Water and its cost cannot be negative.")
    if unit not in (None, "m3", "L"):
        raise CropError("Water is measured in m3 or L.")
    ev = cm.IrrigationEvent(id=new_id(), farm_id=cycle.farm_id, crop_planting_id=cycle.id, field_id=cycle.field_id, started_at=start, ended_at=end,
                            water_quantity=water_quantity, unit=unit, source_code=(source_code or "").strip() or None, energy_cost=energy_cost,
                            recorded_by=user.id, recorded_at=now())
    db.add(ev)
    db.flush()
    write_event(db, farm_id=cycle.farm_id, entity_type="crop_cycle", entity_id=cycle.id, event_type="irrigation_recorded",
                payload={"irrigation_id": ev.id, "water_quantity": water_quantity, "unit": unit}, created_by=user.id)
    return ev


# ------------------------------------------------------------ the sales
def produce_item(db: Session, cycle: models.CropPlanting) -> models.InventoryItem | None:
    """The stock line its produce is held on (created by the first harvest)."""
    crop = db.get(models.Crop, cycle.crop_id)
    if crop is None:
        return None
    return db.scalar(select(models.InventoryItem).where(models.InventoryItem.farm_id == cycle.farm_id, models.InventoryItem.name == crop.name,
                                                        models.InventoryItem.category == "produce"))


def sell_produce(db: Session, user: models.User, cycle: models.CropPlanting, *, quantity: float, unit_price: float, currency: str = "USD",
                 exchange_rate: float | None = None, sold_at: datetime | None = None, buyer_name: str | None = None, payment_status: str = "paid",
                 reference: str | None = None, confirm_duplicate: bool = False) -> models.Sale:
    """Produce of this cycle sold: a sale of the farm (Sales & Finance,
    crops) linked to the cycle, and an `out` movement from its stock — more
    than is in stock is refused."""
    if quantity <= 0 or unit_price < 0:
        raise CropError("Give the quantity sold and a price that is not negative.")
    crop = db.get(models.Crop, cycle.crop_id)
    item = produce_item(db, cycle)
    if item is not None:
        item = _locked_item(db, item.id)
    if item is None or (item.current_qty or 0) + EPS < quantity:
        have = 0 if item is None else item.current_qty
        raise CropError(f"Not enough {crop.name if crop else 'produce'} in stock: {have:g} {item.unit if item else 'kg'}, {quantity:g} sold. "
                        "Record the harvest first.")
    sale = finance.record_sale(db, user, product_type="produce", product_label=crop.name if crop else "Produce", quantity=quantity, unit=item.unit,
                               unit_price=unit_price, total=None, currency=currency, exchange_rate=exchange_rate, sold_at=sold_at, customer_id=None,
                               buyer_name=buyer_name, payment_status=payment_status, reference=reference,
                               notes=f"Crop cycle {cycle.cycle_code or cycle.id}", activity="crops", confirm_duplicate=confirm_duplicate)
    sale.crop_planting_id = cycle.id
    db.add(models.InventoryTransaction(id=new_id(), item_id=item.id, direction="out", quantity=quantity, unit_cost=None, reason="sale",
                                       linked_entity_type="sale", linked_entity_id=sale.id, created_at=ensure_utc(sale.sold_at)))
    item.current_qty = (item.current_qty or 0) - quantity
    db.flush()
    write_event(db, farm_id=cycle.farm_id, entity_type="crop_cycle", entity_id=cycle.id, event_type="crop_produce_sold",
                payload={"sale_id": sale.id, "quantity": quantity, "amount": sale.amount}, created_by=user.id)
    return sale


def close_cycle(db: Session, user: models.User, cycle: models.CropPlanting, *, notes: str | None = None) -> models.CropPlanting:
    if cycle.closed_at is not None:
        raise CropError("This crop cycle is already closed.", 409)
    cycle.status, cycle.stage, cycle.closed_at = "closed", "closed", now()
    write_audit_log(db, farm_id=cycle.farm_id, user_id=user.id, action="crop_cycle_closed", entity_type="crop_planting", entity_id=cycle.id,
                    module_code=MODULE, summary=f"Crop cycle {cycle.cycle_code or cycle.id} closed{': ' + notes.strip() if notes and notes.strip() else ''}"[:500])
    write_event(db, farm_id=cycle.farm_id, entity_type="crop_cycle", entity_id=cycle.id, event_type="crop_cycle_closed", payload={}, created_by=user.id)
    return cycle


# ------------------------------------------------------------ the margin
def margin(db: Session, cycle: models.CropPlanting) -> dict:
    """What this cycle's produce sold for, against what it cost — read from
    its work, inputs, irrigation, harvests, sales and linked expenses."""
    ops = list(db.scalars(select(cm.FieldOperation).where(cm.FieldOperation.crop_planting_id == cycle.id, cm.FieldOperation.status == "completed")))
    inputs_cost = 0.0
    unpriced_inputs: list[str] = []
    by_item: dict[str, dict] = {}
    for op in ops:
        for i in op.inputs:
            item = db.get(models.InventoryItem, i.inventory_item_id)
            row = by_item.setdefault(i.inventory_item_id, {"inventory_item_id": i.inventory_item_id, "name": item.name if item else i.inventory_item_id,
                                                           "category": item.category if item else None, "quantity": 0.0, "unit": i.unit, "cost": 0.0})
            row["quantity"] += i.quantity
            if i.cost is None:
                if row["name"] not in unpriced_inputs:
                    unpriced_inputs.append(row["name"])
            else:
                row["cost"] += i.cost
                inputs_cost += i.cost
    labour_hours = sum(op.labour_hours or 0 for op in ops)
    labour_cost = sum(op.labour_cost or 0 for op in ops)
    unpriced_labour = sum(1 for op in ops if (op.labour_hours or 0) > 0 and op.labour_cost is None)
    irrigation = list(db.scalars(select(cm.IrrigationEvent).where(cm.IrrigationEvent.crop_planting_id == cycle.id)))
    water_m3 = sum((e.water_quantity or 0) / (1000 if e.unit == "L" else 1) for e in irrigation)
    energy_cost = sum(e.energy_cost or 0 for e in irrigation)
    unpriced_irrigation = sum(1 for e in irrigation if e.energy_cost is None)
    expenses = list(db.scalars(select(models.Expense).where(models.Expense.farm_id == cycle.farm_id, models.Expense.status == "recorded",
                                                            models.Expense.linked_entity_type == "crop_planting",
                                                            models.Expense.linked_entity_id == cycle.id)))
    other_cost = sum(e.amount for e in expenses)
    harvests = list(db.scalars(select(models.HarvestRecord).where(models.HarvestRecord.crop_planting_id == cycle.id)))
    harvested = sum(h.quantity for h in harvests)
    lost = sum(h.waste_qty or 0 for h in harvests)
    sales = list(db.scalars(select(models.Sale).where(models.Sale.crop_planting_id == cycle.id, models.Sale.status.in_(("recorded", "reversal")))))
    revenue = sum(s.amount for s in sales)
    sold = sum((s.quantity or 0) * (-1 if s.status == "reversal" else 1) for s in sales)
    costs = inputs_cost + labour_cost + energy_cost + other_cost
    unknown = []
    if unpriced_inputs:
        unknown.append("inputs_without_cost")
    if unpriced_labour:
        unknown.append("labour_not_priced")
    if unpriced_irrigation:
        unknown.append("irrigation_energy_not_known")
    crop = db.get(models.Crop, cycle.crop_id)
    field = db.get(models.Field, cycle.field_id)
    item = produce_item(db, cycle)
    return {
        "crop_cycle_id": cycle.id, "cycle_code": cycle.cycle_code, "crop": crop.name if crop else None, "field": field.name if field else None,
        "unit_type": field.unit_type if field else None, "status": cycle.status,
        "planted_at": ensure_utc(cycle.planted_date).isoformat() if cycle.planted_date else None,
        "closed_at": ensure_utc(cycle.closed_at).isoformat() if cycle.closed_at else None,
        "harvest": {"harvested": round(harvested, 3), "lost": round(lost, 3), "sellable": round(harvested - lost, 3), "sold": round(sold, 3),
                    "unit": harvests[0].unit if harvests else (item.unit if item else "kg"), "harvests": len(harvests),
                    "loss_reasons": sorted({h.loss_reason for h in harvests if h.loss_reason})},
        "revenue": round(revenue, 2),
        "costs": {"inputs": round(inputs_cost, 2), "labour": round(labour_cost, 2), "irrigation_energy": round(energy_cost, 2),
                  "other_expenses": round(other_cost, 2), "total_known": round(costs, 2)},
        "inputs": [{**r, "quantity": round(r["quantity"], 3), "cost": round(r["cost"], 2)} for r in by_item.values()],
        "labour_hours": round(labour_hours, 2), "water_m3": round(water_m3, 3),
        "margin": round(revenue - costs, 2),
        "cost_per_unit_harvested": round(costs / harvested, 4) if harvested > EPS else None,
        "unknown": unknown, "unpriced_inputs": unpriced_inputs,
    }


def operation_dict(op: cm.FieldOperation) -> dict:
    return {"id": op.id, "crop_planting_id": op.crop_planting_id, "operation_type": op.operation_type, "completed_at": ensure_utc(op.completed_at).isoformat(),
            "status": op.status, "labour_hours": op.labour_hours, "labour_cost": op.labour_cost, "notes": op.notes,
            "inputs": [{"inventory_item_id": i.inventory_item_id, "quantity": i.quantity, "unit": i.unit, "unit_cost": i.unit_cost, "cost": i.cost}
                       for i in op.inputs]}


def irrigation_dict(e: cm.IrrigationEvent) -> dict:
    return {"id": e.id, "crop_planting_id": e.crop_planting_id, "started_at": ensure_utc(e.started_at).isoformat(),
            "ended_at": ensure_utc(e.ended_at).isoformat() if e.ended_at else None, "water_quantity": e.water_quantity, "unit": e.unit,
            "source_code": e.source_code, "energy_cost": e.energy_cost}
