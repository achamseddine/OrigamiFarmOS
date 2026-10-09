"""Feed Performance Intelligence (database/FEED-PERFORMANCE-INTELLIGENCE.md).

Revision ID: d2f4a6c8e0b1
Revises: c9e1a7b2d4f6
Create Date: 2026-10-09

An analytical layer over the canonical feed, production and health
facts. Six tables, all projections the cycle can rebuild: monitors
(what is watched, against which explicit baseline), exposure windows
(which lot/mix each subject actually received, with lineage), assessments
(one evaluation of one monitor, versioned by model reference), batch
performance scores (one per numbered mix), supplier × ingredient
performance rows and deduplicated alerts. Nothing here is a second
feed, stock, production or health truth.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "d2f4a6c8e0b1"
down_revision = "c9e1a7b2d4f6"
branch_labels = None
depends_on = None


def _ts(name: str, nullable: bool = False) -> sa.Column:
    return sa.Column(name, sa.DateTime(timezone=True), nullable=nullable)


def upgrade() -> None:
    op.create_table(
        "feed_performance_monitors",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("subject_type", sa.String(10), nullable=False),
        sa.Column("subject_id", sa.String(36), nullable=False),
        sa.Column("production_metric_code", sa.String(60), nullable=False, server_default="milk_l_per_day"),
        sa.Column("baseline_method_code", sa.String(60), nullable=False, server_default="rolling_subject"),
        sa.Column("baseline_window_days", sa.Integer(), nullable=False, server_default="14"),
        sa.Column("evaluation_window_days", sa.Integer(), nullable=False, server_default="3"),
        sa.Column("evaluation_frequency_code", sa.String(30), nullable=False, server_default="daily"),
        sa.Column("minimum_exposure_days", sa.Float(), nullable=False, server_default="2"),
        sa.Column("minimum_observations", sa.Integer(), nullable=False, server_default="3"),
        sa.Column("alert_threshold_percent", sa.Float(), nullable=False, server_default="5"),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("configuration_json", sa.JSON(), nullable=False, server_default="{}"),
        _ts("created_at"),
        _ts("updated_at"),
    )
    op.create_index("ix_feed_perf_monitor_subject", "feed_performance_monitors", ["farm_id", "subject_type", "subject_id"])

    op.create_table(
        "feed_exposure_windows",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("subject_type", sa.String(10), nullable=False),
        sa.Column("subject_id", sa.String(36), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        sa.Column("lot_id", sa.String(36), sa.ForeignKey("feed_lots.id"), nullable=True),
        sa.Column("feed_batch_id", sa.String(36), sa.ForeignKey("feed_batches.id"), nullable=True),
        _ts("exposure_start"),
        _ts("exposure_end", nullable=True),
        sa.Column("offered_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("consumed_estimate", sa.Float(), nullable=True),
        sa.Column("feeding_event_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("lineage_json", sa.JSON(), nullable=False, server_default="{}"),
        _ts("generated_at"),
    )
    op.create_index("ix_feed_exposure_subject", "feed_exposure_windows", ["farm_id", "subject_type", "subject_id"])
    op.create_index("ix_feed_exposure_batch", "feed_exposure_windows", ["feed_batch_id"])

    op.create_table(
        "feed_performance_assessments",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("monitor_id", sa.String(36), sa.ForeignKey("feed_performance_monitors.id"), nullable=False),
        _ts("evaluated_at"),
        _ts("period_start"),
        _ts("period_end"),
        sa.Column("baseline_value", sa.Float(), nullable=True),
        sa.Column("observed_value", sa.Float(), nullable=True),
        sa.Column("variance_value", sa.Float(), nullable=True),
        sa.Column("variance_percent", sa.Float(), nullable=True),
        sa.Column("feed_related_likelihood", sa.String(30), nullable=False, server_default="INSUFFICIENT_EVIDENCE"),
        sa.Column("confidence_score", sa.Float(), nullable=False, server_default="0"),
        sa.Column("model_reference", sa.String(150), nullable=False),
        sa.Column("model_version", sa.String(100), nullable=False),
        sa.Column("evidence_json", sa.JSON(), nullable=False, server_default="{}"),
        sa.Column("confounders_json", sa.JSON(), nullable=False, server_default="{}"),
        sa.Column("explanation", sa.Text(), nullable=False),
        sa.Column("status", sa.String(30), nullable=False, server_default="normal"),
    )
    op.create_index("ix_feed_perf_assessment_monitor", "feed_performance_assessments", ["monitor_id", "evaluated_at"])

    op.create_table(
        "feed_batch_performance_scores",
        sa.Column("feed_batch_id", sa.String(36), sa.ForeignKey("feed_batches.id"), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        _ts("evaluated_at"),
        sa.Column("exposed_head_count", sa.Integer(), nullable=True),
        sa.Column("exposure_days", sa.Float(), nullable=True),
        sa.Column("formula_compliance_score", sa.Float(), nullable=True),
        sa.Column("intake_response_score", sa.Float(), nullable=True),
        sa.Column("production_response_score", sa.Float(), nullable=True),
        sa.Column("health_signal_score", sa.Float(), nullable=True),
        sa.Column("consistency_score", sa.Float(), nullable=True),
        sa.Column("economic_score", sa.Float(), nullable=True),
        sa.Column("overall_score", sa.Float(), nullable=True),
        sa.Column("confidence_score", sa.Float(), nullable=False, server_default="0"),
        sa.Column("evidence_json", sa.JSON(), nullable=False, server_default="{}"),
    )

    op.create_table(
        "supplier_feed_performance",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("supplier_id", sa.String(36), sa.ForeignKey("suppliers.id"), nullable=True),
        sa.Column("supplier_label", sa.String(200), nullable=False),
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("inventory_items.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        _ts("evaluation_start"),
        _ts("evaluation_end"),
        sa.Column("lot_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("feed_batch_count", sa.Integer(), nullable=True),
        sa.Column("purchase_quantity", sa.Float(), nullable=True),
        sa.Column("average_unit_cost", sa.Float(), nullable=True),
        sa.Column("quality_consistency_score", sa.Float(), nullable=True),
        sa.Column("downstream_performance_score", sa.Float(), nullable=True),
        sa.Column("incident_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("confidence_score", sa.Float(), nullable=False, server_default="0"),
        sa.Column("methodology_code", sa.String(60), nullable=False),
        sa.Column("methodology_version", sa.String(40), nullable=False),
        sa.Column("evidence_json", sa.JSON(), nullable=False, server_default="{}"),
        _ts("generated_at"),
    )
    op.create_index("ix_supplier_feed_perf_farm", "supplier_feed_performance", ["farm_id", "supplier_label"])

    op.create_table(
        "feed_performance_alerts",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("assessment_id", sa.String(36), sa.ForeignKey("feed_performance_assessments.id"), nullable=True),
        sa.Column("feed_batch_id", sa.String(36), sa.ForeignKey("feed_batches.id"), nullable=True),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=True),
        sa.Column("subject_type", sa.String(10), nullable=True),
        sa.Column("subject_id", sa.String(36), nullable=True),
        sa.Column("alert_type", sa.String(60), nullable=False),
        sa.Column("severity", sa.String(20), nullable=False, server_default="medium"),
        _ts("detected_at"),
        _ts("last_seen_at"),
        sa.Column("title", sa.String(200), nullable=False),
        sa.Column("explanation", sa.Text(), nullable=False),
        sa.Column("evidence_json", sa.JSON(), nullable=False, server_default="{}"),
        sa.Column("confidence_score", sa.Float(), nullable=True),
        sa.Column("status", sa.String(30), nullable=False, server_default="open"),
        sa.Column("deduplication_key", sa.String(255), nullable=False),
        sa.Column("acknowledged_by", sa.String(36), nullable=True),
        _ts("acknowledged_at", nullable=True),
        _ts("resolved_at", nullable=True),
        sa.Column("resolution_note", sa.Text(), nullable=True),
        sa.UniqueConstraint("farm_id", "deduplication_key", "detected_at", name="uq_feed_perf_alert_dedup"),
    )
    op.create_index("ix_feed_perf_alert_status", "feed_performance_alerts", ["farm_id", "status"])


def downgrade() -> None:
    op.drop_index("ix_feed_perf_alert_status", table_name="feed_performance_alerts")
    op.drop_table("feed_performance_alerts")
    op.drop_index("ix_supplier_feed_perf_farm", table_name="supplier_feed_performance")
    op.drop_table("supplier_feed_performance")
    op.drop_table("feed_batch_performance_scores")
    op.drop_index("ix_feed_perf_assessment_monitor", table_name="feed_performance_assessments")
    op.drop_table("feed_performance_assessments")
    op.drop_index("ix_feed_exposure_batch", table_name="feed_exposure_windows")
    op.drop_index("ix_feed_exposure_subject", table_name="feed_exposure_windows")
    op.drop_table("feed_exposure_windows")
    op.drop_index("ix_feed_perf_monitor_subject", table_name="feed_performance_monitors")
    op.drop_table("feed_performance_monitors")
