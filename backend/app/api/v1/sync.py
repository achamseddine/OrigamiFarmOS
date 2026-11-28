from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import ensure_own_farm, get_current_user, require_farm_access
from app.db.base import get_db
from app.domain import models
from app.core.record_time import not_in_future
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
    ensure_own_farm(current_user, payload.farm_id)
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
        task = _own(db, models.Task, item.entity_id, farm_id)
        if task is not None:
            task.status = payload["status"]
        return

    if item.entity_type == "animal" and {"session", "liters", "destination"} <= payload.keys():
        # `item.entity_id` is the *animal's* id here (the event's subject),
        # not a milk-record id — each push item is a new, immutable milk
        # entry, so it always gets a fresh row. Duplicate delivery of the
        # same batch is already handled by the idempotency_key check above.
        # A replay is judged at the milking's own time (v0.8.5): the
        # lactation that covers it, and a withdrawal the dated history puts
        # on it. Milk a recorded withdrawal covers is kept but held (ADR-008:
        # the device recorded it offline, and the milk may be in the tank);
        # a milking she cannot have given is rejected back to the device.
        # Never stored as saleable.
        from app.schemas.production import ALLOWED_MILK_DESTINATIONS, MAX_LITERS_PER_MILKING, MILK_SESSIONS
        from app.services import milk_safety_service as milk_safety
        from app.services import milk_service

        animal = _own(db, models.Animal, item.entity_id, farm_id)
        if animal is None:
            raise ValueError("Animal not found on this farm")
        session, destination = payload["session"], payload["destination"]
        liters = float(payload["liters"])
        if session not in MILK_SESSIONS or destination not in ALLOWED_MILK_DESTINATIONS or not 0 <= liters <= MAX_LITERS_PER_MILKING:
            raise ValueError("Milk entry has an unknown session or destination, or an impossible amount")
        at = not_in_future(item.client_created_at, "Milk")
        try:
            check = milk_service.check_milk(db, animal, at, destination, recorded_offline_at=at)
        except milk_service.MilkError as exc:
            raise ValueError(exc.message) from exc
        record = models.MilkRecord(
            id=new_id(), animal_id=animal.id, session=session, liters=liters, destination=destination,
            recorded_at=at, recorded_by=created_by,
        )
        milk_service.apply_check(record, check, animal)
        db.add(record)
        if record.release_status == milk_safety.HELD:
            db.flush()
            title = (f"{liters:g} L of {animal.name}'s milk under withdrawal entered offline as {destination}" if check.held_offline_under_withdrawal
                     else f"{liters:g} L of {animal.name}'s milk held for review")
            milk_safety._notify_reviewers(db, animal, title, record.safety_note or "", key=f"held:{record.id}")
            recorder = db.get(models.User, created_by) if created_by else None
            if recorder is not None and check.held_offline_under_withdrawal:
                milk_safety.notify_recorder(db, animal, recorder, title, record.safety_note or "", key=f"held:{record.id}")
        return

    if item.entity_type == "inventory_item" and {"direction", "quantity"} <= payload.keys():
        target = _own(db, models.InventoryItem, item.entity_id, farm_id)
        if target is not None:
            from app.services import feed_inventory_service as feed_inv

            if feed_inv.product_for_item(db, target.id) is not None:
                # Feed stock moves only through its lot ledger (v0.8.4): a bare
                # quantity from the device would change the stock line with no
                # movement and no lot. Rejected, so the device keeps it to show.
                raise ValueError("Feed stock is recorded as a feeding, a delivery or a count, not as a bare quantity.")
            delta = -payload["quantity"] if payload["direction"] == "out" else payload["quantity"]
            target.current_qty = max(target.current_qty + delta, 0)
        return
    # Other event types (observation_recorded, treatment_recorded, ...) are
    # accepted and event-logged by the caller without a domain-row write in
    # this build — see the docstring on `push`.


def _own(db: Session, model, entity_id: str, farm_id: str):
    """The row, if it exists on this farm. Another farm's row is refused
    rather than skipped, so the item is reported back as rejected."""
    row = db.get(model, entity_id)
    if row is not None and row.farm_id != farm_id:
        raise ValueError(f"{model.__name__} not found on this farm")
    return row


@router.get("/pull", response_model=SyncPullResponse)
def pull(
    cursor: str | None = Query(None, description="ISO-8601 timestamp; events after this are returned"),
    limit: int = Query(100, le=500),
    db: Session = Depends(get_db),
    user: models.User = Depends(require_farm_access()),
) -> SyncPullResponse:
    """GET /sync/pull — changes since `cursor` (tech spec §12)."""
    stmt = select(models.Event).where(models.Event.farm_id == user.farm_id)
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
