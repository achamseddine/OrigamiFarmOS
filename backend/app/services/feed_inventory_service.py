"""Feed stock: lots, availability, issue and receipt (feed architecture
§3, §25, §26).

The balance is the ledger. Every kilogram that moves is an
`inventory_transactions` row naming its lot; `inventory_items.current_qty`
and `feed_lots.quantity_on_hand` are maintained from those rows and never
edited directly. Availability is derived the same way every time:

    on hand
    − quarantined / blocked / recalled / expired lots
    − reserved by allocations for another purpose
    = available for this use

Issuing stock answers the four questions of §35 in order: do we have it,
is it reserved, may this subject have it (the policy service), and — for
the forecast — will enough remain.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import feed_models as fm
from app.domain import models
from app.feeding import catalog, uom
from app.repositories.base import ensure_utc, new_id, now, write_event


class FeedError(Exception):
    """A rule of the feed architecture refused the operation. Carries the
    HTTP status the API layer should answer with and a sentence written for
    the farmer, not the log."""

    def __init__(self, message: str, status_code: int = 422):
        super().__init__(message)
        self.message = message
        self.status_code = status_code


@dataclass
class Purpose:
    """Who or what stock is being issued for — matched against allocations
    so reserved stock is only drawn by the purpose it was reserved for."""

    species_code: str | None = None
    subject_type: str | None = None
    subject_id: str | None = None
    feeding_program_id: str | None = None
    label: str = ""


@dataclass
class Draw:
    """One lot's contribution to an issue."""

    lot: fm.FeedLot | None
    quantity: float
    unit: str
    unit_cost: float | None

    @property
    def cost(self) -> float | None:
        return None if self.unit_cost is None else round(self.quantity * self.unit_cost, 4)


@dataclass
class Availability:
    product_id: str
    unit: str
    on_hand: float
    unusable: float
    reserved: float
    available: float
    lots: list[dict] = field(default_factory=list)
    unusable_by_status: dict[str, float] = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {
            "feed_product_id": self.product_id,
            "unit": self.unit,
            "on_hand": round(self.on_hand, 3),
            "unusable": round(self.unusable, 3),
            "unusable_by_status": {k: round(v, 3) for k, v in self.unusable_by_status.items()},
            "reserved": round(self.reserved, 3),
            "available": round(self.available, 3),
            "lots": self.lots,
        }


# ------------------------------------------------------------- products
def get_product(db: Session, product_id: str, farm_id: str) -> fm.FeedProduct:
    product = db.get(fm.FeedProduct, product_id)
    if product is None or product.farm_id != farm_id:
        raise FeedError("Feed product not found", 404)
    return product


def get_lot(db: Session, lot_id: str, farm_id: str) -> fm.FeedLot:
    lot = db.get(fm.FeedLot, lot_id)
    if lot is None or lot.farm_id != farm_id:
        raise FeedError("Feed lot not found", 404)
    return lot


def product_for_item(db: Session, item_id: str) -> fm.FeedProduct | None:
    return db.scalar(select(fm.FeedProduct).where(fm.FeedProduct.inventory_item_id == item_id))


def slug(name: str) -> str:
    return re.sub(r"[^A-Z0-9]+", "-", name.upper()).strip("-")[:50] or "FEED"


def unique_code(db: Session, farm_id: str, base: str) -> str:
    code, n = base, 2
    while db.scalar(select(fm.FeedProduct.id).where(fm.FeedProduct.farm_id == farm_id, fm.FeedProduct.code == code)):
        code = f"{base}-{n}"
        n += 1
    return code


def ensure_product_for_item(
    db: Session,
    item: models.InventoryItem,
    *,
    is_ingredient: bool = True,
    is_feedable: bool = True,
    source_type: str = "purchased",
    category: str | None = None,
    created_by: str | None = None,
) -> fm.FeedProduct:
    """The feed-side master for an inventory item that predates it. Stock
    already on hand becomes an `opening_balance` lot so the ledger and the
    lots agree from the first day."""
    product = product_for_item(db, item.id)
    if product is None:
        product = fm.FeedProduct(
            id=new_id(),
            farm_id=item.farm_id,
            code=unique_code(db, item.farm_id, slug(item.name)),
            name=item.name,
            source_type=source_type,
            is_ingredient=is_ingredient,
            is_feedable=is_feedable,
            category=category or (item.category or "").lower() or None,
            unit=uom.normalise(item.unit),
            inventory_item_id=item.id,
            default_unit_cost=item.unit_cost,
            status="active",
            created_at=now(),
        )
        db.add(product)
        db.flush()
    reconcile_opening_balance(db, product, item, created_by=created_by)
    return product


def reconcile_opening_balance(db: Session, product: fm.FeedProduct, item: models.InventoryItem, *, created_by: str | None) -> None:
    """Stock an item held before lots existed becomes its opening lot. Runs
    only for a product with no lots at all — once lots exist, the services
    keep the item balance and the lots in step, and a difference would be
    a bug to surface, not a gap to paper over."""
    if product.lots:
        return
    gap = item.current_qty or 0
    if gap <= 0.0005:
        return
    lot = fm.FeedLot(
        id=new_id(),
        farm_id=product.farm_id,
        feed_product_id=product.id,
        lot_code=_unique_lot_code(db, product.farm_id, f"{product.code}-OPENING"),
        source_type="opening_balance",
        supplier_label=item.supplier_label,
        received_at=item.last_purchase or now(),
        received_quantity=gap,
        accepted_quantity=gap,
        quantity_on_hand=gap,
        unit=product.unit,
        unit_cost=item.unit_cost,
        status="active",
        notes="Opening balance carried over from the inventory item.",
        created_by=created_by,
        created_at=now(),
    )
    db.add(lot)
    product.lots.append(lot)
    db.flush()


def create_product(
    db: Session,
    farm_id: str,
    *,
    code: str | None,
    name: str,
    name_ar: str | None = None,
    unit: str = "kg",
    source_type: str = "purchased",
    is_ingredient: bool = True,
    is_feedable: bool = False,
    category: str | None = None,
    unit_cost: float | None = None,
    supplier_id: str | None = None,
    supplier_label: str | None = None,
    reorder_level: float = 0,
    opening_quantity: float = 0,
    notes: str | None = None,
    created_by: str | None = None,
) -> fm.FeedProduct:
    if source_type not in catalog.PRODUCT_SOURCES:
        raise FeedError(f"source_type must be one of {list(catalog.PRODUCT_SOURCES)}")
    if not (is_ingredient or is_feedable):
        raise FeedError("A feed product must be an ingredient, feedable, or both.")
    unit = uom.normalise(unit)
    item = models.InventoryItem(
        id=new_id(),
        farm_id=farm_id,
        name=name,
        category=(category or "feed").capitalize(),
        unit=unit,
        current_qty=0,
        reorder_level=reorder_level,
        supplier_id=supplier_id,
        supplier_label=supplier_label,
        unit_cost=unit_cost,
    )
    db.add(item)
    db.flush()
    product = fm.FeedProduct(
        id=new_id(),
        farm_id=farm_id,
        code=unique_code(db, farm_id, slug(code or name)),
        name=name,
        name_ar=name_ar,
        source_type=source_type,
        is_ingredient=is_ingredient,
        is_feedable=is_feedable,
        category=category,
        unit=unit,
        inventory_item_id=item.id,
        default_unit_cost=unit_cost,
        status="active",
        notes=notes,
        created_at=now(),
    )
    db.add(product)
    db.flush()
    if opening_quantity and opening_quantity > 0:
        receive(
            db, product, quantity=opening_quantity, unit=unit, unit_cost=unit_cost, supplier_id=supplier_id,
            supplier_label=supplier_label, lot_code=f"{product.code}-OPENING", source_type="opening_balance",
            notes="Opening balance", user_id=created_by,
        )
    return product


# ------------------------------------------------------------------ lots
def _unique_lot_code(db: Session, farm_id: str, base: str) -> str:
    code, n = base, 2
    while db.scalar(select(fm.FeedLot.id).where(fm.FeedLot.farm_id == farm_id, fm.FeedLot.lot_code == code)):
        code = f"{base}-{n}"
        n += 1
    return code


def lot_expired(lot: fm.FeedLot, at: datetime | None = None) -> bool:
    return lot.expiry_date is not None and ensure_utc(lot.expiry_date) <= (at or now())


def refresh_lot_status(lot: fm.FeedLot) -> None:
    """Expiry and depletion are facts of the lot, not decisions — they are
    reflected on read so a lot that expired overnight is unusable this
    morning without anyone touching it."""
    if lot.status == "active" and lot_expired(lot):
        lot.status = "expired"
    elif lot.status == "active" and lot.quantity_on_hand <= 0.0005:
        lot.status = "depleted"
    elif lot.status == "depleted" and lot.quantity_on_hand > 0.0005:
        lot.status = "active"


def lot_usable(lot: fm.FeedLot) -> bool:
    refresh_lot_status(lot)
    return lot.status == "active" and lot.quantity_on_hand > 0


def unit_cost_of(lot: fm.FeedLot | None, product: fm.FeedProduct, item: models.InventoryItem | None) -> float | None:
    if lot is not None and lot.unit_cost is not None:
        return lot.unit_cost
    if item is not None and item.unit_cost is not None:
        return item.unit_cost
    return product.default_unit_cost


def receive(
    db: Session,
    product: fm.FeedProduct,
    *,
    quantity: float,
    unit: str | None = None,
    unit_cost: float | None = None,
    supplier_id: str | None = None,
    supplier_label: str | None = None,
    lot_code: str | None = None,
    source_type: str = "purchased",
    expiry_date: datetime | None = None,
    ordered_quantity: float | None = None,
    rejected_quantity: float = 0,
    reference: str | None = None,
    notes: str | None = None,
    received_at: datetime | None = None,
    feed_batch_id: str | None = None,
    user_id: str | None = None,
) -> fm.FeedLot:
    """Goods receipt (§26): what arrived, what was accepted, what was
    rejected — three separately auditable numbers. On-hand starts at the
    accepted quantity."""
    if quantity <= 0:
        raise FeedError("Received quantity must be greater than zero.")
    if rejected_quantity < 0 or rejected_quantity > quantity:
        raise FeedError("Rejected quantity must be between zero and the received quantity.")
    qty = uom.convert(quantity, unit or product.unit, product.unit)
    rejected = uom.convert(rejected_quantity, unit or product.unit, product.unit)
    accepted = qty - rejected
    item = db.get(models.InventoryItem, product.inventory_item_id)
    when = received_at or now()
    lot = fm.FeedLot(
        id=new_id(),
        farm_id=product.farm_id,
        feed_product_id=product.id,
        lot_code=_unique_lot_code(db, product.farm_id, lot_code or f"{product.code}-{when:%Y%m%d}"),
        source_type=source_type,
        supplier_id=supplier_id,
        supplier_label=supplier_label or (item.supplier_label if item else None),
        feed_batch_id=feed_batch_id,
        received_at=when,
        expiry_date=expiry_date,
        ordered_quantity=ordered_quantity,
        received_quantity=qty,
        accepted_quantity=accepted,
        rejected_quantity=rejected,
        quantity_on_hand=accepted,
        unit=product.unit,
        unit_cost=unit_cost if unit_cost is not None else (item.unit_cost if item else product.default_unit_cost),
        status="active" if accepted > 0 else "depleted",
        reference=reference,
        notes=notes,
        created_by=user_id,
        created_at=now(),
    )
    db.add(lot)
    # Keep the loaded collection coherent: availability and FIFO issue read
    # `product.lots`, and a lot that only exists as a row would leave a
    # phantom gap between the item balance and its lots.
    product.lots.append(lot)
    db.flush()
    if item is not None and accepted > 0:
        db.add(
            models.InventoryTransaction(
                id=new_id(), item_id=item.id, direction="in", quantity=accepted, unit_cost=lot.unit_cost,
                reason={"purchased": "purchase", "farm_produced": "production", "opening_balance": "opening_balance"}.get(source_type, source_type),
                linked_entity_type="feed_lot", linked_entity_id=lot.id, lot_id=lot.id, created_at=when,
            )
        )
        item.current_qty = (item.current_qty or 0) + accepted
        if source_type == "purchased":
            item.last_purchase = when
            if unit_cost is not None:
                item.unit_cost = unit_cost
    write_event(
        db, farm_id=product.farm_id, entity_type="feed_lot", entity_id=lot.id, event_type="feed_lot_received",
        payload={"feed_product_id": product.id, "lot_code": lot.lot_code, "received": qty, "accepted": accepted,
                 "rejected": rejected, "source_type": source_type, "unit": product.unit},
        created_by=user_id or "system",
    )
    return lot


def set_lot_status(db: Session, lot: fm.FeedLot, status: str, *, reason: str | None, user_id: str) -> fm.FeedLot:
    if status not in catalog.LOT_STATUSES:
        raise FeedError(f"status must be one of {list(catalog.LOT_STATUSES)}")
    previous = lot.status
    lot.status = status
    if status == "active":
        refresh_lot_status(lot)
    event = {
        "quarantined": "feed_lot_quarantined", "recalled": "feed_lot_recalled", "blocked": "feed_lot_blocked",
        "expired": "feed_lot_expired", "active": "feed_lot_released",
    }.get(status, "feed_lot_status_changed")
    write_event(
        db, farm_id=lot.farm_id, entity_type="feed_lot", entity_id=lot.id, event_type=event,
        payload={"from": previous, "to": lot.status, "reason": reason}, created_by=user_id,
    )
    return lot


# --------------------------------------------------------- availability
def _allocations(db: Session, product_id: str) -> list[fm.FeedAllocation]:
    return list(db.scalars(select(fm.FeedAllocation).where(
        fm.FeedAllocation.feed_product_id == product_id, fm.FeedAllocation.status == "active",
    )))


def allocation_remaining(alloc: fm.FeedAllocation) -> float:
    return max(alloc.allocated_quantity - alloc.consumed_quantity, 0)


def allocation_matches(alloc: fm.FeedAllocation, purpose: Purpose | None) -> bool:
    """A reservation is for a purpose; an issue for that purpose may draw on
    it. Every dimension the reservation names must be met by the purpose."""
    if purpose is None:
        return False
    if alloc.subject_id is not None:
        return alloc.subject_type == purpose.subject_type and alloc.subject_id == purpose.subject_id
    if alloc.feeding_program_id is not None and alloc.feeding_program_id != purpose.feeding_program_id:
        return False
    if alloc.species_code is not None and alloc.species_code != purpose.species_code:
        return False
    return True


def reserved_for_others(db: Session, product: fm.FeedProduct, purpose: Purpose | None, lot: fm.FeedLot | None = None) -> float:
    total = 0.0
    for alloc in _allocations(db, product.id):
        if lot is not None and alloc.lot_id not in (None, lot.id):
            continue
        if allocation_matches(alloc, purpose):
            continue
        total += uom.convert(allocation_remaining(alloc), alloc.unit, product.unit)
    return total


def availability(db: Session, product: fm.FeedProduct, purpose: Purpose | None = None) -> Availability:
    item = db.get(models.InventoryItem, product.inventory_item_id)
    if item is not None:
        reconcile_opening_balance(db, product, item, created_by=None)
    on_hand = 0.0
    unusable = 0.0
    by_status: dict[str, float] = {}
    lots = []
    for lot in product.lots:
        refresh_lot_status(lot)
        qty = max(lot.quantity_on_hand, 0)
        on_hand += qty
        if lot.status in catalog.LOT_UNUSABLE:
            unusable += qty
            by_status[lot.status] = by_status.get(lot.status, 0) + qty
        lots.append({
            "id": lot.id, "lot_code": lot.lot_code, "status": lot.status, "quantity_on_hand": round(lot.quantity_on_hand, 3),
            "unit": lot.unit, "unit_cost": lot.unit_cost, "received_at": lot.received_at, "expiry_date": lot.expiry_date,
            "source_type": lot.source_type, "supplier_label": lot.supplier_label, "feed_batch_id": lot.feed_batch_id,
        })
    reserved = reserved_for_others(db, product, purpose)
    usable = max(on_hand - unusable, 0)
    return Availability(
        product_id=product.id, unit=product.unit, on_hand=on_hand, unusable=unusable,
        reserved=min(reserved, usable), available=max(usable - reserved, 0), lots=lots, unusable_by_status=by_status,
    )


# ----------------------------------------------------------------- issue
def consume(
    db: Session,
    product: fm.FeedProduct,
    quantity: float,
    unit: str | None,
    *,
    reason: str,
    linked_entity_type: str,
    linked_entity_id: str,
    purpose: Purpose | None = None,
    lot_id: str | None = None,
    allow_negative: bool = False,
    user_id: str | None = None,
    occurred_at: datetime | None = None,
) -> list[Draw]:
    """Issues stock FIFO from usable lots, respecting reservations. Raises
    with the arithmetic when there is not enough: the farmer sees why
    ("400 kg on hand, 350 kg reserved for the dairy herd") instead of a bare
    refusal."""
    if quantity <= 0:
        raise FeedError("Quantity must be greater than zero.")
    qty = uom.convert(quantity, unit or product.unit, product.unit)
    item = db.get(models.InventoryItem, product.inventory_item_id)
    if item is not None:
        reconcile_opening_balance(db, product, item, created_by=user_id)

    if lot_id is not None:
        lot = get_lot(db, lot_id, product.farm_id)
        if lot.feed_product_id != product.id:
            raise FeedError(f"Lot {lot.lot_code} is not {product.name}.")
        if not lot_usable(lot):
            raise FeedError(f"Lot {lot.lot_code} is {lot.status} and cannot be issued without an authorised release.")
        candidates = [lot]
    else:
        candidates = sorted((l for l in product.lots if lot_usable(l)), key=lambda l: ensure_utc(l.received_at))

    avail = availability(db, product, purpose)
    if qty > avail.available + 0.0005 and not allow_negative:
        parts = [f"{avail.on_hand:.1f} {uom.describe(product.unit)} on hand"]
        if avail.unusable:
            parts.append(f"{avail.unusable:.1f} unusable ({', '.join(f'{k} {v:.0f}' for k, v in avail.unusable_by_status.items())})")
        if avail.reserved:
            parts.append(f"{avail.reserved:.1f} reserved for another purpose")
        raise FeedError(
            f"Not enough {product.name} for this use: {'; '.join(parts)} — {avail.available:.1f} {uom.describe(product.unit)} available, "
            f"{qty:.1f} requested. Pass allow_negative=true to override."
        )

    when = occurred_at or now()
    draws: list[Draw] = []
    remaining = qty
    for lot in candidates:
        if remaining <= 0.0005:
            break
        lot_free = max(lot.quantity_on_hand - reserved_for_others(db, product, purpose, lot), 0)
        take = min(lot_free, remaining)
        if take <= 0.0005:
            continue
        lot.quantity_on_hand -= take
        refresh_lot_status(lot)
        cost = unit_cost_of(lot, product, item)
        draws.append(Draw(lot=lot, quantity=take, unit=product.unit, unit_cost=cost))
        if item is not None:
            db.add(models.InventoryTransaction(
                id=new_id(), item_id=item.id, direction="out", quantity=take, unit_cost=cost, reason=reason,
                linked_entity_type=linked_entity_type, linked_entity_id=linked_entity_id, lot_id=lot.id, created_at=when,
            ))
        remaining -= take
    if remaining > 0.0005:
        # Only reachable with allow_negative: the override the tech spec
        # allows for inventory, recorded against no lot so the gap is visible.
        cost = unit_cost_of(None, product, item)
        draws.append(Draw(lot=None, quantity=remaining, unit=product.unit, unit_cost=cost))
        if item is not None:
            db.add(models.InventoryTransaction(
                id=new_id(), item_id=item.id, direction="out", quantity=remaining, unit_cost=cost, reason=reason,
                linked_entity_type=linked_entity_type, linked_entity_id=linked_entity_id, lot_id=None, created_at=when,
            ))
    if item is not None:
        item.current_qty = (item.current_qty or 0) - qty

    # Draw down the reservations this purpose holds.
    if purpose is not None:
        left = qty
        for alloc in _allocations(db, product.id):
            if left <= 0.0005:
                break
            if not allocation_matches(alloc, purpose):
                continue
            take = min(uom.convert(allocation_remaining(alloc), alloc.unit, product.unit), left)
            alloc.consumed_quantity += uom.convert(take, product.unit, alloc.unit)
            if allocation_remaining(alloc) <= 0.0005:
                alloc.status = "exhausted"
            left -= take
    write_event(
        db, farm_id=product.farm_id, entity_type="feed_product", entity_id=product.id, event_type="feed_inventory_consumed",
        payload={"quantity": qty, "unit": product.unit, "reason": reason, "for": f"{linked_entity_type}:{linked_entity_id}",
                 "lots": [d.lot.lot_code for d in draws if d.lot is not None]},
        created_by=user_id or "system",
    )
    return draws


def restore(db: Session, product: fm.FeedProduct, draws: list[tuple[str | None, float]], *, reason: str, linked_entity_type: str, linked_entity_id: str, user_id: str) -> None:
    """Puts issued stock back on the lots it came from — a reversed feeding
    event, a returned delivery. Written as `in` movements, never by editing
    the original `out`."""
    item = db.get(models.InventoryItem, product.inventory_item_id)
    total = 0.0
    for lot_id, quantity in draws:
        lot = db.get(fm.FeedLot, lot_id) if lot_id else None
        if lot is not None:
            lot.quantity_on_hand += quantity
            refresh_lot_status(lot)
        if item is not None:
            db.add(models.InventoryTransaction(
                id=new_id(), item_id=item.id, direction="in", quantity=quantity, unit_cost=lot.unit_cost if lot else None,
                reason=reason, linked_entity_type=linked_entity_type, linked_entity_id=linked_entity_id, lot_id=lot_id, created_at=now(),
            ))
        total += quantity
    if item is not None:
        item.current_qty = (item.current_qty or 0) + total


def adjust(
    db: Session,
    product: fm.FeedProduct,
    *,
    lot: fm.FeedLot | None,
    delta: float,
    reason: str,
    explanation: str,
    user_id: str,
    linked_entity_type: str | None = None,
    linked_entity_id: str | None = None,
) -> models.InventoryTransaction:
    """An auditable correction (§26, §33): a count, a spill, a return. The
    explanation is mandatory — an unexplained difference is a variance,
    never an adjustment."""
    if not explanation or not explanation.strip():
        raise FeedError("An adjustment needs an explanation — an unexplained difference stays a variance.")
    if delta == 0:
        raise FeedError("Adjustment quantity cannot be zero.")
    if reason not in ("adjustment", "waste", "return", "reconciliation_adjustment", "count_correction"):
        raise FeedError("reason must be adjustment, waste, return, count_correction or reconciliation_adjustment")
    item = db.get(models.InventoryItem, product.inventory_item_id)
    if lot is None:
        usable = [l for l in product.lots if lot_usable(l)]
        lot = usable[-1] if usable else (product.lots[-1] if product.lots else None)
    if lot is not None:
        lot.quantity_on_hand += delta
        refresh_lot_status(lot)
    tx = models.InventoryTransaction(
        id=new_id(), item_id=product.inventory_item_id, direction="in" if delta > 0 else "out", quantity=abs(delta),
        unit_cost=unit_cost_of(lot, product, item), reason=reason,
        linked_entity_type=linked_entity_type, linked_entity_id=linked_entity_id, lot_id=lot.id if lot else None, created_at=now(),
    )
    db.add(tx)
    if item is not None:
        item.current_qty = (item.current_qty or 0) + delta
    write_event(
        db, farm_id=product.farm_id, entity_type="feed_product", entity_id=product.id, event_type="feed_inventory_adjusted",
        payload={"delta": delta, "unit": product.unit, "reason": reason, "explanation": explanation, "lot_id": lot.id if lot else None},
        created_by=user_id,
    )
    return tx


# ----------------------------------------------------------- allocation
def allocate(
    db: Session,
    product: fm.FeedProduct,
    *,
    quantity: float,
    unit: str | None,
    lot_id: str | None = None,
    species_code: str | None = None,
    subject_type: str | None = None,
    subject_id: str | None = None,
    feeding_program_id: str | None = None,
    location_label: str | None = None,
    cost_centre: str | None = None,
    purpose: str | None = None,
    transferable: bool = False,
    user_id: str,
) -> fm.FeedAllocation:
    if quantity <= 0:
        raise FeedError("Allocated quantity must be greater than zero.")
    if not any([species_code, subject_id, feeding_program_id, location_label, cost_centre, purpose]):
        raise FeedError("An allocation must say what the stock is reserved for.")
    qty = uom.convert(quantity, unit or product.unit, product.unit)
    lot = get_lot(db, lot_id, product.farm_id) if lot_id else None
    avail = availability(db, product)
    free = avail.available
    if lot is not None:
        free = min(free, max(lot.quantity_on_hand - reserved_for_others(db, product, None, lot), 0))
    if qty > free + 0.0005:
        raise FeedError(
            f"Only {free:.1f} {uom.describe(product.unit)} of {product.name} is unreserved and usable; "
            f"{qty:.1f} requested."
        )
    alloc = fm.FeedAllocation(
        id=new_id(), farm_id=product.farm_id, feed_product_id=product.id, lot_id=lot.id if lot else None,
        species_code=species_code, subject_type=subject_type, subject_id=subject_id, feeding_program_id=feeding_program_id,
        location_label=location_label, cost_centre=cost_centre, purpose=purpose, allocated_quantity=qty, consumed_quantity=0,
        unit=product.unit, transferable=transferable, status="active", created_by=user_id, created_at=now(),
    )
    db.add(alloc)
    db.flush()
    write_event(
        db, farm_id=product.farm_id, entity_type="feed_allocation", entity_id=alloc.id, event_type="feed_allocation_created",
        payload={"feed_product_id": product.id, "quantity": qty, "unit": product.unit, "species_code": species_code,
                 "subject": f"{subject_type}:{subject_id}" if subject_id else None, "feeding_program_id": feeding_program_id},
        created_by=user_id,
    )
    return alloc


def release_allocation(db: Session, alloc: fm.FeedAllocation, *, user_id: str, reason: str | None = None) -> fm.FeedAllocation:
    if alloc.status != "active":
        raise FeedError("This allocation is no longer active.")
    alloc.status = "released"
    alloc.released_at = now()
    write_event(
        db, farm_id=alloc.farm_id, entity_type="feed_allocation", entity_id=alloc.id, event_type="feed_allocation_released",
        payload={"remaining": allocation_remaining(alloc), "reason": reason}, created_by=user_id,
    )
    return alloc


def transfer_allocation(
    db: Session,
    alloc: fm.FeedAllocation,
    *,
    quantity: float | None,
    species_code: str | None,
    subject_type: str | None,
    subject_id: str | None,
    feeding_program_id: str | None,
    purpose: str | None,
    authorised: bool,
    cross_species_allowed: bool,
    user_id: str,
) -> fm.FeedAllocation:
    """Moves part of a reservation to another purpose. Needs either an
    allocation marked transferable or an approver (the workflow of §25);
    crossing species also needs the product's policy to allow it."""
    if alloc.status != "active":
        raise FeedError("This allocation is no longer active.")
    if not (alloc.transferable or authorised):
        raise FeedError("This reservation is not transferable; an approver must authorise the reallocation.", 403)
    if species_code and alloc.species_code and species_code != alloc.species_code and not cross_species_allowed:
        raise FeedError(f"Cross-species transfer of this feed is prohibited by its usage policy ({alloc.species_code} → {species_code}).")
    remaining = allocation_remaining(alloc)
    qty = remaining if quantity is None else quantity
    if qty <= 0 or qty > remaining + 0.0005:
        raise FeedError(f"Transfer quantity must be between zero and the {remaining:.1f} {alloc.unit} remaining.")
    write_event(
        db, farm_id=alloc.farm_id, entity_type="feed_allocation", entity_id=alloc.id, event_type="feed_allocation_transfer_requested",
        payload={"quantity": qty, "to_species": species_code, "to_subject": f"{subject_type}:{subject_id}" if subject_id else None},
        created_by=user_id,
    )
    alloc.allocated_quantity -= qty
    if allocation_remaining(alloc) <= 0.0005:
        alloc.status = "released" if alloc.consumed_quantity <= 0.0005 else "exhausted"
        alloc.released_at = now()
    moved = fm.FeedAllocation(
        id=new_id(), farm_id=alloc.farm_id, feed_product_id=alloc.feed_product_id, lot_id=alloc.lot_id,
        species_code=species_code, subject_type=subject_type, subject_id=subject_id, feeding_program_id=feeding_program_id,
        location_label=alloc.location_label, cost_centre=alloc.cost_centre, purpose=purpose or alloc.purpose,
        allocated_quantity=qty, consumed_quantity=0, unit=alloc.unit, transferable=alloc.transferable, status="active",
        created_by=user_id, created_at=now(),
    )
    db.add(moved)
    db.flush()
    write_event(
        db, farm_id=alloc.farm_id, entity_type="feed_allocation", entity_id=moved.id, event_type="feed_allocation_transferred",
        payload={"from_allocation_id": alloc.id, "quantity": qty, "unit": alloc.unit}, created_by=user_id,
    )
    return moved


# ---------------------------------------------------------- traceability
def lot_trace(db: Session, lot: fm.FeedLot) -> dict:
    """Forward trace (§12): where a lot went — the batches it was mixed
    into, the lots those produced, the feedings that used it, and every
    animal or group exposed. And backward: if the lot came out of a batch,
    the ingredient lots that went in."""
    batches = list(db.scalars(select(fm.FeedBatchComponent).where(fm.FeedBatchComponent.lot_id == lot.id)))
    feedings = list(db.scalars(select(fm.FeedingEventComponent).where(fm.FeedingEventComponent.lot_id == lot.id)))
    exposed: dict[tuple[str, str], dict] = {}
    events_out = []
    for comp in feedings:
        event = db.get(fm.FeedingEvent, comp.event_id)
        if event is None or event.status == "reversed":
            continue
        key = (event.subject_type, event.subject_id)
        entry = exposed.setdefault(key, {"subject_type": event.subject_type, "subject_id": event.subject_id, "quantity": 0.0, "first": event.occurred_at, "last": event.occurred_at, "events": 0})
        entry["quantity"] += comp.quantity_offered
        entry["events"] += 1
        entry["first"] = min(entry["first"], event.occurred_at)
        entry["last"] = max(entry["last"], event.occurred_at)
        events_out.append({"event_id": event.id, "occurred_at": event.occurred_at, "subject_type": event.subject_type,
                           "subject_id": event.subject_id, "quantity": comp.quantity_offered, "unit": comp.unit})
    downstream_batches = []
    for comp in batches:
        batch = db.get(fm.FeedBatch, comp.batch_id)
        if batch is None:
            continue
        downstream_batches.append({"batch_id": batch.id, "batch_code": batch.batch_code, "status": batch.status,
                                   "quantity_used": comp.actual_quantity, "unit": comp.unit, "output_lot_id": batch.output_lot_id})
        # Second hop: feedings of the lot this batch produced.
        if batch.output_lot_id:
            out_lot = db.get(fm.FeedLot, batch.output_lot_id)
            if out_lot is not None:
                nested = lot_trace(db, out_lot)
                for e in nested["exposed_subjects"]:
                    key = (e["subject_type"], e["subject_id"])
                    entry = exposed.setdefault(key, {**e, "quantity": 0.0, "events": 0})
                    entry["quantity"] += e["quantity"]
                    entry["events"] += e["events"]
                events_out.extend(nested["feeding_events"])
    upstream = []
    if lot.feed_batch_id:
        batch = db.get(fm.FeedBatch, lot.feed_batch_id)
        if batch is not None:
            for comp in batch.components:
                src = db.get(fm.FeedLot, comp.lot_id) if comp.lot_id else None
                upstream.append({"feed_product_id": comp.feed_product_id, "lot_id": comp.lot_id, "lot_code": src.lot_code if src else None,
                                 "supplier_label": src.supplier_label if src else None, "quantity": comp.actual_quantity, "unit": comp.unit})
    for e in exposed.values():
        subj = db.get(models.Animal, e["subject_id"]) if e["subject_type"] == "animal" else db.get(models.Flock, e["subject_id"])
        e["name"] = getattr(subj, "name", None)
        e["species"] = getattr(subj, "species", None)
    return {
        "lot": {"id": lot.id, "lot_code": lot.lot_code, "feed_product_id": lot.feed_product_id, "status": lot.status,
                "source_type": lot.source_type, "supplier_label": lot.supplier_label, "received_at": lot.received_at,
                "quantity_on_hand": lot.quantity_on_hand, "unit": lot.unit, "feed_batch_id": lot.feed_batch_id},
        "upstream_ingredient_lots": upstream,
        "downstream_batches": downstream_batches,
        "feeding_events": sorted(events_out, key=lambda e: e["occurred_at"]),
        "exposed_subjects": sorted(exposed.values(), key=lambda e: -e["quantity"]),
    }
