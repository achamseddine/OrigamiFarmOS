"""Feed performance → the manager's action → its measured outcome
(master prompt Package 13; database/FEED-PERFORMANCE-ACTIONS.md).

    an alert of the Feed Performance Intelligence (milk down after a feed
      change, a weak ingredient lot…), with its assessment and evidence
    → the manager's action on it: change the lot or the supplier, sample the
      lot, revise the formula, adjust the feeding, a health check — what is
      expected (milk back up), and how long to wait before measuring
    → the outcome, measured once from the canonical production records: the
      baseline before, the result after, the change, met or not, and a
      confidence lowered by every confounder in between (health events,
      calving, group moves, another feed change) — or insufficient data

An action records a decision, never a transaction: changing the lot or the
formula is done in its own workflow and only linked here.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, CheckConstraint, DateTime, Float, ForeignKey, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


ACTION_TYPES = ("change_lot", "change_supplier", "sample_lot", "revise_formula", "adjust_feeding", "health_check", "other")
EXPECTED_EFFECTS = ("increase", "decrease", "no_change")
ACTION_STATUSES = ("measuring", "measured", "cancelled")
OUTCOMES = ("as_expected", "no_change", "opposite", "insufficient_data")


class FeedPerformanceAction(Base):
    __tablename__ = "feed_performance_actions"
    __table_args__ = (
        Index("ix_feed_perf_actions_alert", "alert_id"),
        Index("ix_feed_perf_actions_farm_status", "farm_id", "status"),
        CheckConstraint("measure_after_days > 0 AND baseline_days > 0", name="ck_feed_perf_actions_windows"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    alert_id: Mapped[str] = mapped_column(String(36), ForeignKey("feed_performance_alerts.id"))
    assessment_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("feed_performance_assessments.id"), nullable=True)
    monitor_id: Mapped[str] = mapped_column(String(36), ForeignKey("feed_performance_monitors.id"))
    subject_type: Mapped[str] = mapped_column(String(10))
    subject_id: Mapped[str] = mapped_column(String(36))
    metric_code: Mapped[str] = mapped_column(String(40))
    action_type: Mapped[str] = mapped_column(String(40))
    description: Mapped[str] = mapped_column(Text)
    expected_effect: Mapped[str] = mapped_column(String(20))
    # What the action was done through, when it was (a lot, a formula version…): linked, never done here.
    linked_entity_type: Mapped[str | None] = mapped_column(String(60), nullable=True)
    linked_entity_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    decided_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"))
    decided_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    baseline_days: Mapped[int] = mapped_column(Integer, default=14)
    measure_after_days: Mapped[int] = mapped_column(Integer, default=14)
    status: Mapped[str] = mapped_column(String(20), default="measuring")
    # The outcome, measured once.
    measured_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    baseline_value: Mapped[float | None] = mapped_column(Float, nullable=True)
    outcome_value: Mapped[float | None] = mapped_column(Float, nullable=True)
    change_pct: Mapped[float | None] = mapped_column(Float, nullable=True)
    outcome: Mapped[str | None] = mapped_column(String(30), nullable=True)
    confidence_score: Mapped[float | None] = mapped_column(Float, nullable=True)
    evidence_json: Mapped[dict] = mapped_column(JSON, default=dict)
    explanation: Mapped[str | None] = mapped_column(Text, nullable=True)
    reviewed_by: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)
    reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    cancel_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
