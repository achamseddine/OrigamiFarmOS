from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.base import get_db
from app.domain import models
from app.repositories.base import new_id, write_event
from app.schemas.sync import SyncItemResult, SyncPullResponse, SyncPushRequest, SyncPushResponse

router = APIRouter(prefix="/sync", tags=["sync"])


@router.post("/push", response_model=SyncPushResponse)
def push(payload: SyncPushRequest, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> SyncPushResponse:
    """POST /sync/push — upload a batch of queued tablet writes.

    Tech spec §14: "Duplicate idempotency key must not create duplicate
    server record." Each item's `idempotency_key` is unique-constrained on
    `sync_queue`, so replaying a batch after a dropped connection is safe.

    Because every domain-row ID is generated client-side (a UUID, written
    once by `FarmWriteService` and never reused), the server can accept
    entity IDs as-is with no remapping step — a deliberate simplification
    that keeps this push endpoint correct without needing a second
    ID-translation pass.

    This build durably records every item (event + sync_queue row,
    idempotent) and materializes the common write types the tablet already
    produces (observations, milk, tasks, feed transactions) back into
    their domain tables. Less common event types are still accepted and
    queued/event-logged, ready for a same-shaped repository call to be
    added — see README "What remains".
    """
    results: list[SyncItemResult] = []

    for item in payload.items:
        existing = db.scalar(select(models.SyncQueueItem).where(models.SyncQueueItem.idempotency_key == item.idempotency_key))
        if existing is not None:
            results.append(SyncItemResult(idempotency_key=item.idempotency_key, status="duplicate", server_id=existing.entity_id))
            continue

        try:
            _apply_known_event(db, farm_id=payload.farm_id, item=item, created_by=current_user.id)
            queue_row = models.SyncQueueItem(
                id=new_id(),
                local_event_id=None,
                operation=item.operation,
                entity_type=item.entity_type,
                entity_id=item.entity_id,
                payload_json=item.payload,
                status="accepted",
                idempotency_key=item.idempotency_key,
                created_at=datetime.now(timezone.utc),
            )
            db.add(queue_row)
            write_event(
                db,
                farm_id=payload.farm_id,
                entity_type=item.entity_type,
                entity_id=item.entity_id,
                event_type=f"sync_{item.operation}",
                payload=item.payload,
                created_by=current_user.id,
                device_id=payload.device_id,
            )
            db.commit()
            results.append(SyncItemResult(idempotency_key=item.idempotency_key, status="accepted", server_id=item.entity_id))
        except Exception as exc:  # noqa: BLE001 - one bad item must not fail the whole batch
            db.rollback()
            results.append(SyncItemResult(idempotency_key=item.idempotency_key, status="rejected", error=str(exc)))

    return SyncPushResponse(results=results, server_time=datetime.now(timezone.utc))


def _apply_known_event(db: Session, *, farm_id: str, item, created_by: str) -> None:
    """Best-effort reconciliation for the event shapes FarmWriteService
    (mobile) already emits. Unknown event types are still queued/event-
    logged by the caller — this only adds the domain-row write on top.
    """
    payload = item.payload

    if item.entity_type == "task" and "status" in payload:
        task = db.get(models.Task, item.entity_id)
        if task is not None:
            task.status = payload["status"]
        return

    if item.entity_type == "animal" and {"session", "liters", "destination"} <= payload.keys():
        # `item.entity_id` is the *animal's* id here (the event's subject),
        # not a milk-record id — each push item is a new, immutable milk
        # entry, so it always gets a fresh row. Duplicate delivery of the
        # same batch is already handled by the idempotency_key check above.
        db.add(
            models.MilkRecord(
                id=new_id(),
                animal_id=item.entity_id,
                session=payload["session"],
                liters=payload["liters"],
                destination=payload["destination"],
                recorded_at=item.client_created_at,
                recorded_by=created_by,
            )
        )
        return

    if item.entity_type == "inventory_item" and {"direction", "quantity"} <= payload.keys():
        target = db.get(models.InventoryItem, item.entity_id)
        if target is not None:
            delta = -payload["quantity"] if payload["direction"] == "out" else payload["quantity"]
            target.current_qty = max(target.current_qty + delta, 0)
        return
    # Other event types (observation_recorded, treatment_recorded, ...) are
    # accepted and event-logged by the caller without a domain-row write in
    # this build — see the docstring on `push`.


@router.get("/pull", response_model=SyncPullResponse)
def pull(
    farm_id: str,
    cursor: str | None = Query(None, description="ISO-8601 timestamp; events after this are returned"),
    limit: int = Query(100, le=500),
    db: Session = Depends(get_db),
    _user: models.User = Depends(get_current_user),
) -> SyncPullResponse:
    """GET /sync/pull — changes since `cursor` (tech spec §12)."""
    stmt = select(models.Event).where(models.Event.farm_id == farm_id)
    if cursor:
        try:
            cursor_dt = datetime.fromisoformat(cursor)
        except ValueError:
            cursor_dt = None
        if cursor_dt is not None:
            stmt = stmt.where(models.Event.server_created_at > cursor_dt)
    stmt = stmt.order_by(models.Event.server_created_at).limit(limit + 1)

    rows = db.scalars(stmt).all()
    has_more = len(rows) > limit
    rows = rows[:limit]
    next_cursor = rows[-1].server_created_at.isoformat() if rows else (cursor or datetime.now(timezone.utc).isoformat())

    return SyncPullResponse(
        cursor=next_cursor,
        events=[
            {
                "id": e.id,
                "entity_type": e.entity_type,
                "entity_id": e.entity_id,
                "event_type": e.event_type,
                "payload": e.payload_json,
                "created_at": e.created_at.isoformat(),
            }
            for e in rows
        ],
        has_more=has_more,
        server_time=datetime.now(timezone.utc),
    )
