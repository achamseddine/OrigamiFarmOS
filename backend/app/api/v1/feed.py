from __future__ import annotations

from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.base import get_db
from app.domain import feed_models as fm
from app.domain import models
from app.repositories.base import new_id, now, write_event
from app.schemas.feed import FeedTransactionCreate, InventoryItemOut
from app.schemas.feeding import InventoryMovementOut
from app.services import feed_inventory_service as inv

router = APIRouter(prefix="/feed", tags=["feed"])

# Inventory categories that are stock but not feed: they keep the plain
# item ledger and never become feed products or lots.
_NOT_FEED = {"medicine", "medication", "vet", "veterinary", "produce"}


def _is_feed(item: models.InventoryItem) -> bool:
    return (item.category or "").strip().lower() not in _NOT_FEED


@router.get("/items", response_model=list[InventoryItemOut])
def list_inventory_items(farm_id: str, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)) -> list[models.InventoryItem]:
    return list(db.scalars(select(models.InventoryItem).where(models.InventoryItem.farm_id == farm_id).order_by(models.InventoryItem.name)))


@router.get("/transactions", response_model=list[InventoryMovementOut])
def list_feed_transactions(
    farm_id: str, days: int = Query(30, ge=1, le=365), db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)
) -> list[dict]:
    """The movement history behind the feed screen's "recent movements":
    newest first, each with the lot it belongs to."""
    since = now() - timedelta(days=days)
    rows = db.execute(
        select(models.InventoryTransaction, fm.FeedProduct.id)
        .join(models.InventoryItem, models.InventoryItem.id == models.InventoryTransaction.item_id)
        .outerjoin(fm.FeedProduct, fm.FeedProduct.inventory_item_id == models.InventoryItem.id)
        .where(models.InventoryItem.farm_id == farm_id, models.InventoryTransaction.created_at >= since)
        .order_by(models.InventoryTransaction.created_at.desc())
    ).all()
    return [
        {
            "id": t.id, "inventory_item_id": t.item_id, "feed_product_id": product_id, "lot_id": t.lot_id, "direction": t.direction,
            "quantity": t.quantity, "unit_cost": t.unit_cost, "reason": t.reason, "linked_entity_type": t.linked_entity_type,
            "linked_entity_id": t.linked_entity_id, "occurred_at": t.created_at,
        }
        for t, product_id in rows
    ]


@router.post("/transactions", response_model=InventoryItemOut, status_code=status.HTTP_201_CREATED)
def create_feed_transaction(
    payload: FeedTransactionCreate, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)
) -> models.InventoryItem:
    """Validation rule (tech spec §14): "Inventory should not go negative
    without explicit override."

    Feed items are lot-tracked (feed architecture §26): an `in` becomes a
    received lot, an `out` is issued FIFO from usable, unreserved lots,
    and either way the movement names its lot. Non-feed stock (medicine)
    keeps the plain item ledger.
    """
    item = db.get(models.InventoryItem, payload.item_id)
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Inventory item not found")

    if _is_feed(item):
        product = inv.ensure_product_for_item(db, item, created_by=current_user.id)
        if payload.direction == "in":
            inv.receive(db, product, quantity=payload.quantity, unit=payload.unit, reference=payload.reason,
                        notes=payload.reason, user_id=current_user.id)
        else:
            inv.consume(
                db, product, payload.quantity, payload.unit, reason=payload.reason or "feeding",
                linked_entity_type=payload.linked_entity_type or "inventory_item", linked_entity_id=payload.linked_entity_id or item.id,
                purpose=_purpose_for(db, payload), allow_negative=payload.allow_negative, user_id=current_user.id,
            )
        db.commit()
        db.refresh(item)
        return item

    delta = -payload.quantity if payload.direction == "out" else payload.quantity
    new_qty = item.current_qty + delta
    if new_qty < 0 and not payload.allow_negative:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"This transaction would take {item.name} to {new_qty:.1f} {item.unit}. "
            "Pass allow_negative=true to override.",
        )
    transaction = models.InventoryTransaction(
        id=new_id(), item_id=item.id, direction=payload.direction, quantity=payload.quantity, reason=payload.reason,
        linked_entity_type=payload.linked_entity_type, linked_entity_id=payload.linked_entity_id, created_at=now(),
    )
    item.current_qty = new_qty
    db.add(transaction)
    write_event(
        db, farm_id=item.farm_id, entity_type="inventory_item", entity_id=item.id, event_type="feed_transaction",
        payload={"direction": payload.direction, "quantity": payload.quantity, "reason": payload.reason}, created_by=current_user.id,
    )
    db.commit()
    db.refresh(item)
    return item


def _purpose_for(db: Session, payload: FeedTransactionCreate) -> inv.Purpose | None:
    """A distribution linked to an animal is issued *for* that animal, so
    stock reserved for its species or group can be drawn on."""
    if payload.linked_entity_type == "animal" and payload.linked_entity_id:
        animal = db.get(models.Animal, payload.linked_entity_id)
        if animal is not None:
            return inv.Purpose(species_code=animal.species, subject_type="animal", subject_id=animal.id, label=animal.name)
    if payload.linked_entity_type in ("group", "flock") and payload.linked_entity_id:
        group = db.get(models.Flock, payload.linked_entity_id)
        if group is not None:
            return inv.Purpose(species_code=group.species, subject_type="group", subject_id=group.id, label=group.name)
    return None
