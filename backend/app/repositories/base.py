"""Thin data-access helpers shared by the domain repositories.

Kept intentionally small: services call these for common lookups, and use
`db.add`/`db.execute` directly for anything more specific. This is a
pragmatic middle ground for an MVP — a full repository-per-aggregate
abstraction is not worth the indirection yet.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy.orm import Session

from app.domain import models


def new_id() -> str:
    return str(uuid.uuid4())


def now() -> datetime:
    return datetime.now(timezone.utc)


def ensure_utc(dt: datetime) -> datetime:
    """SQLite has no native timezone-aware storage: SQLAlchemy's
    `DateTime(timezone=True)` round-trips a value through SQLite as a
    *naive* datetime even though PostgreSQL would keep it aware. Every
    datetime this app writes is UTC (see `now()` above), so a naive value
    read back is safely assumed to already be UTC. Call this before
    comparing or subtracting any ORM-loaded datetime against a fresh
    `now()` value, so the same code is correct on both SQLite and
    PostgreSQL.
    """
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def write_event(
    db: Session,
    *,
    farm_id: str,
    entity_type: str,
    entity_id: str,
    event_type: str,
    payload: dict,
    created_by: str,
    device_id: str | None = None,
) -> models.Event:
    """Constitution: "Every important change is an event. History is never
    silently deleted." Every mutating endpoint calls this alongside its
    domain-table write.
    """
    event = models.Event(
        id=new_id(),
        farm_id=farm_id,
        entity_type=entity_type,
        entity_id=entity_id,
        event_type=event_type,
        payload_json=payload,
        created_by=created_by,
        device_id=device_id,
        created_at=now(),
        server_created_at=now(),
    )
    db.add(event)
    return event


def write_audit_log(
    db: Session, *, farm_id: str, user_id: str, action: str, entity_type: str, entity_id: str, metadata: dict | None = None
) -> models.AuditLog:
    entry = models.AuditLog(
        id=new_id(),
        farm_id=farm_id,
        user_id=user_id,
        action=action,
        entity_type=entity_type,
        entity_id=entity_id,
        timestamp=now(),
        metadata_json=metadata or {},
    )
    db.add(entry)
    return entry
