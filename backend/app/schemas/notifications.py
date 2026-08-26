"""Notification, priority and audit response shapes (tech spec §3/§5/§23)."""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel

from app.schemas.common import ORMModel


class NotificationOut(ORMModel):
    id: str
    module_code: str
    notification_type: str
    title: str
    description: str | None = None
    priority: str
    entity_type: str | None = None
    entity_id: str | None = None
    source_type: str | None = None
    source_id: str | None = None
    read_at: datetime | None = None
    created_at: datetime

    @property
    def is_read(self) -> bool:
        return self.read_at is not None


class NotificationsPage(BaseModel):
    unread_count: int
    total: int
    notifications: list[NotificationOut]


class PriorityOut(BaseModel):
    """One actionable item in the Today's Priorities feed. `entity_type`
    and `entity_id` are what the tablet turns into a deep link, so every
    card opens the record that produced it.
    """

    id: str
    kind: str  # alert | task
    module_code: str
    notification_type: str
    title: str
    description: str | None = None
    priority: str
    status: str
    entity_type: str
    entity_id: str
    source_type: str
    source_id: str
    due_at: str | None = None
    assigned_to: str | None = None
    assigned_to_name: str | None = None
    metadata: dict = {}


class PrioritiesPage(BaseModel):
    total: int
    counts_by_priority: dict[str, int]
    counts_by_module: dict[str, int]
    priorities: list[PriorityOut]


class AuditEventOut(ORMModel):
    id: str
    user_id: str
    user_name: str | None = None
    action: str
    entity_type: str
    entity_id: str
    module_code: str | None = None
    summary: str | None = None
    changes_json: dict | None = None
    metadata_json: dict = {}
    device: str | None = None
    timestamp: datetime
