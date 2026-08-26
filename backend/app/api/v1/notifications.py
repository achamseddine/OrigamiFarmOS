"""The notification bell (tech spec §3).

Notifications are *derived*, not hand-written: [signals_service] recomputes
what the farm is currently complaining about on every read, and this router
persists each distinct signal once so read/unread state survives. A signal
that stops being true (stock reordered, treatment finished) simply stops
being regenerated, and its row is retired rather than nagging forever.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, load_permission_map
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.repositories.base import new_id, now
from app.schemas.notifications import NotificationOut, NotificationsPage
from app.services import signals_service

router = APIRouter(tags=["notifications"])


def _sync_notifications(db: Session, farm_id: str) -> list[models.Notification]:
    """Reconciles stored notifications with what is true right now.

    New signal -> new row (unread). Still-true signal -> existing row kept,
    with its read state. No-longer-true signal -> row removed, because a
    resolved problem is not news; the underlying event stays in the event
    log either way.
    """
    signals = signals_service.collect_signals(db, farm_id)
    live_keys = {(s.source_type, s.source_id) for s in signals}

    existing = list(db.scalars(select(models.Notification).where(models.Notification.farm_id == farm_id)))
    by_key = {(n.source_type, n.source_id): n for n in existing}

    for row in existing:
        if (row.source_type, row.source_id) not in live_keys:
            db.delete(row)

    for signal in signals:
        row = by_key.get((signal.source_type, signal.source_id))
        if row is None:
            db.add(
                models.Notification(
                    id=new_id(),
                    farm_id=farm_id,
                    user_id=signal.assigned_to,
                    module_code=signal.module_code,
                    notification_type=signal.notification_type,
                    title=signal.title,
                    description=signal.description,
                    priority=signal.priority,
                    entity_type=signal.entity_type,
                    entity_id=signal.entity_id,
                    source_type=signal.source_type,
                    source_id=signal.source_id,
                    created_at=now(),
                )
            )
        else:
            # Keep the wording current (a stock level moves, a task's title
            # is edited) without disturbing whether it has been read.
            row.title = signal.title
            row.description = signal.description
            row.priority = signal.priority
            row.module_code = signal.module_code
            row.entity_type = signal.entity_type
            row.entity_id = signal.entity_id

    db.commit()
    return list(
        db.scalars(
            select(models.Notification)
            .where(models.Notification.farm_id == farm_id)
            .order_by(models.Notification.created_at.desc())
        )
    )


def _visible(rows: list[models.Notification], user: models.User, permission_map: dict) -> list[models.Notification]:
    """A notification reaches a user only if they hold the module it came
    from, and it is either farm-wide or addressed to them personally.
    """
    out = []
    for row in rows:
        if row.user_id is not None and row.user_id != user.id:
            continue
        if not permission_map.get(row.module_code, {}).get(perms.VIEW, False):
            continue
        out.append(row)
    return out


_PRIORITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}


@router.get("/notifications", response_model=NotificationsPage)
def list_notifications(
    unread_only: bool = False,
    module: str | None = None,
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    rows = _sync_notifications(db, current_user.farm_id)
    permission_map = load_permission_map(db, current_user)
    visible = _visible(rows, current_user, permission_map)

    unread_count = sum(1 for r in visible if r.read_at is None)
    filtered = visible
    if module:
        filtered = [r for r in filtered if r.module_code == module]
    if unread_only:
        filtered = [r for r in filtered if r.read_at is None]

    filtered.sort(key=lambda r: (_PRIORITY_RANK.get(r.priority, 5), -r.created_at.timestamp()))
    return {
        "unread_count": unread_count,
        "total": len(visible),
        "notifications": filtered[:limit],
    }


@router.post("/notifications/{notification_id}/read", response_model=NotificationOut)
def mark_read(
    notification_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.Notification:
    row = db.get(models.Notification, notification_id)
    if row is None or row.farm_id != current_user.farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Notification not found")
    if row.read_at is None:
        row.read_at = now()
        db.commit()
        db.refresh(row)
    return row


@router.post("/notifications/read-all")
def mark_all_read(
    module: str | None = None,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    # Sync first: "mark all read" has to mean everything the bell would
    # show right now, including alerts this session has not fetched yet —
    # otherwise clearing the badge before opening the panel marks nothing.
    rows = _sync_notifications(db, current_user.farm_id)
    permission_map = load_permission_map(db, current_user)
    marked = 0
    stamp = now()
    for row in _visible(rows, current_user, permission_map):
        if module and row.module_code != module:
            continue
        if row.read_at is None:
            row.read_at = stamp
            marked += 1
    db.commit()
    return {"marked_read": marked}
