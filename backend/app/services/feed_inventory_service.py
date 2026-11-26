"""Feed stock: lots, availability, issue and receipt (feed architecture
§3, §25, §26; database/INVENTORY-SCHEMA §1).

The balance is the ledger (v0.8.4 makes this exact). Every kilogram that
moves is one `inventory_transactions` row, and every row is posted by
`_post`, the only function that changes a feed quantity:

    lot balance       = Σ signed movements naming the lot           (never < 0)
    untraced balance  = Σ signed movements of the item naming no lot (never > 0)
    on hand           = Σ signed movements of the item
                      = Σ lot balances + untraced balance

`feed_lots.quantity_on_hand` and `inventory_items.current_qty` are
projections of those sums, written by `_post` in the same transaction as
the row and checked by `integrity_report` (a stored figure that disagrees
with its rows is a defect to report, never a gap to paper over).

A movement names no lot only in three cases: stock recorded before lots
existed, the movement that carried that stock into its opening lot, and a
stock exception (`feed_stock_exceptions`). An exception is the one way
feed leaves untraced — an approved override with a reason — and it stays
open, reducing what is available, until it is reconciled (a count, the
lot it really came from, stock that was there unrecorded, or the feeding
undone). Availability is derived the same way every time:

    usable lot stock (not quarantined / blocked / recalled / expired)
    − issued untraced and not yet reconciled (open exceptions)
    − reserved by allocations for another purpose
    = available for this use

Every movement first locks the product's inventory-item row (`lock_stock`,
SELECT … FOR UPDATE on PostgreSQL), so two people feeding the last 10 kg at
the same moment are served one after the other: the second sees what the
first left.

Issuing stock answers the four questions of §35 in order: do we have it,
is it reserved, may this subject have it (the policy service), and — for
the forecast — will enough remain.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from sqlalchemy import case, func, select
from sqlalchemy.orm import Session
from sqlalchemy.orm.attributes import set_committed_value

from app.domain import feed_models as fm
from app.domain import models
from app.feeding import catalog, uom
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event


class FeedError(Exception):
    """A rule of the feed architecture refused the operation. Carries the
    HTTP status the API layer should answer with and a sentence written for
    the farmer, not the log."""

    def __init__(self, message: str, status_code: int = 422, *, code: str | None = None):
        super().__init__(message)
        self.message = message
        self.status_code = status_code
        # A stable name for the rule that refused it, sent beside `detail`
        # so a client can say it in the person's language without reading
        # the English sentence (v0.8.7).
        self.code = code


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
    """One lot's contribution to an issue — or, with no lot, the part an
    approved stock exception ([exception_id]) covered."""

    lot: fm.FeedLot | None
    quantity: float
    unit: str
    unit_cost: float | None
    exception_id: str | None = None

    @property
    def cost(self) -> float | None:
        return None if self.unit_cost is None else round(self.quantity * self.unit_cost, 4)


@dataclass
class Availability:
    product_id: str
    unit: str
    # The ledger: Σ every movement = lot_on_hand − untraced.
    on_hand: float
    unusable: float
    reserved: float
    available: float
    lots: list[dict] = field(default_factory=list)
    unusable_by_status: dict[str, float] = field(default_factory=dict)
    # Σ lot balances, and what was issued with no lot and is not yet
    # reconciled (a positive number; on_hand = lot_on_hand − untraced).
    lot_on_hand: float = 0.0
    untraced: float = 0.0
    open_exceptions: int = 0

    def to_dict(self) -> dict:
        return {
            "feed_product_id": self.product_id,
            "unit": self.unit,
            "on_hand": round(self.on_hand, 3),
            "lot_on_hand": round(self.lot_on_hand, 3),
            "untraced": round(self.untraced, 3),
            "open_exceptions": self.open_exceptions,
            "unusable": round(self.unusable, 3),
            "unusable_by_status": {k: round(v, 3) for k, v in self.unusable_by_status.items()},
            "reserved": round(self.reserved, 3),
            "available": round(self.available, 3),
            "lots": self.lots,
        }


# Quantities closer than this are equal (a gram of a kilogram unit).
EPS = 0.0005


@dataclass
class Override:
    """An authorised decision to issue more than the stock on record
    (INVENTORY-SCHEMA §8: negative stock is blocked by default; an approved
    override is the exception). The API builds it only for someone with
    Feed or Inventory approve; the reason is required the moment the
    override is actually used, and it is kept on the exception record."""

    reason: str | None
    approved_by: str
    requested_by: str | None = None
    approval_request_id: str | None = None


# ------------------------------------------------------------- the ledger
def lock_stock(db: Session, *products: fm.FeedProduct) -> None:
    """Serialises every movement of these products' stock. Takes the
    inventory-item rows FOR UPDATE (in id order, so two operations over the
    same products cannot deadlock) and then re-reads the lots and
    reservations, so what this transaction decides on is what the last
    committed movement left — never a copy read before someone else issued
    the same kilos. Pending changes of this session are flushed first so
    the re-read cannot discard them. SQLite has no row locks; it takes one
    write lock for the whole database, which serialises writers the same
    way."""
    ids = sorted({p.inventory_item_id for p in products if p is not None and p.inventory_item_id})
    if not ids:
        return
    db.flush()
    db.execute(
        select(models.InventoryItem).where(models.InventoryItem.id.in_(ids)).order_by(models.InventoryItem.id)
        .with_for_update().execution_options(populate_existing=True)
    ).scalars().all()
    for product in products:
        if product is None:
            continue
        lots = list(db.scalars(
            select(fm.FeedLot).where(fm.FeedLot.feed_product_id == product.id).order_by(fm.FeedLot.received_at)
            .execution_options(populate_existing=True)
        ))
        set_committed_value(product, "lots", lots)
        db.execute(select(fm.FeedAllocation).where(fm.FeedAllocation.feed_product_id == product.id)
                   .execution_options(populate_existing=True)).scalars().all()


def _signed(direction: str, quantity: float) -> float:
    return quantity if direction == "in" else -quantity


def _post(
    db: Session,
    product: fm.FeedProduct,
    item: models.InventoryItem | None,
    *,
    lot: fm.FeedLot | None,
    direction: str,
    quantity: float,
    reason: str,
    linked_entity_type: str | None,
    linked_entity_id: str | None,
    unit_cost: float | None,
    when: datetime | None = None,
    user_id: str | None = None,
    exception: fm.FeedStockException | None = None,
    correlation_id: str | None = None,
) -> models.InventoryTransaction | None:
    """Posts one movement and moves the two projections with it. The only
    writer of `feed_lots.quantity_on_hand` and `inventory_items.current_qty`
    for feed. A lot is never taken below zero; stock that is not there
    leaves through a stock exception, never through a lot."""
    if direction not in ("in", "out"):
        raise ValueError(direction)
    quantity = round(float(quantity), 6)
    if quantity <= EPS:
        return None
    signed = _signed(direction, quantity)
    if lot is not None:
        after = (lot.quantity_on_hand or 0) + signed
        if after < -EPS:
            raise FeedError(
                f"Lot {lot.lot_code} holds {max(lot.quantity_on_hand or 0, 0):g} {uom.describe(product.unit)}; "
                f"{quantity:g} cannot be taken from it."
            )
        lot.quantity_on_hand = round(max(after, 0.0), 6)
        refresh_lot_status(lot)
    elif exception is None and reason not in _UNLOTTED_REASONS:
        raise FeedError("A feed movement names its lot; stock with no lot leaves only through an approved stock exception.")
    tx = models.InventoryTransaction(
        id=new_id(), item_id=product.inventory_item_id, direction=direction, quantity=quantity, unit_cost=unit_cost, reason=reason,
        linked_entity_type=linked_entity_type, linked_entity_id=linked_entity_id, lot_id=lot.id if lot is not None else None,
        stock_exception_id=exception.id if exception is not None else None, correlation_id=correlation_id,
        actor_user_id=user_id, created_at=when or now(),
    )
    db.add(tx)
    if item is not None:
        item.current_qty = round((item.current_qty or 0) + signed, 6)
    return tx


def _item_ledger_total(db: Session, item_id: str) -> float:
    signed = case((models.InventoryTransaction.direction == "in", models.InventoryTransaction.quantity), else_=-models.InventoryTransaction.quantity)
    return float(db.scalar(select(func.coalesce(func.sum(signed), 0.0)).where(models.InventoryTransaction.item_id == item_id)) or 0.0)


# Movements with no lot and no exception: carrying stock recorded before
# lots existed into the opening lot, and zeroing it at a count.
_UNLOTTED_REASONS = ("opening_balance", "count_correction")


@dataclass
class LedgerState:
    """One product's stock as the rows say it and as the projections say it."""

    product_id: str
    name: str
    unit: str
    item_cached: float
    ledger_total: float
    untraced: float
    open_exceptions: float
    lots: list[dict]

    @property
    def lot_cached_total(self) -> float:
        return sum(l["cached"] for l in self.lots)

    def problems(self) -> list[str]:
        out = []
        if abs(self.item_cached - self.ledger_total) > 0.001:
            out.append(f"stock line {self.item_cached:g} ≠ ledger {self.ledger_total:g}")
        for l in self.lots:
            if abs(l["cached"] - l["ledger"]) > 0.001:
                out.append(f"lot {l['lot_code']}: stored {l['cached']:g} ≠ ledger {l['ledger']:g}")
            if l["ledger"] < -0.001:
                out.append(f"lot {l['lot_code']} is below zero ({l['ledger']:g})")
        if self.untraced > 0.001:
            out.append(f"{self.untraced:g} on record with no lot")
        if abs(-self.untraced - self.open_exceptions) > 0.001 and self.untraced <= 0.001:
            out.append(f"untraced {-self.untraced:g} ≠ open exceptions {self.open_exceptions:g}")
        return out

    def to_dict(self) -> dict:
        problems = self.problems()
        return {
            "feed_product_id": self.product_id, "name": self.name, "unit": self.unit,
            "stock_line": round(self.item_cached, 3), "ledger_on_hand": round(self.ledger_total, 3),
            "lot_on_hand": round(self.lot_cached_total, 3), "untraced": round(-self.untraced, 3),
            "open_exceptions": round(self.open_exceptions, 3),
            "lots": [{**l, "cached": round(l["cached"], 3), "ledger": round(l["ledger"], 3)} for l in self.lots],
            "consistent": not problems, "problems": problems,
        }


def ledger_state(db: Session, product: fm.FeedProduct) -> LedgerState:
    """Reads the rows themselves (SQL sums), not the projections."""
    signed = case((models.InventoryTransaction.direction == "in", models.InventoryTransaction.quantity), else_=-models.InventoryTransaction.quantity)
    sums = dict(db.execute(
        select(models.InventoryTransaction.lot_id, func.coalesce(func.sum(signed), 0.0))
        .where(models.InventoryTransaction.item_id == product.inventory_item_id).group_by(models.InventoryTransaction.lot_id)
    ).all())
    item = db.get(models.InventoryItem, product.inventory_item_id)
    lots = list(db.scalars(select(fm.FeedLot).where(fm.FeedLot.feed_product_id == product.id).order_by(fm.FeedLot.received_at)))
    open_total = db.scalar(select(func.coalesce(func.sum(fm.FeedStockException.quantity - fm.FeedStockException.resolved_quantity), 0.0)).where(
        fm.FeedStockException.feed_product_id == product.id, fm.FeedStockException.status == "open")) or 0.0
    return LedgerState(
        product_id=product.id, name=product.name, unit=product.unit,
        item_cached=float(item.current_qty or 0) if item else 0.0,
        ledger_total=float(sum(sums.values())), untraced=float(sums.get(None, 0.0)), open_exceptions=float(open_total),
        lots=[{"lot_id": l.id, "lot_code": l.lot_code, "status": l.status, "cached": float(l.quantity_on_hand or 0),
               "ledger": float(sums.get(l.id, 0.0))} for l in lots],
    )


def integrity_report(db: Session, farm_id: str) -> dict:
    """The reconciliation every feed product must pass (docs/runbooks/
    FEED-STOCK-RECONCILIATION.md): projections equal their rows, no lot
    below zero, no stock on record without a lot, and every untraced kilo
    carried by an open exception."""
    products = list(db.scalars(select(fm.FeedProduct).where(fm.FeedProduct.farm_id == farm_id).order_by(fm.FeedProduct.name)))
    rows = [ledger_state(db, p).to_dict() for p in products]
    return {"products": rows, "consistent": all(r["consistent"] for r in rows),
            "inconsistent": [r["feed_product_id"] for r in rows if not r["consistent"]]}


def rebuild_projections(db: Session, product: fm.FeedProduct, *, user_id: str) -> dict:
    """Sets the two projections back to what the rows say (INVENTORY-SCHEMA
    §1: balances are rebuildable projections). Touches no movement; the
    audit log keeps what each figure was. Used by the reconciliation
    runbook when `integrity_report` finds a stored figure that disagrees
    with its rows."""
    lock_stock(db, product)
    state = ledger_state(db, product)
    changes = {}
    item = db.get(models.InventoryItem, product.inventory_item_id)
    if item is not None and abs((item.current_qty or 0) - state.ledger_total) > 1e-6:
        changes["stock_line"] = {"from": item.current_qty, "to": round(state.ledger_total, 6)}
        item.current_qty = round(state.ledger_total, 6)
    for lot in product.lots:
        ledger = next((l["ledger"] for l in state.lots if l["lot_id"] == lot.id), 0.0)
        if abs((lot.quantity_on_hand or 0) - ledger) > 1e-6:
            changes[f"lot:{lot.lot_code}"] = {"from": lot.quantity_on_hand, "to": round(ledger, 6)}
            lot.quantity_on_hand = round(ledger, 6)
            refresh_lot_status(lot)
    if changes:
        write_audit_log(db, farm_id=product.farm_id, user_id=user_id, action="feed_stock_projection_rebuilt", entity_type="feed_product",
                        entity_id=product.id, module_code="feed_nutrition",
                        summary=f"Stock figures of {product.name} rebuilt from the ledger", changes=changes)
    return {"feed_product_id": product.id, "changes": changes}


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


def resolve_ration(
    ration_type: str | None,
    *,
    is_feedable: bool,
    is_ingredient: bool,
    name: str | None,
    name_ar: str | None = None,
    category: str | None = None,
) -> tuple[str | None, bool, bool]:
    """(ration_type, is_feedable, is_ingredient) for a product (v0.8.3).
    Only a concentrate, corn silage or hay & straw is fed to the animals;
    anything else is a raw material for mixes. A form that names the type
    gets it; an older one that only says "feedable" gets the type its name
    and category say (catalog.infer_ration_type) — a grain stays a raw
    material however it was marked."""
    if ration_type == catalog.RAW_MATERIAL:
        return None, False, True
    if ration_type is not None:
        if ration_type not in catalog.RATION_TYPES:
            raise FeedError(f"ration_type must be one of {list(catalog.RATION_TYPES) + [catalog.RAW_MATERIAL]}")
        return ration_type, True, is_ingredient
    if not is_feedable:
        return None, False, True
    inferred = catalog.infer_ration_type(name=name, name_ar=name_ar, category=category, is_ingredient=is_ingredient)
    if inferred is None:
        return None, False, True
    return inferred, True, is_ingredient


def current_unit_cost(db: Session, product: fm.FeedProduct) -> float | None:
    """What a kilo (unit) of this feed costs when it is fed next: the cost
    of the lot it would be taken from first (FIFO), else the feed's price."""
    item = db.get(models.InventoryItem, product.inventory_item_id)
    usable = sorted((l for l in product.lots if lot_usable(l) and l.quantity_on_hand > 0), key=lambda l: l.received_at)
    return unit_cost_of(usable[0] if usable else None, product, item)


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
        category = category or (item.category or "").lower() or None
        ration, is_feedable, is_ingredient = resolve_ration(None, is_feedable=is_feedable, is_ingredient=is_ingredient, name=item.name, category=category)
        product = fm.FeedProduct(
            id=new_id(),
            farm_id=item.farm_id,
            code=unique_code(db, item.farm_id, slug(item.name)),
            name=item.name,
            source_type=source_type,
            is_ingredient=is_ingredient,
            is_feedable=is_feedable,
            ration_type=ration,
            category=category,
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


# ------------------------------------------------------------ standard feeds
def _slot_match_rank(product: fm.FeedProduct, slot_row) -> int | None:
    """0: coded for the slot; 1: its name says it; 2: (concentrate only) a
    concentrate by category. None: not this slot's feed."""
    slot, code, _en, _ar, category, _unit, keywords = slot_row
    if (product.code or "").upper() == code:
        return 0
    names = f"{product.name or ''} {product.name_ar or ''}".lower()
    if any(k.lower() in names for k in keywords):
        return 1
    if slot == "concentrate" and (product.category or "").lower() == category:
        return 2
    return None


def standard_feed_slots(db: Session, farm_id: str) -> dict[str, fm.FeedProduct | None]:
    """Which of the farm's feeds fills each default row of the feeding form
    (concentrate, corn silage, wheat straw). A product coded for the slot
    wins, then one whose name says it, then — for concentrate — any
    concentrate. The rule lives here, once; the tablet only shows it."""
    products = list(db.scalars(
        select(fm.FeedProduct).where(fm.FeedProduct.farm_id == farm_id, fm.FeedProduct.status == "active", fm.FeedProduct.is_feedable.is_(True))
        .order_by(fm.FeedProduct.created_at, fm.FeedProduct.name)
    ))
    out: dict[str, fm.FeedProduct | None] = {}
    for row in catalog.STANDARD_FEEDS:
        ranked = sorted(((rank, i, p) for i, p in enumerate(products) if (rank := _slot_match_rank(p, row)) is not None), key=lambda t: t[:2])
        out[row[0]] = ranked[0][2] if ranked else None
    return out


def ensure_standard_feeds(db: Session, farm_id: str, *, created_by: str | None = None) -> dict[str, fm.FeedProduct]:
    """Creates whichever of the three standard feeds the farm does not have
    yet — an ordinary feedable product with an empty ledger (no invented
    stock); the concentrate is farm-produced so the farm's mixes make it.
    Idempotent."""
    slots = standard_feed_slots(db, farm_id)
    for slot, code, name_en, name_ar, category, unit, _keywords in catalog.STANDARD_FEEDS:
        if slots.get(slot) is None:
            slots[slot] = create_product(
                db, farm_id, code=code, name=name_en, name_ar=name_ar, unit=unit, source_type=catalog.STANDARD_FEED_SOURCE.get(slot, "purchased"),
                is_ingredient=True, is_feedable=True, ration_type=catalog.SLOT_RATION[slot], category=category,
                notes="Standard feed of the animal feeding form.", created_by=created_by,
            )
    return slots  # type: ignore[return-value]


def reconcile_opening_balance(db: Session, product: fm.FeedProduct, item: models.InventoryItem, *, created_by: str | None) -> None:
    """Stock an item held before lots existed becomes its opening lot. Runs
    only for a product with no lots at all — once lots exist, every
    movement names one, and a difference would be a defect for
    `integrity_report`, not a gap to paper over.

    The carry-over is two posted movements sharing a correlation id: `in`
    on the new opening lot, `out` of the same quantity from the no-lot
    balance. The stock line does not move; the kilos simply get a lot. A
    balance below zero has nothing to carry: it is recorded as an open
    stock exception for the manager to reconcile."""
    if product.lots:
        return
    if abs(item.current_qty or 0) <= EPS and abs(_item_ledger_total(db, item.id)) <= EPS:
        return
    lock_stock(db, product)
    if product.lots:
        return
    ledger = _item_ledger_total(db, item.id)
    drift = round((item.current_qty or 0) - ledger, 6)
    if abs(drift) > EPS:
        # The stock line holds a figure no movement explains (an item created
        # with a quantity, or changed by an older path). That figure is kept,
        # and made explicit: the projection goes back to its rows and one
        # `opening_balance` movement records the difference.
        item.current_qty = round(ledger, 6)
        _post(db, product, item, lot=None, direction="in" if drift > 0 else "out", quantity=abs(drift), reason="opening_balance",
              linked_entity_type="inventory_item", linked_entity_id=item.id, unit_cost=item.unit_cost, user_id=created_by)
    gap = round(item.current_qty or 0, 6)
    if abs(gap) <= EPS:
        return
    if gap < -EPS:
        if db.scalar(select(fm.FeedStockException.id).where(fm.FeedStockException.feed_product_id == product.id,
                                                            fm.FeedStockException.status == "open")) is None:
            _open_exception(db, product, item, kind="legacy_untraced", quantity=-gap,
                            reason="The stock line was below zero before the feed had lots; nothing was recorded to explain it.",
                            requested_by=None, approved_by=None, source_entity_type="inventory_item", source_entity_id=item.id,
                            when=now(), user_id=created_by or "system", post=False)
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
        quantity_on_hand=0,
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
    carry = new_id()
    _post(db, product, item, lot=lot, direction="in", quantity=gap, reason="opening_balance", linked_entity_type="feed_lot",
          linked_entity_id=lot.id, unit_cost=lot.unit_cost, when=lot.received_at, user_id=created_by, correlation_id=carry)
    _post(db, product, item, lot=None, direction="out", quantity=gap, reason="opening_balance", linked_entity_type="feed_lot",
          linked_entity_id=lot.id, unit_cost=lot.unit_cost, when=lot.received_at, user_id=created_by, correlation_id=carry)


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
    ration_type: str | None = None,
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
    if not (is_ingredient or is_feedable or ration_type not in (None, catalog.RAW_MATERIAL)):
        raise FeedError("A feed product must be an ingredient, feedable, or both.")
    if unit_cost is not None and unit_cost < 0:
        raise FeedError("A price cannot be negative.")
    ration_type, is_feedable, is_ingredient = resolve_ration(
        ration_type, is_feedable=is_feedable, is_ingredient=is_ingredient, name=name, name_ar=name_ar, category=category)
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
        ration_type=ration_type,
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
    quality_grade: str | None = None,
    moisture_pct: float | None = None,
    quality_notes: str | None = None,
) -> fm.FeedLot:
    """Goods receipt (§26): what arrived, what was accepted, what was
    rejected — three separately auditable numbers — and the quality seen at
    receipt (grade, moisture, notes). On-hand starts at the accepted
    quantity."""
    if quality_grade is not None and quality_grade not in catalog.LOT_QUALITY_GRADES:
        raise FeedError(f"quality_grade must be one of {list(catalog.LOT_QUALITY_GRADES)}")
    if moisture_pct is not None and not 0 <= moisture_pct <= 100:
        raise FeedError("Moisture is a percentage between 0 and 100.")
    if quantity <= 0:
        raise FeedError("Received quantity must be greater than zero.")
    if rejected_quantity < 0 or rejected_quantity > quantity:
        raise FeedError("Rejected quantity must be between zero and the received quantity.")
    qty = uom.convert(quantity, unit or product.unit, product.unit)
    rejected = uom.convert(rejected_quantity, unit or product.unit, product.unit)
    accepted = qty - rejected
    lock_stock(db, product)
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
        # Starts empty: the receipt movement below brings the accepted
        # quantity in, through the one function that moves stock.
        quantity_on_hand=0,
        unit=product.unit,
        unit_cost=unit_cost if unit_cost is not None else (item.unit_cost if item else product.default_unit_cost),
        status="active" if accepted > 0 else "depleted",
        reference=reference,
        quality_grade=quality_grade,
        moisture_pct=moisture_pct,
        quality_notes=(quality_notes or "").strip() or None,
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
    if accepted > 0:
        _post(db, product, item, lot=lot, direction="in", quantity=accepted, unit_cost=lot.unit_cost,
              reason={"purchased": "purchase", "farm_produced": "production", "opening_balance": "opening_balance"}.get(source_type, source_type),
              linked_entity_type="feed_lot", linked_entity_id=lot.id, when=when, user_id=user_id)
    if item is not None and accepted > 0:
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
    if source_type == "purchased":
        # FEED-PERFORMANCE-INTELLIGENCE §12: a supplier receipt or cost
        # update refreshes the supplier rows and the cost picture.
        from app.services import feed_performance_service as perf  # local import: perf imports this module

        perf.on_receipt(db, product.farm_id, user_id=user_id or "system")
    return lot


def set_lot_status(db: Session, lot: fm.FeedLot, status: str, *, reason: str | None, user_id: str) -> fm.FeedLot:
    if status not in catalog.LOT_STATUSES:
        raise FeedError(f"status must be one of {list(catalog.LOT_STATUSES)}")
    # A hold and an issue of the same lot are decided one after the other.
    lock_stock(db, db.get(fm.FeedProduct, lot.feed_product_id))
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
    # FEED-PERFORMANCE-INTELLIGENCE §12: an ingredient / output lot change
    # re-scores the mixes that used it and the subjects that received it.
    from app.services import feed_performance_service as perf  # local import: perf imports this module

    perf.on_lot_status_changed(db, lot, user_id=user_id)
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


@dataclass
class _Reserved:
    """What reservations for other purposes hold back: per lot for a
    reservation that names its lot (never more than that lot's usable
    stock), and as one pool for a reservation of the product."""

    by_lot: dict[str, float]
    pool: float

    def total(self) -> float:
        return sum(self.by_lot.values()) + self.pool


def _reserved_for_others(db: Session, product: fm.FeedProduct, purpose: Purpose | None) -> _Reserved:
    lots = {l.id: l for l in product.lots}
    by_lot: dict[str, float] = {}
    pool = 0.0
    for alloc in _allocations(db, product.id):
        if allocation_matches(alloc, purpose):
            continue
        qty = uom.convert(allocation_remaining(alloc), alloc.unit, product.unit)
        if alloc.lot_id is not None:
            lot = lots.get(alloc.lot_id)
            # A reservation on a held or empty lot holds back nothing usable.
            usable = max(lot.quantity_on_hand, 0) if lot is not None and lot_usable(lot) else 0.0
            by_lot[alloc.lot_id] = min(by_lot.get(alloc.lot_id, 0.0) + qty, usable)
        else:
            pool += qty
    return _Reserved(by_lot=by_lot, pool=pool)


def reserved_for_others(db: Session, product: fm.FeedProduct, purpose: Purpose | None, lot: fm.FeedLot | None = None) -> float:
    reserved = _reserved_for_others(db, product, purpose)
    if lot is not None:
        return reserved.by_lot.get(lot.id, 0.0) + reserved.pool
    return reserved.total()


def open_untraced(db: Session, product: fm.FeedProduct) -> tuple[float, int]:
    """(quantity, count) of the product's open stock exceptions."""
    row = db.execute(select(
        func.coalesce(func.sum(fm.FeedStockException.quantity - fm.FeedStockException.resolved_quantity), 0.0), func.count(fm.FeedStockException.id),
    ).where(fm.FeedStockException.feed_product_id == product.id, fm.FeedStockException.status == "open")).one()
    return float(row[0] or 0.0), int(row[1] or 0)


@dataclass
class _IssuePlan:
    """What can be issued right now for one purpose: each usable lot's free
    quantity (its stock less what other purposes reserved on it) and the
    product-wide limit (free lot stock less product-level reservations of
    others and the untraced stock not yet reconciled)."""

    lot_free: dict[str, float]
    available: float


def _issue_plan(db: Session, product: fm.FeedProduct, purpose: Purpose | None) -> _IssuePlan:
    reserved = _reserved_for_others(db, product, purpose)
    deficit, _ = open_untraced(db, product)
    lot_free = {}
    for lot in product.lots:
        if lot_usable(lot):
            lot_free[lot.id] = max(lot.quantity_on_hand - reserved.by_lot.get(lot.id, 0.0), 0.0)
    return _IssuePlan(lot_free=lot_free, available=max(sum(lot_free.values()) - reserved.pool - deficit, 0.0))


def availability(db: Session, product: fm.FeedProduct, purpose: Purpose | None = None) -> Availability:
    """The one derivation every screen, report and check uses (module
    docstring): on hand is the ledger, the lots and the untraced balance
    are its two parts, and what is available is usable lot stock less what
    is owed to open exceptions and to other purposes' reservations."""
    item = db.get(models.InventoryItem, product.inventory_item_id)
    if item is not None:
        reconcile_opening_balance(db, product, item, created_by=None)
    lot_on_hand = 0.0
    unusable = 0.0
    by_status: dict[str, float] = {}
    lots = []
    for lot in product.lots:
        refresh_lot_status(lot)
        qty = max(lot.quantity_on_hand, 0)
        lot_on_hand += qty
        if lot.status in catalog.LOT_UNUSABLE:
            unusable += qty
            by_status[lot.status] = by_status.get(lot.status, 0) + qty
        lots.append({
            "id": lot.id, "lot_code": lot.lot_code, "status": lot.status, "quantity_on_hand": round(lot.quantity_on_hand, 3),
            "unit": lot.unit, "unit_cost": lot.unit_cost, "received_at": lot.received_at, "expiry_date": lot.expiry_date,
            "source_type": lot.source_type, "supplier_label": lot.supplier_label, "feed_batch_id": lot.feed_batch_id,
        })
    on_hand = float(item.current_qty or 0) if item is not None else lot_on_hand
    deficit, open_count = open_untraced(db, product)
    plan = _issue_plan(db, product, purpose)
    usable = max(lot_on_hand - unusable, 0)
    return Availability(
        product_id=product.id, unit=product.unit, on_hand=on_hand, unusable=unusable,
        reserved=min(reserved_for_others(db, product, purpose), max(usable - deficit, 0)), available=plan.available,
        lots=lots, unusable_by_status=by_status, lot_on_hand=lot_on_hand, untraced=deficit, open_exceptions=open_count,
    )


# ----------------------------------------------------------------- issue
def _shortage_message(product: fm.FeedProduct, avail: Availability, qty: float, named: fm.FeedLot | None, named_free: float | None) -> str:
    unit = uom.describe(product.unit)
    if named is not None:
        return (
            f"Not enough {product.name} in lot {named.lot_code}: it holds {max(named.quantity_on_hand, 0):.1f} {unit}"
            + (f" ({named_free:.1f} free of other reservations)" if named_free is not None and named_free < named.quantity_on_hand - EPS else "")
            + f", {qty:.1f} requested. A named lot is never made up from another lot — choose another lot, split the feeding, "
              f"or record it as an approved stock exception with a reason."
        )
    parts = [f"{avail.on_hand:.1f} {unit} on hand"]
    if avail.unusable:
        parts.append(f"{avail.unusable:.1f} unusable ({', '.join(f'{k} {v:.0f}' for k, v in avail.unusable_by_status.items())})")
    if avail.untraced:
        parts.append(f"{avail.untraced:.1f} issued earlier without a lot and not yet reconciled")
    if avail.reserved:
        parts.append(f"{avail.reserved:.1f} reserved for another purpose")
    return (
        f"Not enough {product.name} for this use: {'; '.join(parts)} — {avail.available:.1f} {unit} available, "
        f"{qty:.1f} requested. Pass allow_negative=true with an override_reason to record it as an approved stock exception."
    )


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
    override: Override | None = None,
    user_id: str | None = None,
    occurred_at: datetime | None = None,
) -> list[Draw]:
    """Issues stock FIFO from usable lots — or from the one lot named —
    respecting holds and reservations. Raises with the arithmetic when
    there is not enough: the farmer sees why ("400 kg on hand, 350 kg
    reserved for the dairy herd") instead of a bare refusal.

    A named lot is the whole answer: if it holds too little the issue is
    refused, never made up from a second lot or from no lot. Only an
    approved [override] with a reason issues more than there is; the part
    no lot covers is posted with no lot, tagged with an open stock
    exception that names who recorded it, who approved it, why and for
    what (v0.8.4, audit I-1)."""
    if quantity <= 0:
        raise FeedError("Quantity must be greater than zero.")
    qty = round(uom.convert(quantity, unit or product.unit, product.unit), 6)
    lock_stock(db, product)
    item = db.get(models.InventoryItem, product.inventory_item_id)
    if item is not None:
        reconcile_opening_balance(db, product, item, created_by=user_id)

    named = None
    if lot_id is not None:
        named = get_lot(db, lot_id, product.farm_id)
        if named.feed_product_id != product.id:
            raise FeedError(f"Lot {named.lot_code} is not {product.name}.")
        if not lot_usable(named) and named.status != "depleted":
            raise FeedError(f"Lot {named.lot_code} is {named.status} and cannot be issued without an authorised release.")

    plan = _issue_plan(db, product, purpose)
    if named is not None:
        named_free = plan.lot_free.get(named.id, 0.0)
        can_take = min(named_free, plan.available)
        candidates = [named]
    else:
        named_free = None
        can_take = plan.available
        candidates = sorted((l for l in product.lots if l.id in plan.lot_free), key=lambda l: ensure_utc(l.received_at))

    shortfall = round(qty - can_take, 6) if qty > can_take + EPS else 0.0
    if shortfall:
        if override is None:
            raise FeedError(_shortage_message(product, availability(db, product, purpose), qty, named, named_free))
        if not (override.reason or "").strip():
            raise FeedError(
                f"Recording {shortfall:.1f} {uom.describe(product.unit)} of {product.name} more than the stock on record is an approved "
                "stock exception: say why (override_reason) — for example a delivery that is not entered yet."
            )

    when = occurred_at or now()
    draws: list[Draw] = []
    remaining = qty - shortfall
    for lot in candidates:
        if remaining <= EPS:
            break
        take = min(plan.lot_free.get(lot.id, 0.0), remaining)
        if take <= EPS:
            continue
        cost = unit_cost_of(lot, product, item)
        _post(db, product, item, lot=lot, direction="out", quantity=take, unit_cost=cost, reason=reason, linked_entity_type=linked_entity_type,
              linked_entity_id=linked_entity_id, when=when, user_id=user_id)
        draws.append(Draw(lot=lot, quantity=take, unit=product.unit, unit_cost=cost))
        remaining -= take
    if remaining > EPS:
        # The plan said these kilos were free; a lot cannot have changed
        # under the lock, so this is a defect, not a shortage to cover.
        raise FeedError(f"Stock of {product.name} changed while it was being issued; nothing was recorded. Try again.", 409)
    traced = qty - shortfall
    if shortfall:
        cost = unit_cost_of(None, product, item)
        exc = _open_exception(
            db, product, item, kind="untraced_issue", quantity=shortfall, reason=override.reason.strip(),
            requested_by=override.requested_by or user_id, approved_by=override.approved_by, approval_request_id=override.approval_request_id,
            source_entity_type=linked_entity_type, source_entity_id=linked_entity_id, lot=named, when=when, user_id=override.approved_by,
            detail={"requested": qty, "issued_from_lots": round(traced, 6), "available": round(plan.available, 6), "movement_reason": reason,
                    **({"named_lot_holds": round(named.quantity_on_hand + (draws[0].quantity if draws else 0), 6)} if named is not None else {})},
            unit_cost=cost, movement_reason=reason,
        )
        draws.append(Draw(lot=None, quantity=shortfall, unit=product.unit, unit_cost=cost, exception_id=exc.id))

    # Draw down the reservations this purpose holds — by what left its lots.
    if purpose is not None:
        left = traced
        for alloc in _allocations(db, product.id):
            if left <= EPS:
                break
            if not allocation_matches(alloc, purpose):
                continue
            take = min(uom.convert(allocation_remaining(alloc), alloc.unit, product.unit), left)
            alloc.consumed_quantity += uom.convert(take, product.unit, alloc.unit)
            if allocation_remaining(alloc) <= EPS:
                alloc.status = "exhausted"
            left -= take
    write_event(
        db, farm_id=product.farm_id, entity_type="feed_product", entity_id=product.id, event_type="feed_inventory_consumed",
        payload={"quantity": qty, "unit": product.unit, "reason": reason, "for": f"{linked_entity_type}:{linked_entity_id}",
                 "lots": [d.lot.lot_code for d in draws if d.lot is not None], "untraced": shortfall or None},
        created_by=user_id or "system",
    )
    return draws


# ------------------------------------------------------- stock exceptions
def _open_exception(
    db: Session,
    product: fm.FeedProduct,
    item: models.InventoryItem | None,
    *,
    kind: str,
    quantity: float,
    reason: str,
    requested_by: str | None,
    approved_by: str | None,
    source_entity_type: str | None,
    source_entity_id: str | None,
    when: datetime,
    user_id: str,
    approval_request_id: str | None = None,
    lot: fm.FeedLot | None = None,
    detail: dict | None = None,
    unit_cost: float | None = None,
    movement_reason: str | None = None,
    post: bool = True,
) -> fm.FeedStockException:
    """Records the untraced gap and (with [post]) posts it: an `out` with no
    lot, tagged with the exception. Audit-logged and evented."""
    exc = fm.FeedStockException(
        id=new_id(), farm_id=product.farm_id, feed_product_id=product.id, inventory_item_id=product.inventory_item_id, kind=kind,
        quantity=round(quantity, 6), resolved_quantity=0, unit=product.unit, status="open", reason=reason, requested_by=requested_by,
        approved_by=approved_by, approval_request_id=approval_request_id, source_entity_type=source_entity_type, source_entity_id=source_entity_id,
        lot_id=lot.id if lot is not None else None, detail=detail or {}, occurred_at=when, created_at=now(),
    )
    db.add(exc)
    db.flush()
    if post:
        _post(db, product, item, lot=None, direction="out", quantity=quantity, unit_cost=unit_cost, reason=movement_reason or "untraced_issue",
              linked_entity_type=source_entity_type, linked_entity_id=source_entity_id, when=when, user_id=user_id, exception=exc)
    write_audit_log(
        db, farm_id=product.farm_id, user_id=user_id, action="feed_stock_exception_opened", entity_type="feed_stock_exception", entity_id=exc.id,
        module_code="feed_nutrition",
        summary=f"{quantity:g} {product.unit} of {product.name} issued with no lot ({kind}): {reason}",
        metadata={"feed_product_id": product.id, "quantity": quantity, "requested_by": requested_by, "approved_by": approved_by,
                  "approval_request_id": approval_request_id, "source": f"{source_entity_type}:{source_entity_id}", "lot_id": exc.lot_id},
    )
    write_event(
        db, farm_id=product.farm_id, entity_type="feed_product", entity_id=product.id, event_type="feed_stock_exception_opened",
        payload={"exception_id": exc.id, "kind": kind, "quantity": quantity, "unit": product.unit, "reason": reason,
                 "requested_by": requested_by, "approved_by": approved_by, "approval_request_id": approval_request_id,
                 "source": f"{source_entity_type}:{source_entity_id}", "lot_id": exc.lot_id},
        created_by=user_id,
    )
    return exc


def exception_open(exc: fm.FeedStockException) -> float:
    return max(round(exc.quantity - (exc.resolved_quantity or 0), 6), 0.0)


def get_exception(db: Session, exception_id: str, farm_id: str) -> fm.FeedStockException:
    exc = db.get(fm.FeedStockException, exception_id)
    if exc is None or exc.farm_id != farm_id:
        raise FeedError("Stock exception not found", 404)
    return exc


def list_exceptions(db: Session, farm_id: str, *, status: str | None = None, feed_product_id: str | None = None) -> list[fm.FeedStockException]:
    stmt = select(fm.FeedStockException).where(fm.FeedStockException.farm_id == farm_id)
    if status:
        stmt = stmt.where(fm.FeedStockException.status == status)
    if feed_product_id:
        stmt = stmt.where(fm.FeedStockException.feed_product_id == feed_product_id)
    return list(db.scalars(stmt.order_by(fm.FeedStockException.occurred_at.desc())))


def _settle(
    db: Session,
    exc: fm.FeedStockException,
    product: fm.FeedProduct,
    item: models.InventoryItem | None,
    *,
    quantity: float,
    resolution: str,
    note: str,
    user_id: str,
    when: datetime,
    reference_id: str | None,
    lot: fm.FeedLot | None = None,
    linked_entity_type: str = "feed_stock_exception",
    linked_entity_id: str | None = None,
) -> None:
    """Posts the reconciling movement(s) for [quantity] of [exc] and records
    it. `in` with no lot, tagged, closes that much of the untraced gap; when
    the kilos really came from [lot], the same quantity is taken out of it
    in the same breath (a correlated pair), so the lot pays for what it fed."""
    quantity = round(min(quantity, exception_open(exc)), 6)
    if quantity <= EPS:
        return
    pair = new_id()
    cost = unit_cost_of(lot, product, item)
    if lot is not None:
        _post(db, product, item, lot=lot, direction="out", quantity=quantity, unit_cost=cost, reason="exception_assignment",
              linked_entity_type=linked_entity_type, linked_entity_id=linked_entity_id or exc.id, when=when, user_id=user_id,
              exception=exc, correlation_id=pair)
    _post(db, product, item, lot=None, direction="in", quantity=quantity, unit_cost=cost, reason="exception_resolution",
          linked_entity_type=linked_entity_type, linked_entity_id=linked_entity_id or exc.id, when=when, user_id=user_id,
          exception=exc, correlation_id=pair)
    exc.resolved_quantity = round((exc.resolved_quantity or 0) + quantity, 6)
    detail = dict(exc.detail or {})
    detail["resolutions"] = [*detail.get("resolutions", []), {
        "resolution": resolution, "quantity": quantity, "lot_id": lot.id if lot is not None else None, "note": note,
        "by": user_id, "at": when.isoformat(), "reference_id": reference_id, "correlation_id": pair,
    }]
    exc.detail = detail
    if exception_open(exc) <= EPS:
        exc.status = "reversed" if resolution == "reversed" else "resolved"
        exc.resolution = resolution if len({r["resolution"] for r in detail["resolutions"]}) == 1 else "mixed"
        exc.resolution_note = note
        exc.resolution_lot_id = lot.id if lot is not None else exc.resolution_lot_id
        exc.resolution_reference_id = reference_id
        exc.resolved_by = user_id
        exc.resolved_at = when
    write_audit_log(
        db, farm_id=exc.farm_id, user_id=user_id, action="feed_stock_exception_resolved", entity_type="feed_stock_exception", entity_id=exc.id,
        module_code="feed_nutrition",
        summary=f"{quantity:g} {product.unit} of {product.name} issued with no lot reconciled ({resolution}): {note}",
        metadata={"resolution": resolution, "quantity": quantity, "lot_id": lot.id if lot is not None else None, "reference_id": reference_id,
                  "open_after": exception_open(exc)},
    )
    write_event(
        db, farm_id=exc.farm_id, entity_type="feed_product", entity_id=product.id, event_type="feed_stock_exception_resolved",
        payload={"exception_id": exc.id, "resolution": resolution, "quantity": quantity, "unit": product.unit, "note": note,
                 "lot_id": lot.id if lot is not None else None, "open_after": exception_open(exc), "status": exc.status},
        created_by=user_id,
    )


RESOLUTIONS = ("assigned_to_lot", "confirmed_unrecorded_stock")


def resolve_exception(
    db: Session,
    exc: fm.FeedStockException,
    *,
    resolution: str,
    note: str | None,
    user_id: str,
    lot_id: str | None = None,
    quantity: float | None = None,
) -> fm.FeedStockException:
    """The manager's reconciliation of an open exception (a stock count is
    the third way, `count_stock`; undoing the feeding the fourth):

    assigned_to_lot             the kilos came from [lot_id], a delivery or
                                mix recorded after the feeding — that lot
                                gives them up now; the feeding's own record
                                keeps "no lot" (history is not rewritten),
                                the exception names the lot
    confirmed_unrecorded_stock  the stock was there and never recorded
                                (an opening count that was short) — the
                                gap is closed with no lot giving anything
    """
    if resolution not in RESOLUTIONS:
        raise FeedError(f"resolution must be one of {list(RESOLUTIONS)}")
    note = (note or "").strip()
    if not note:
        raise FeedError("Say how this was reconciled — it stays on the record with the exception.")
    product = get_product(db, exc.feed_product_id, exc.farm_id)
    lock_stock(db, product)
    db.refresh(exc)
    if exc.status != "open":
        raise FeedError(f"This stock exception is already {exc.status}.", 409)
    open_qty = exception_open(exc)
    qty = open_qty if quantity is None else round(float(quantity), 6)
    if qty <= EPS or qty > open_qty + EPS:
        raise FeedError(f"Reconcile between zero and the {open_qty:g} {product.unit} still open.")
    item = db.get(models.InventoryItem, product.inventory_item_id)
    lot = None
    when = now()
    if resolution == "assigned_to_lot":
        if not lot_id:
            raise FeedError("Name the lot the feed came from.")
        lot = get_lot(db, lot_id, exc.farm_id)
        if lot.feed_product_id != product.id:
            raise FeedError(f"Lot {lot.lot_code} is not {product.name}.")
        if lot.received_at is not None and ensure_utc(lot.received_at) > ensure_utc(exc.occurred_at) + timedelta(days=1):
            raise FeedError(
                f"Lot {lot.lot_code} was received on {ensure_utc(lot.received_at).date().isoformat()}, after the feed was issued "
                f"({ensure_utc(exc.occurred_at).date().isoformat()}); it cannot be where that feed came from."
            )
        if lot.quantity_on_hand < qty - EPS:
            raise FeedError(f"Lot {lot.lot_code} holds {lot.quantity_on_hand:g} {product.unit}; reconcile at most that much against it.")
    _settle(db, exc, product, item, quantity=qty, resolution=resolution, note=note, user_id=user_id, when=when, reference_id=None, lot=lot)
    return exc


def restore(
    db: Session,
    product: fm.FeedProduct,
    draws: list[tuple[str | None, float]],
    *,
    reason: str,
    linked_entity_type: str,
    linked_entity_id: str,
    user_id: str,
    reverses_entity_id: str | None = None,
) -> None:
    """Puts issued stock back on the lots it came from — a reversed feeding
    event, a returned delivery. Written as `in` movements, never by editing
    the original `out`. The part that left with no lot closes the stock
    exception it opened ("reversed"); if that exception was reconciled in
    the meantime, the kilos come back to the lot it was reconciled
    against, else to the newest usable lot."""
    lock_stock(db, product)
    item = db.get(models.InventoryItem, product.inventory_item_id)
    when = now()
    for lot_id, quantity in draws:
        if quantity <= EPS:
            continue
        lot = db.get(fm.FeedLot, lot_id) if lot_id else None
        if lot is not None:
            _post(db, product, item, lot=lot, direction="in", quantity=quantity, unit_cost=lot.unit_cost, reason=reason,
                  linked_entity_type=linked_entity_type, linked_entity_id=linked_entity_id, when=when, user_id=user_id)
            continue
        left = quantity
        for exc in _exceptions_for(db, product, reverses_entity_id):
            if left <= EPS:
                break
            take = min(exception_open(exc), left)
            _settle(db, exc, product, item, quantity=take, resolution="reversed", note=reason, user_id=user_id, when=when,
                    reference_id=linked_entity_id, linked_entity_type=linked_entity_type, linked_entity_id=linked_entity_id)
            left -= take
        if left > EPS:
            target = _return_lot(db, product, item, reverses_entity_id, user_id=user_id)
            _post(db, product, item, lot=target, direction="in", quantity=left, unit_cost=target.unit_cost, reason=reason,
                  linked_entity_type=linked_entity_type, linked_entity_id=linked_entity_id, when=when, user_id=user_id)


def _exceptions_for(db: Session, product: fm.FeedProduct, source_entity_id: str | None) -> list[fm.FeedStockException]:
    """Open exceptions an untraced draw of [source_entity_id] opened —
    directly, or among the movements a migrated (legacy) exception lists."""
    if source_entity_id is None:
        return []
    rows = list(db.scalars(select(fm.FeedStockException).where(
        fm.FeedStockException.feed_product_id == product.id, fm.FeedStockException.status == "open",
    ).order_by(fm.FeedStockException.occurred_at)))
    direct = [e for e in rows if e.source_entity_id == source_entity_id]
    legacy = [e for e in rows if e.source_entity_id != source_entity_id
              and any(t.get("linked_entity_id") == source_entity_id for t in (e.detail or {}).get("transactions", []))]
    return direct + legacy


def _return_lot(db: Session, product: fm.FeedProduct, item: models.InventoryItem | None, source_entity_id: str | None, *, user_id: str) -> fm.FeedLot:
    settled = db.scalar(select(fm.FeedStockException).where(
        fm.FeedStockException.feed_product_id == product.id, fm.FeedStockException.source_entity_id == source_entity_id,
        fm.FeedStockException.resolution_lot_id.is_not(None),
    )) if source_entity_id else None
    if settled is not None:
        return db.get(fm.FeedLot, settled.resolution_lot_id)
    return _newest_lot_or_new(db, product, item, suffix="RETURN", note="Feed returned to the store with no lot of its own.", user_id=user_id)


def _newest_lot_or_new(db: Session, product: fm.FeedProduct, item: models.InventoryItem | None, *, suffix: str, note: str,
                       user_id: str | None, when: datetime | None = None) -> fm.FeedLot:
    usable = sorted((l for l in product.lots if lot_usable(l)), key=lambda l: ensure_utc(l.received_at))
    if usable:
        return usable[-1]
    lot = fm.FeedLot(
        id=new_id(), farm_id=product.farm_id, feed_product_id=product.id,
        lot_code=_unique_lot_code(db, product.farm_id, f"{product.code}-{suffix}"), source_type="opening_balance",
        received_at=when or now(), received_quantity=0, accepted_quantity=0, quantity_on_hand=0, unit=product.unit,
        unit_cost=unit_cost_of(None, product, item), status="active", notes=note, created_by=user_id, created_at=now(),
    )
    db.add(lot)
    product.lots.append(lot)
    db.flush()
    return lot


# ------------------------------------------------------------- corrections
ADJUSTMENT_REASONS = ("adjustment", "waste", "return", "reconciliation_adjustment", "count_correction")


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
) -> list[models.InventoryTransaction]:
    """An auditable correction (§26, §33): a spill, a return to the
    supplier, a reconciliation. The explanation is mandatory — an
    unexplained difference is a variance, never an adjustment. A
    correction never takes a lot below zero and never posts stock with no
    lot: a loss comes out of the named lot, or oldest first across the
    lots; a gain goes to the named lot, else the newest usable one."""
    if not explanation or not explanation.strip():
        raise FeedError("An adjustment needs an explanation — an unexplained difference stays a variance.")
    if delta == 0:
        raise FeedError("Adjustment quantity cannot be zero.")
    if reason not in ADJUSTMENT_REASONS:
        raise FeedError("reason must be adjustment, waste, return, count_correction or reconciliation_adjustment")
    lock_stock(db, product)
    if lot is not None:
        lot = db.get(fm.FeedLot, lot.id)
    item = db.get(models.InventoryItem, product.inventory_item_id)
    if item is not None:
        reconcile_opening_balance(db, product, item, created_by=user_id)
    when = now()
    txs: list[models.InventoryTransaction] = []
    if delta > 0:
        target = lot or _newest_lot_or_new(db, product, item, suffix="ADJ", note="Stock added by a correction.", user_id=user_id)
        txs.append(_post(db, product, item, lot=target, direction="in", quantity=delta, unit_cost=unit_cost_of(target, product, item), reason=reason,
                         linked_entity_type=linked_entity_type, linked_entity_id=linked_entity_id, when=when, user_id=user_id))
    else:
        loss = -delta
        if lot is not None:
            sources = [lot]
            held = max(lot.quantity_on_hand, 0)
        else:
            sources = sorted((l for l in product.lots if l.quantity_on_hand > EPS), key=lambda l: ensure_utc(l.received_at))
            held = sum(l.quantity_on_hand for l in sources)
        if loss > held + EPS:
            where = f"lot {lot.lot_code}" if lot is not None else "its lots"
            raise FeedError(
                f"{product.name}: {where} hold {held:g} {product.unit}; a correction of −{loss:g} would take stock below zero. "
                "Count the stock instead, or name the lot."
            )
        for src in sources:
            if loss <= EPS:
                break
            take = min(src.quantity_on_hand, loss)
            if take <= EPS:
                continue
            txs.append(_post(db, product, item, lot=src, direction="out", quantity=take, unit_cost=unit_cost_of(src, product, item), reason=reason,
                             linked_entity_type=linked_entity_type, linked_entity_id=linked_entity_id, when=when, user_id=user_id))
            loss -= take
    txs = [t for t in txs if t is not None]
    write_event(
        db, farm_id=product.farm_id, entity_type="feed_product", entity_id=product.id, event_type="feed_inventory_adjusted",
        payload={"delta": delta, "unit": product.unit, "reason": reason, "explanation": explanation, "lot_ids": [t.lot_id for t in txs]},
        created_by=user_id,
    )
    write_audit_log(
        db, farm_id=product.farm_id, user_id=user_id, action="feed_stock_adjusted", entity_type="feed_product", entity_id=product.id,
        module_code="feed_nutrition", summary=f"{product.name} {delta:+g} {product.unit} ({reason}): {explanation.strip()}",
        metadata={"transactions": [t.id for t in txs], "lot_ids": [t.lot_id for t in txs]},
    )
    return txs


# ------------------------------------------------------ stock count (v0.8.3)
def count_stock(
    db: Session,
    product: fm.FeedProduct,
    *,
    counted: float,
    unit: str | None = None,
    counted_at: datetime | None = None,
    notes: str | None = None,
    user: models.User,
) -> dict:
    """What the manager counted on inspection becomes the stock. The
    records are never edited: the difference with what they say is posted
    as count corrections on the lots — the stock left is the newest (feed is
    used oldest first), a surplus goes to the newest usable lot (or a lot of
    its own). A count also settles every open stock exception of the feed
    (v0.8.4): the physical figure replaces the book one, so what was issued
    with no lot no longer owes anything; each exception keeps its record
    and says the count settled it. A count that matches changes nothing but
    is still kept (audit log and event), so the inspection is on file."""
    if counted is None or counted < 0:
        raise FeedError("The quantity counted cannot be negative.")
    unit = uom.normalise(unit or product.unit)
    counted = round(uom.convert(float(counted), unit, product.unit), 3)
    when = ensure_utc(counted_at) if counted_at else now()
    if when > now() + timedelta(minutes=5):
        raise FeedError("A stock count cannot be in the future.")
    lock_stock(db, product)
    item = db.get(models.InventoryItem, product.inventory_item_id)
    if item is not None:
        reconcile_opening_balance(db, product, item, created_by=user.id)
    lots = sorted(product.lots, key=lambda l: ensure_utc(l.received_at), reverse=True)  # newest first
    lot_before = round(sum(max(l.quantity_on_hand, 0) for l in lots), 3)
    before = round(float(item.current_qty or 0), 3) if item is not None else lot_before
    count_id = new_id()
    # The stock that is there now: the newest lots, each up to what it holds.
    targets: dict[str, float] = {}
    left = counted
    for lot in lots:
        keep = min(max(lot.quantity_on_hand, 0.0), left)
        targets[lot.id] = keep
        left -= keep
    if left > EPS:
        target = _newest_lot_or_new(db, product, item, suffix="COUNT", note="Stock found at an inspection count.", user_id=user.id, when=when)
        if target.id not in targets:
            lots.insert(0, target)
        targets[target.id] = targets.get(target.id, 0.0) + left
    explanation = f"Stock count: {counted:g} {product.unit} counted on inspection; the records said {before:g} {product.unit}."
    if notes and notes.strip():
        explanation += f" {notes.strip()}"
    changes = []
    for lot in lots:
        change = round(targets.get(lot.id, 0.0) - lot.quantity_on_hand, 6)
        if abs(change) < EPS:
            continue
        _post(db, product, item, lot=lot, direction="in" if change > 0 else "out", quantity=abs(change), unit_cost=unit_cost_of(lot, product, item),
              reason="count_correction", linked_entity_type="feed_stock_count", linked_entity_id=count_id, when=when, user_id=user.id)
        changes.append({"lot_id": lot.id, "lot_code": lot.lot_code, "change": round(change, 3)})
    settled = []
    for exc in list_exceptions(db, product.farm_id, status="open", feed_product_id=product.id):
        qty = exception_open(exc)
        _settle(db, exc, product, item, quantity=qty, resolution="count", note=explanation, user_id=user.id, when=when,
                reference_id=count_id, linked_entity_type="feed_stock_count", linked_entity_id=count_id)
        settled.append({"exception_id": exc.id, "quantity": qty})
    # Anything still on record with no lot (only a defect could leave it) is
    # not in the store either: the count is the store.
    if item is not None:
        stray = round(float(item.current_qty or 0) - sum(l.quantity_on_hand for l in product.lots), 6)
        if abs(stray) > EPS:
            _post(db, product, item, lot=None, direction="out" if stray > 0 else "in", quantity=abs(stray), unit_cost=None,
                  reason="count_correction", linked_entity_type="feed_stock_count", linked_entity_id=count_id, when=when, user_id=user.id)
    delta = round(counted - before, 3)
    write_audit_log(
        db, farm_id=product.farm_id, user_id=user.id, action="feed_stock_counted", entity_type="feed_product", entity_id=product.id,
        module_code="feed_nutrition", summary=f"{user.name} counted {product.name}: {counted:g} {product.unit} (records {before:g}, {delta:+g})",
        changes={"on_hand": {"from": before, "to": counted}},
        metadata={"count_id": count_id, "lot_before": lot_before, "exceptions_settled": settled},
    )
    write_event(
        db, farm_id=product.farm_id, entity_type="feed_product", entity_id=product.id, event_type="feed_stock_counted",
        payload={"count_id": count_id, "counted": counted, "before": before, "delta": delta, "unit": product.unit,
                 "counted_at": when.isoformat(), "notes": notes, "lots": changes, "exceptions_settled": settled},
        created_by=user.id,
    )
    return {"count_id": count_id, "feed_product_id": product.id, "unit": product.unit, "before": before, "counted": counted,
            "delta": delta, "counted_at": when, "lots": changes, "exceptions_settled": settled}


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
    # Two reservations of the last free kilos are decided one after the other.
    lock_stock(db, product)
    lot = get_lot(db, lot_id, product.farm_id) if lot_id else None
    if lot is not None and lot.feed_product_id != product.id:
        raise FeedError(f"Lot {lot.lot_code} is not {product.name}.")
    plan = _issue_plan(db, product, None)
    free = plan.available
    if lot is not None:
        free = min(free, plan.lot_free.get(lot.id, 0.0))
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
    lock_stock(db, db.get(fm.FeedProduct, alloc.feed_product_id))
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
    lock_stock(db, db.get(fm.FeedProduct, alloc.feed_product_id))
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
        # Exposure is feed that was given (left the store): a refusal or an
        # intake estimate naming the lot is not a second exposure (v0.8.6).
        if event is None or event.status != "recorded" or event.event_type not in ("offered", "delivered"):
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
        downstream_batches.append({"batch_id": batch.id, "batch_code": batch.batch_code, "mix_number": batch.mix_number, "mix_code": batch.mix_code,
                                   "status": batch.status, "quantity_used": comp.actual_quantity, "unit": comp.unit, "output_lot_id": batch.output_lot_id})
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
    mix = None
    if lot.feed_batch_id:
        batch = db.get(fm.FeedBatch, lot.feed_batch_id)
        if batch is not None:
            mix = {"batch_id": batch.id, "mix_number": batch.mix_number, "mix_code": batch.mix_code, "intended_species_code": batch.intended_species_code}
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
        "mix": mix,
        "upstream_ingredient_lots": upstream,
        "downstream_batches": downstream_batches,
        "feeding_events": sorted(events_out, key=lambda e: e["occurred_at"]),
        "exposed_subjects": sorted(exposed.values(), key=lambda e: -e["quantity"]),
        # Feed issued with no lot that names this lot: the lot that was asked
        # for and held too little, or the lot an exception was reconciled to.
        "stock_exceptions": [exception_to_dict(db, e) for e in db.scalars(select(fm.FeedStockException).where(
            (fm.FeedStockException.lot_id == lot.id) | (fm.FeedStockException.resolution_lot_id == lot.id)))],
    }


def exception_to_dict(db: Session, exc: fm.FeedStockException) -> dict:
    def name(user_id: str | None) -> str | None:
        user = db.get(models.User, user_id) if user_id else None
        return user.name if user else None

    product = db.get(fm.FeedProduct, exc.feed_product_id)
    lot = db.get(fm.FeedLot, exc.lot_id) if exc.lot_id else None
    res_lot = db.get(fm.FeedLot, exc.resolution_lot_id) if exc.resolution_lot_id else None
    return {
        "id": exc.id, "feed_product_id": exc.feed_product_id, "feed_product_name": product.name if product else None, "kind": exc.kind,
        "quantity": round(exc.quantity, 3), "resolved_quantity": round(exc.resolved_quantity or 0, 3), "open_quantity": round(exception_open(exc), 3),
        "unit": exc.unit, "status": exc.status, "reason": exc.reason,
        "requested_by": exc.requested_by, "requested_by_name": name(exc.requested_by),
        "approved_by": exc.approved_by, "approved_by_name": name(exc.approved_by), "approval_request_id": exc.approval_request_id,
        "source_entity_type": exc.source_entity_type, "source_entity_id": exc.source_entity_id,
        "lot_id": exc.lot_id, "lot_code": lot.lot_code if lot else None, "occurred_at": exc.occurred_at, "created_at": exc.created_at,
        "resolution": exc.resolution, "resolution_note": exc.resolution_note, "resolution_lot_id": exc.resolution_lot_id,
        "resolution_lot_code": res_lot.lot_code if res_lot else None, "resolved_by": exc.resolved_by, "resolved_by_name": name(exc.resolved_by),
        "resolved_at": exc.resolved_at, "detail": exc.detail or {},
    }
