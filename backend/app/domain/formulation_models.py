"""Least-cost formulation runs (master prompt Package 12; database/LEAST-COST-FORMULATION.md).

    a run: the requirement set (one version), the ingredients the manager
      allows and their limits, the ration, the prices of the day
    → up to three drafts — the cheapest, the cheapest with a safety margin,
      the closest to the current formula — or *infeasible* (which limits
      cannot be met), or *insufficient data* (what is not known)
    → a manager approves one draft: it becomes a new *draft* version of the
      formula, to be activated by the usual formula approval

A draft is a plan: it never moves stock, never changes a formula, a batch or
a price. Its prices are kept as they were the day it was computed, so a later
price never rewrites it nor any batch.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, DateTime, ForeignKey, Index, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


RUN_STATUSES = ("drafts", "infeasible", "insufficient_data")


class FormulationRun(Base):
    __tablename__ = "formulation_runs"
    __table_args__ = (Index("ix_formulation_runs_farm_created", "farm_id", "created_at"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    requirement_set_id: Mapped[str] = mapped_column(String(36), ForeignKey("nutrition_requirement_sets.id"))
    base_formula_version_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("feed_formula_versions.id"), nullable=True)
    status: Mapped[str] = mapped_column(String(30))
    inputs: Mapped[dict] = mapped_column(JSON, default=dict)
    # The drafts, the prices used, what was infeasible or missing — as computed.
    result: Mapped[dict] = mapped_column(JSON, default=dict)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    # Approval of one draft (once): the new draft formula version it became.
    approved_draft: Mapped[str | None] = mapped_column(String(10), nullable=True)
    approved_by: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    approval_note: Mapped[str | None] = mapped_column(Text, nullable=True)
    approved_formula_version_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("feed_formula_versions.id"), nullable=True)
