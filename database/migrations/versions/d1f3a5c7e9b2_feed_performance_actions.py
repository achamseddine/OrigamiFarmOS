"""Feed performance actions and their measured outcomes (v0.8.20, master prompt Package 13).

Revision ID: d1f3a5c7e9b2
Revises: c9e1a3b5d7f0
Create Date: 2026-11-27

Schema
- feed_performance_actions: the manager's action on a feed performance
  alert (its assessment, monitor, subject and metric), what is expected and
  when to measure; then the outcome measured once — baseline, result,
  change, as expected / no change / opposite / insufficient data, the
  confidence and the confounders it was lowered for — its review, or its
  cancellation with a reason.

Data — nothing existing is changed: alerts, assessments and production
records are read; an action acknowledges its open alert through the
existing service. Downgrade drops the table.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "d1f3a5c7e9b2"
down_revision = "c9e1a3b5d7f0"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "feed_performance_actions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("alert_id", sa.String(36), sa.ForeignKey("feed_performance_alerts.id"), nullable=False),
        sa.Column("assessment_id", sa.String(36), sa.ForeignKey("feed_performance_assessments.id"), nullable=True),
        sa.Column("monitor_id", sa.String(36), sa.ForeignKey("feed_performance_monitors.id"), nullable=False),
        sa.Column("subject_type", sa.String(10), nullable=False),
        sa.Column("subject_id", sa.String(36), nullable=False),
        sa.Column("metric_code", sa.String(40), nullable=False),
        sa.Column("action_type", sa.String(40), nullable=False),
        sa.Column("description", sa.Text(), nullable=False),
        sa.Column("expected_effect", sa.String(20), nullable=False),
        sa.Column("linked_entity_type", sa.String(60), nullable=True),
        sa.Column("linked_entity_id", sa.String(36), nullable=True),
        sa.Column("decided_by", sa.String(36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("decided_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("baseline_days", sa.Integer(), nullable=False),
        sa.Column("measure_after_days", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("measured_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("baseline_value", sa.Float(), nullable=True),
        sa.Column("outcome_value", sa.Float(), nullable=True),
        sa.Column("change_pct", sa.Float(), nullable=True),
        sa.Column("outcome", sa.String(30), nullable=True),
        sa.Column("confidence_score", sa.Float(), nullable=True),
        sa.Column("evidence_json", sa.JSON(), nullable=False),
        sa.Column("explanation", sa.Text(), nullable=True),
        sa.Column("reviewed_by", sa.String(36), sa.ForeignKey("users.id"), nullable=True),
        sa.Column("reviewed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("cancel_reason", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("measure_after_days > 0 AND baseline_days > 0", name="ck_feed_perf_actions_windows"),
    )
    op.create_index("ix_feed_perf_actions_alert", "feed_performance_actions", ["alert_id"])
    op.create_index("ix_feed_perf_actions_farm_status", "feed_performance_actions", ["farm_id", "status"])


def downgrade() -> None:
    op.drop_index("ix_feed_perf_actions_farm_status", table_name="feed_performance_actions")
    op.drop_index("ix_feed_perf_actions_alert", table_name="feed_performance_actions")
    op.drop_table("feed_performance_actions")
