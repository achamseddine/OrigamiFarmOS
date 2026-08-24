from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel

from app.schemas.common import ORMModel


class TaskCreate(BaseModel):
    farm_id: str
    title: str
    description: str | None = None
    assigned_to: str | None = None
    due_at: datetime | None = None
    priority: str = "medium"
    source_type: str | None = None
    source_id: str | None = None


class TaskUpdate(BaseModel):
    status: str | None = None
    assigned_to: str | None = None
    priority: str | None = None


class TaskOut(ORMModel):
    id: str
    farm_id: str
    title: str
    description: str | None = None
    assigned_to: str | None = None
    due_at: datetime | None = None
    priority: str
    status: str
    source_type: str | None = None
    source_id: str | None = None
