"""Work an employee did that waits for the farm manager (handbook/
03-Behavioral-Model.md §5, approval before effect).

An employee records the day's facts — milk, feedings — directly. Making
a numbered feed mix and correcting a record already on file are not
facts of the day but changes to the farm's stock and history, and the
farm decides them through its manager: the employee's version is kept
here as a *request*, and nothing in stock, mixes or records changes until
someone with approval on the module approves it. A rejected or cancelled
request changes nothing. Buying feed goes through purchase requisitions
(procurement_models.py), not through this table.

A request is never a transaction (CLAUDE.md: "Plans/recommendations are
never stored as actual transactions"): approving it runs the same service
the manager would have used directly, as the manager, recording who asked
and who approved.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, DateTime, ForeignKey, Index, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base

# feed_mix: a numbered mix as it was made (POST /feed-mixes body).
# milk_correction: new values for one milk record (target = the record).
# feeding_correction: undo one feeding, optionally with what was really fed
# (target = the feeding event).
APPROVAL_KINDS = ("feed_mix", "milk_correction", "feeding_correction")
APPROVAL_STATUSES = ("pending", "approved", "rejected", "cancelled")


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


class ApprovalRequest(Base):
    __tablename__ = "approval_requests"
    __table_args__ = (
        Index("ix_approval_requests_status", "farm_id", "status"),
        Index("ix_approval_requests_target", "farm_id", "target_id"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    kind: Mapped[str] = mapped_column(String(40))
    # The module whose approval decides it (feed_nutrition, milk_production).
    module_code: Mapped[str] = mapped_column(String(40))
    status: Mapped[str] = mapped_column(String(20), default="pending")
    # The animal / group the request is about, for the manager's list.
    subject_type: Mapped[str | None] = mapped_column(String(30), nullable=True)
    subject_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    # The record a correction changes.
    target_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    summary: Mapped[str] = mapped_column(String(300))
    # The employee's version, as the direct endpoint would take it.
    payload: Mapped[dict] = mapped_column(JSON, default=dict)
    reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    requested_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"))
    requested_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    decided_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    decision_note: Mapped[str | None] = mapped_column(Text, nullable=True)
    # What approving it created or changed (feed_batch, milk_record, feeding_event).
    result_type: Mapped[str | None] = mapped_column(String(40), nullable=True)
    result_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
