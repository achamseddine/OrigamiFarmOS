from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, field_validator

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
    # An open task with the same title for the same person is refused as a
    # possible duplicate unless confirmed (app/core/duplicates.py).
    confirm_duplicate: bool = False

    @field_validator("title")
    @classmethod
    def title_not_blank(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("a task needs a title")
        return v.strip()


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
