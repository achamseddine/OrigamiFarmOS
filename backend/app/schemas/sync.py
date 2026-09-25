from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel


class SyncPushItem(BaseModel):
    """One queued item from the tablet's local `sync_queue` table
    (tech spec §9/§10). `idempotency_key` prevents duplicate server
    records when the same batch is retried after a dropped connection
    (tech spec §14: "Duplicate idempotency key must not create duplicate
    server record.").
    """

    idempotency_key: str
    operation: str  # create | update
    entity_type: str
    entity_id: str
    payload: dict
    client_created_at: datetime
    device_id: str | None = None


class SyncPushRequest(BaseModel):
    farm_id: str
    device_id: str
    items: list[SyncPushItem]


class SyncItemResult(BaseModel):
    idempotency_key: str
    status: str  # accepted | rejected | conflict | duplicate
    server_id: str | None = None
    error: str | None = None


class SyncPushResponse(BaseModel):
    results: list[SyncItemResult]
    server_time: datetime


class SyncPullResponse(BaseModel):
    cursor: str
    events: list[dict]
    has_more: bool
    server_time: datetime
