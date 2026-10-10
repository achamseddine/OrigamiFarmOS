"""Clinical decision support & emergency protocol engine
(database/CLINICAL-DECISION-SUPPORT-EMERGENCY-PROTOCOLS.md).

Revision ID: f4b6c8d0e2a3
Revises: e3a5b7c9d1f2
Create Date: 2026-10-09

Protocols and their veterinarian-approved versions (approval provenance
on the version, written once), trigger rules, eligibility rules, steps
and the medication parameters a step may carry, and the runtime
records: assessments with candidate matches, protocol runs and their
steps bound to the administrations they produced.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "f4b6c8d0e2a3"
down_revision = "e3a5b7c9d1f2"
branch_labels = None
depends_on = None


def _ts(name: str, nullable: bool = False) -> sa.Column:
    return sa.Column(name, sa.DateTime(timezone=True), nullable=nullable)


def upgrade() -> None:
    op.create_table(
        "emergency_protocols",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("code", sa.String(100), nullable=False),
        sa.Column("title", sa.String(200), nullable=False),
        sa.Column("condition_family_code", sa.String(100), nullable=False),
        sa.Column("species_code", sa.String(30), sa.ForeignKey("species.code"), nullable=True),
        sa.Column("subject_scope", sa.String(10), nullable=False, server_default="animal"),
        sa.Column("status", sa.String(30), nullable=False, server_default="draft"),
        sa.Column("current_version_id", sa.String(36), nullable=True),
        _ts("created_at"),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.UniqueConstraint("farm_id", "code", name="uq_emergency_protocol_farm_code"),
    )
    op.create_table(
        "emergency_protocol_versions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("emergency_protocol_id", sa.String(36), sa.ForeignKey("emergency_protocols.id"), nullable=False),
        sa.Column("version_no", sa.Integer(), nullable=False),
        _ts("effective_from", nullable=True),
        _ts("effective_to", nullable=True),
        sa.Column("protocol_text", sa.Text(), nullable=True),
        sa.Column("minimum_match_confidence", sa.Float(), nullable=False, server_default="0.6"),
        sa.Column("requires_manager_notification", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("requires_vet_notification", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("requires_pre_action_confirmation", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("offline_eligible", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("reassessment_minutes", sa.Integer(), nullable=True),
        sa.Column("status", sa.String(30), nullable=False, server_default="draft"),
        sa.Column("approved_by_veterinarian_id", sa.String(36), nullable=True),
        _ts("approved_at", nullable=True),
        sa.Column("approval_reference", sa.String(150), nullable=True),
        sa.Column("withdrawn_reason", sa.Text(), nullable=True),
        _ts("created_at"),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.UniqueConstraint("emergency_protocol_id", "version_no", name="uq_emergency_protocol_version_no"),
    )
    op.create_table(
        "protocol_trigger_rules",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("protocol_version_id", sa.String(36), sa.ForeignKey("emergency_protocol_versions.id"), nullable=False),
        sa.Column("observation_code", sa.String(100), nullable=False),
        sa.Column("operator", sa.String(20), nullable=False, server_default="present"),
        sa.Column("threshold_numeric", sa.Float(), nullable=True),
        sa.Column("threshold_unit", sa.String(20), nullable=True),
        sa.Column("expected_value_code", sa.String(100), nullable=True),
        sa.Column("required", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("weight", sa.Float(), nullable=False, server_default="1"),
        sa.Column("danger_sign", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("label", sa.String(200), nullable=True),
    )
    op.create_table(
        "protocol_eligibility_rules",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("protocol_version_id", sa.String(36), sa.ForeignKey("emergency_protocol_versions.id"), nullable=False),
        sa.Column("rule_type", sa.String(60), nullable=False),
        sa.Column("operator", sa.String(20), nullable=False, server_default="=="),
        sa.Column("rule_payload", sa.JSON(), nullable=False, server_default="{}"),
        sa.Column("failure_action", sa.String(30), nullable=False, server_default="WARN"),
        sa.Column("message", sa.String(300), nullable=True),
    )
    op.create_table(
        "protocol_steps",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("protocol_version_id", sa.String(36), sa.ForeignKey("emergency_protocol_versions.id"), nullable=False),
        sa.Column("step_no", sa.Integer(), nullable=False),
        sa.Column("step_type", sa.String(40), nullable=False),
        sa.Column("title", sa.String(200), nullable=False),
        sa.Column("instructions", sa.Text(), nullable=False),
        sa.Column("required", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("requires_confirmation", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("timing_offset_minutes", sa.Integer(), nullable=True),
        sa.UniqueConstraint("protocol_version_id", "step_no", name="uq_protocol_step_no"),
    )
    op.create_table(
        "protocol_medication_steps",
        sa.Column("protocol_step_id", sa.String(36), sa.ForeignKey("protocol_steps.id"), primary_key=True),
        sa.Column("medicine_product_id", sa.String(36), sa.ForeignKey("medicine_products.inventory_item_id"), nullable=False),
        sa.Column("route_code", sa.String(40), nullable=False),
        sa.Column("dose_rule_type", sa.String(40), nullable=False),
        sa.Column("fixed_dose_quantity", sa.Float(), nullable=True),
        sa.Column("dose_per_weight_quantity", sa.Float(), nullable=True),
        sa.Column("dose_unit", sa.String(20), nullable=False),
        sa.Column("weight_unit", sa.String(20), nullable=True),
        sa.Column("minimum_dose_quantity", sa.Float(), nullable=True),
        sa.Column("maximum_dose_quantity", sa.Float(), nullable=True),
        sa.Column("repeat_interval_minutes", sa.Integer(), nullable=True),
        sa.Column("maximum_administrations", sa.Integer(), nullable=True),
        sa.Column("weight_max_age_days", sa.Integer(), nullable=True),
        sa.Column("withdrawal_rule_payload", sa.JSON(), nullable=False, server_default="{}"),
        sa.CheckConstraint(
            "(dose_rule_type = 'FIXED' AND fixed_dose_quantity IS NOT NULL) OR (dose_rule_type = 'PER_WEIGHT' AND dose_per_weight_quantity IS NOT NULL AND weight_unit IS NOT NULL)",
            name="ck_protocol_medication_dose_rule",
        ),
    )
    op.create_table(
        "emergency_assessments",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("animal_id", sa.String(36), sa.ForeignKey("animals.id"), nullable=True),
        sa.Column("animal_group_id", sa.String(36), sa.ForeignKey("flocks.id"), nullable=True),
        sa.Column("health_case_id", sa.String(36), nullable=True),
        sa.Column("parent_run_id", sa.String(36), nullable=True),
        _ts("started_at"),
        sa.Column("source", sa.String(30), nullable=False, server_default="worker"),
        sa.Column("observed_signs", sa.JSON(), nullable=False, server_default="[]"),
        sa.Column("animal_facts", sa.JSON(), nullable=False, server_default="{}"),
        sa.Column("triage_level", sa.String(30), nullable=False, server_default="LOW"),
        sa.Column("ai_model_reference", sa.String(150), nullable=True),
        sa.Column("ai_confidence", sa.Float(), nullable=True),
        sa.Column("status", sa.String(30), nullable=False, server_default="open"),
        sa.Column("escalation_reasons", sa.JSON(), nullable=False, server_default="[]"),
        sa.Column("explanation", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_by", sa.String(36), nullable=True),
        _ts("closed_at", nullable=True),
        sa.CheckConstraint("(animal_id IS NOT NULL AND animal_group_id IS NULL) OR (animal_id IS NULL AND animal_group_id IS NOT NULL)", name="ck_emergency_assessment_one_subject"),
    )
    op.create_index("ix_emergency_assessments_status", "emergency_assessments", ["farm_id", "status"])
    op.create_table(
        "protocol_matches",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("emergency_assessment_id", sa.String(36), sa.ForeignKey("emergency_assessments.id"), nullable=False),
        sa.Column("protocol_version_id", sa.String(36), sa.ForeignKey("emergency_protocol_versions.id"), nullable=False),
        sa.Column("match_score", sa.Float(), nullable=True),
        sa.Column("match_explanation", sa.JSON(), nullable=False, server_default="{}"),
        sa.Column("eligibility_result", sa.String(30), nullable=False, server_default="ELIGIBLE"),
        sa.Column("blocking_reasons", sa.JSON(), nullable=False, server_default="[]"),
        sa.Column("selected", sa.Boolean(), nullable=False, server_default=sa.false()),
        _ts("evaluated_at"),
    )
    op.create_table(
        "emergency_protocol_runs",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("emergency_assessment_id", sa.String(36), sa.ForeignKey("emergency_assessments.id"), nullable=False),
        sa.Column("protocol_version_id", sa.String(36), sa.ForeignKey("emergency_protocol_versions.id"), nullable=False),
        sa.Column("animal_id", sa.String(36), sa.ForeignKey("animals.id"), nullable=True),
        sa.Column("animal_group_id", sa.String(36), sa.ForeignKey("flocks.id"), nullable=True),
        sa.Column("health_case_id", sa.String(36), nullable=True),
        _ts("started_at"),
        sa.Column("started_by", sa.String(36), nullable=True),
        sa.Column("status", sa.String(30), nullable=False, server_default="in_progress"),
        _ts("manager_notified_at", nullable=True),
        _ts("veterinarian_notified_at", nullable=True),
        _ts("next_reassessment_at", nullable=True),
        _ts("escalated_at", nullable=True),
        sa.Column("escalation_reason", sa.Text(), nullable=True),
        _ts("completed_at", nullable=True),
        sa.Column("outcome", sa.Text(), nullable=True),
        sa.Column("device_id", sa.String(100), nullable=True),
        sa.CheckConstraint("(animal_id IS NOT NULL AND animal_group_id IS NULL) OR (animal_id IS NULL AND animal_group_id IS NOT NULL)", name="ck_emergency_run_one_subject"),
    )
    op.create_index("ix_emergency_runs_status", "emergency_protocol_runs", ["farm_id", "status"])
    op.create_table(
        "protocol_run_steps",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("protocol_run_id", sa.String(36), sa.ForeignKey("emergency_protocol_runs.id"), nullable=False),
        sa.Column("protocol_step_id", sa.String(36), sa.ForeignKey("protocol_steps.id"), nullable=False),
        sa.Column("sequence", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("status", sa.String(30), nullable=False, server_default="pending"),
        _ts("due_at", nullable=True),
        _ts("presented_at", nullable=True),
        _ts("confirmed_at", nullable=True),
        sa.Column("confirmed_by", sa.String(36), nullable=True),
        _ts("completed_at", nullable=True),
        sa.Column("medication_administration_id", sa.String(36), sa.ForeignKey("medication_administrations.id"), nullable=True),
        sa.Column("result_payload", sa.JSON(), nullable=False, server_default="{}"),
        sa.Column("skip_reason", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_table("protocol_run_steps")
    op.drop_index("ix_emergency_runs_status", table_name="emergency_protocol_runs")
    op.drop_table("emergency_protocol_runs")
    op.drop_table("protocol_matches")
    op.drop_index("ix_emergency_assessments_status", table_name="emergency_assessments")
    op.drop_table("emergency_assessments")
    op.drop_table("protocol_medication_steps")
    op.drop_table("protocol_steps")
    op.drop_table("protocol_eligibility_rules")
    op.drop_table("protocol_trigger_rules")
    op.drop_table("emergency_protocol_versions")
    op.drop_table("emergency_protocols")
