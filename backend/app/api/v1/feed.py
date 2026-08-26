from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.base import get_db
from app.domain import models
from app.repositories.base import new_id, now, write_event
from app.schemas.feed import FeedTransactionCreate, InventoryItemOut

router = APIRouter(prefix="/feed", tags=["feed"])


@router.get("/items", response_model=list[InventoryItemOut])
def list_inventory_items(farm_id: str, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)) -> list[models.InventoryItem]:
    return list(db.scalars(select(models.InventoryItem).where(models.InventoryItem.farm_id == farm_id).order_by(models.InventoryItem.name)))


@router.post("/transactions", response_model=InventoryItemOut, status_code=status.HTTP_201_CREATED)
def create_feed_transaction(
    payload: FeedTransactionCreate, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)
) -> models.InventoryItem:
    """Validation rule (tech spec §14): "Inventory should not go negative
    without explicit override."
    """
    item = db.get(models.InventoryItem, payload.item_id)
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Inventory item not found")

    delta = -payload.quantity if payload.direction == "out" else payload.quantity
    new_qty = item.current_qty + delta
    if new_qty < 0 and not payload.allow_negative:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"This transaction would take {item.name} to {new_qty:.1f} {item.unit}. "
            "Pass allow_negative=true to override.",
        )

    transaction = models.InventoryTransaction(
        id=new_id(),
        item_id=item.id,
        direction=payload.direction,
        quantity=payload.quantity,
        reason=payload.reason,
        linked_entity_type=payload.linked_entity_type,
        linked_entity_id=payload.linked_entity_id,
        created_at=now(),
    )
    item.current_qty = new_qty
    db.add(transaction)
    write_event(
        db,
        farm_id=item.farm_id,
        entity_type="inventory_item",
        entity_id=item.id,
        event_type="feed_transaction",
        payload={"direction": payload.direction, "quantity": payload.quantity, "reason": payload.reason},
        created_by=current_user.id,
    )
    db.commit()
    db.refresh(item)
    return item
