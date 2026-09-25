"""Generic feed, formula, batch and feeding-program architecture.

Revision ID: b4d7e2f9a1c3
Revises: 7c2e9a41d5b8
Create Date: 2026-09-25

Implements docs/GENERIC-FEED-ARCHITECTURE.md. Feed Product (what can be
fed), Feed Formula + Version (how a farm-made feed is meant to be made),
Feed Batch (what was actually mixed), Feeding Program + Version (what a
subject should get) and Feeding Event (what was actually fed) are five
tables, never one. Around them: lots on the existing inventory ledger,
nutrient profiles, usage policies, allocations, reorder policies,
forecasts and reconciliations.

Backfill: every existing feed inventory item becomes a feed product, and
the stock it holds becomes an `opening_balance` lot, so the lot ledger
and the item balance agree from the first day.
"""
from __future__ import annotations

import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import sqlalchemy as sa
from alembic import op

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "backend"))
from app.feeding.catalog import nutrient_rows  # noqa: E402

revision = "b4d7e2f9a1c3"
down_revision = "7c2e9a41d5b8"
branch_labels = None
depends_on = None

_NOT_FEED = {"medicine", "medication", "vet", "veterinary", "produce"}


def _id() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _slug(name: str) -> str:
    return re.sub(r"[^A-Z0-9]+", "-", name.upper()).strip("-")[:50] or "FEED"


def upgrade() -> None:
    op.create_table(
        "feed_products",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("code", sa.String(60), nullable=False),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("name_ar", sa.String(200), nullable=True),
        sa.Column("source_type", sa.String(20), nullable=False, server_default="purchased"),
        sa.Column("is_ingredient", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("is_feedable", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("category", sa.String(40), nullable=True),
        sa.Column("unit", sa.String(20), nullable=False, server_default="kg"),
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("inventory_items.id"), nullable=False),
        sa.Column("default_unit_cost", sa.Float(), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("farm_id", "code", name="uq_feed_product_farm_code"),
    )
    op.create_table(
        "feed_formulas",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("code", sa.String(60), nullable=False),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        sa.Column("species_code", sa.String(30), sa.ForeignKey("species.code"), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("farm_id", "code", name="uq_feed_formula_farm_code"),
    )
    op.create_table(
        "feed_formula_versions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("formula_id", sa.String(36), sa.ForeignKey("feed_formulas.id"), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("status", sa.String(20), nullable=False, server_default="draft"),
        sa.Column("batch_size", sa.Float(), nullable=False, server_default="1000"),
        sa.Column("unit", sa.String(20), nullable=False, server_default="kg"),
        sa.Column("effective_from", sa.DateTime(timezone=True), nullable=True),
        sa.Column("effective_to", sa.DateTime(timezone=True), nullable=True),
        sa.Column("locked", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("formula_id", "version", name="uq_feed_formula_version"),
    )
    op.create_table(
        "feed_formula_components",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("version_id", sa.String(36), sa.ForeignKey("feed_formula_versions.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        sa.Column("target_quantity", sa.Float(), nullable=False),
        sa.Column("unit", sa.String(20), nullable=False, server_default="kg"),
        sa.Column("target_percentage", sa.Float(), nullable=True),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
    )
    op.create_table(
        "feed_batches",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        sa.Column("formula_version_id", sa.String(36), sa.ForeignKey("feed_formula_versions.id"), nullable=True),
        sa.Column("batch_code", sa.String(80), nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default="planned"),
        sa.Column("target_quantity", sa.Float(), nullable=True),
        sa.Column("actual_quantity", sa.Float(), nullable=True),
        sa.Column("unit", sa.String(20), nullable=False, server_default="kg"),
        sa.Column("planned_cost", sa.Float(), nullable=True),
        sa.Column("actual_cost", sa.Float(), nullable=True),
        sa.Column("unit_cost", sa.Float(), nullable=True),
        sa.Column("output_lot_id", sa.String(36), nullable=True),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("produced_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("mixed_by", sa.String(36), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("farm_id", "batch_code", name="uq_feed_batch_farm_code"),
    )
    op.create_table(
        "feed_lots",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        sa.Column("lot_code", sa.String(80), nullable=False),
        sa.Column("source_type", sa.String(20), nullable=False, server_default="purchased"),
        sa.Column("supplier_id", sa.String(36), sa.ForeignKey("suppliers.id"), nullable=True),
        sa.Column("supplier_label", sa.String(200), nullable=True),
        sa.Column("feed_batch_id", sa.String(36), sa.ForeignKey("feed_batches.id"), nullable=True),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expiry_date", sa.DateTime(timezone=True), nullable=True),
        sa.Column("ordered_quantity", sa.Float(), nullable=True),
        sa.Column("received_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("accepted_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("rejected_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("quantity_on_hand", sa.Float(), nullable=False, server_default="0"),
        sa.Column("unit", sa.String(20), nullable=False, server_default="kg"),
        sa.Column("unit_cost", sa.Float(), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("reference", sa.String(120), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("farm_id", "lot_code", name="uq_feed_lot_farm_code"),
    )
    op.create_table(
        "feed_batch_components",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("batch_id", sa.String(36), sa.ForeignKey("feed_batches.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        sa.Column("lot_id", sa.String(36), sa.ForeignKey("feed_lots.id"), nullable=True),
        sa.Column("target_quantity", sa.Float(), nullable=True),
        sa.Column("actual_quantity", sa.Float(), nullable=True),
        sa.Column("unit", sa.String(20), nullable=False, server_default="kg"),
        sa.Column("unit_cost", sa.Float(), nullable=True),
        sa.Column("cost", sa.Float(), nullable=True),
    )
    op.create_table(
        "feed_nutrients",
        sa.Column("code", sa.String(30), primary_key=True),
        sa.Column("name_en", sa.String(100), nullable=False),
        sa.Column("name_ar", sa.String(100), nullable=False),
        sa.Column("unit", sa.String(20), nullable=False),
        sa.Column("category", sa.String(30), nullable=False, server_default="other"),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="100"),
    )
    op.create_table(
        "feed_nutrient_profiles",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("subject_type", sa.String(30), nullable=False),
        sa.Column("subject_id", sa.String(36), nullable=False),
        sa.Column("basis", sa.String(20), nullable=False, server_default="as_fed"),
        sa.Column("source_type", sa.String(20), nullable=False, server_default="declared"),
        sa.Column("reference", sa.String(120), nullable=True),
        sa.Column("effective_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "feed_nutrient_values",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("profile_id", sa.String(36), sa.ForeignKey("feed_nutrient_profiles.id"), nullable=False),
        sa.Column("nutrient_code", sa.String(30), sa.ForeignKey("feed_nutrients.code"), nullable=False),
        sa.Column("value", sa.Float(), nullable=False),
        sa.Column("unit", sa.String(20), nullable=False),
    )
    op.create_table(
        "feeding_programs",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("code", sa.String(60), nullable=False),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("name_ar", sa.String(200), nullable=True),
        sa.Column("category", sa.String(60), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("farm_id", "code", name="uq_feeding_program_farm_code"),
    )
    op.create_table(
        "feeding_program_versions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("program_id", sa.String(36), sa.ForeignKey("feeding_programs.id"), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("status", sa.String(20), nullable=False, server_default="draft"),
        sa.Column("feedings_per_day", sa.Integer(), nullable=False, server_default="2"),
        sa.Column("effective_from", sa.DateTime(timezone=True), nullable=True),
        sa.Column("effective_to", sa.DateTime(timezone=True), nullable=True),
        sa.Column("locked", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("program_id", "version", name="uq_feeding_program_version"),
    )
    op.create_table(
        "feeding_program_components",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("version_id", sa.String(36), sa.ForeignKey("feeding_program_versions.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        sa.Column("quantity_per_head", sa.Float(), nullable=False),
        sa.Column("unit", sa.String(20), nullable=False, server_default="kg"),
        sa.Column("frequency", sa.String(20), nullable=False, server_default="per_day"),
        sa.Column("timing", sa.String(20), nullable=True),
        sa.Column("notes", sa.String(300), nullable=True),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
    )
    op.create_table(
        "feeding_program_rules",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("version_id", sa.String(36), sa.ForeignKey("feeding_program_versions.id"), nullable=False),
        sa.Column("species_code", sa.String(30), sa.ForeignKey("species.code"), nullable=True),
        sa.Column("sex", sa.String(1), nullable=True),
        sa.Column("life_stage", sa.String(30), nullable=True),
        sa.Column("management_profile", sa.String(30), nullable=True),
        sa.Column("reproductive_state", sa.String(20), nullable=True),
        sa.Column("lactation_state", sa.String(20), nullable=True),
        sa.Column("production_metric", sa.String(40), nullable=True),
        sa.Column("production_min", sa.Float(), nullable=True),
        sa.Column("production_max", sa.Float(), nullable=True),
        sa.Column("weight_min", sa.Float(), nullable=True),
        sa.Column("weight_max", sa.Float(), nullable=True),
        sa.Column("age_min_days", sa.Integer(), nullable=True),
        sa.Column("age_max_days", sa.Integer(), nullable=True),
        sa.Column("priority", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("notes", sa.String(300), nullable=True),
    )
    op.create_table(
        "feeding_assignments",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("subject_type", sa.String(10), nullable=False),
        sa.Column("subject_id", sa.String(36), nullable=False),
        sa.Column("program_version_id", sa.String(36), sa.ForeignKey("feeding_program_versions.id"), nullable=True),
        sa.Column("assignment_type", sa.String(20), nullable=False, server_default="explicit"),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=True),
        sa.Column("quantity_per_head", sa.Float(), nullable=True),
        sa.Column("unit", sa.String(20), nullable=True),
        sa.Column("reason", sa.String(300), nullable=True),
        sa.Column("valid_from", sa.DateTime(timezone=True), nullable=False),
        sa.Column("valid_to", sa.DateTime(timezone=True), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_feeding_assignments_subject", "feeding_assignments", ["subject_type", "subject_id"])
    op.create_table(
        "feeding_events",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("subject_type", sa.String(10), nullable=False),
        sa.Column("subject_id", sa.String(36), nullable=False),
        sa.Column("program_version_id", sa.String(36), sa.ForeignKey("feeding_program_versions.id"), nullable=True),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("event_type", sa.String(20), nullable=False, server_default="offered"),
        sa.Column("head_count", sa.Integer(), nullable=True),
        sa.Column("recorded_by", sa.String(36), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="recorded"),
        sa.Column("reversal_of_id", sa.String(36), nullable=True),
        sa.Column("total_cost", sa.Float(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_feeding_events_subject", "feeding_events", ["subject_type", "subject_id", "occurred_at"])
    op.create_table(
        "feeding_event_components",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("event_id", sa.String(36), sa.ForeignKey("feeding_events.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        sa.Column("lot_id", sa.String(36), sa.ForeignKey("feed_lots.id"), nullable=True),
        sa.Column("batch_id", sa.String(36), sa.ForeignKey("feed_batches.id"), nullable=True),
        sa.Column("quantity_offered", sa.Float(), nullable=False),
        sa.Column("quantity_consumed", sa.Float(), nullable=True),
        sa.Column("unit", sa.String(20), nullable=False, server_default="kg"),
        sa.Column("unit_cost", sa.Float(), nullable=True),
        sa.Column("cost", sa.Float(), nullable=True),
    )
    op.create_table(
        "feed_usage_policies",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=True),
        sa.Column("lot_id", sa.String(36), sa.ForeignKey("feed_lots.id"), nullable=True),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("requires_approved_formula", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("cross_species_transfer_allowed", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("effective_from", sa.DateTime(timezone=True), nullable=True),
        sa.Column("effective_to", sa.DateTime(timezone=True), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "feed_usage_policy_rules",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("policy_id", sa.String(36), sa.ForeignKey("feed_usage_policies.id"), nullable=False),
        sa.Column("effect", sa.String(10), nullable=False),
        sa.Column("species_code", sa.String(30), sa.ForeignKey("species.code"), nullable=True),
        sa.Column("management_profile", sa.String(30), nullable=True),
        sa.Column("life_stage", sa.String(30), nullable=True),
        sa.Column("reproductive_state", sa.String(20), nullable=True),
        sa.Column("max_inclusion_pct", sa.Float(), nullable=True),
        sa.Column("min_age_days", sa.Integer(), nullable=True),
        sa.Column("max_age_days", sa.Integer(), nullable=True),
        sa.Column("reason", sa.String(300), nullable=True),
    )
    op.create_table(
        "feed_allocations",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        sa.Column("lot_id", sa.String(36), sa.ForeignKey("feed_lots.id"), nullable=True),
        sa.Column("species_code", sa.String(30), sa.ForeignKey("species.code"), nullable=True),
        sa.Column("subject_type", sa.String(10), nullable=True),
        sa.Column("subject_id", sa.String(36), nullable=True),
        sa.Column("feeding_program_id", sa.String(36), sa.ForeignKey("feeding_programs.id"), nullable=True),
        sa.Column("location_label", sa.String(200), nullable=True),
        sa.Column("cost_centre", sa.String(100), nullable=True),
        sa.Column("purpose", sa.String(300), nullable=True),
        sa.Column("allocated_quantity", sa.Float(), nullable=False),
        sa.Column("consumed_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("unit", sa.String(20), nullable=False, server_default="kg"),
        sa.Column("transferable", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("released_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_table(
        "feed_reorder_policies",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        sa.Column("location_label", sa.String(200), nullable=True),
        sa.Column("minimum_stock", sa.Float(), nullable=True),
        sa.Column("reorder_point", sa.Float(), nullable=True),
        sa.Column("safety_stock", sa.Float(), nullable=True),
        sa.Column("preferred_reorder_quantity", sa.Float(), nullable=True),
        sa.Column("maximum_stock", sa.Float(), nullable=True),
        sa.Column("lead_time_days", sa.Integer(), nullable=True),
        sa.Column("cover_margin_days", sa.Integer(), nullable=False, server_default="3"),
        sa.Column("variance_threshold_pct", sa.Float(), nullable=False, server_default="5"),
        sa.Column("unit", sa.String(20), nullable=False, server_default="kg"),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.UniqueConstraint("feed_product_id", "location_label", name="uq_feed_reorder_product_location"),
    )
    op.create_table(
        "feed_demand_forecasts",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        sa.Column("forecast_from", sa.DateTime(timezone=True), nullable=False),
        sa.Column("forecast_to", sa.DateTime(timezone=True), nullable=False),
        sa.Column("daily_demand", sa.Float(), nullable=False, server_default="0"),
        sa.Column("forecast_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("available_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("days_of_cover", sa.Float(), nullable=True),
        sa.Column("projected_stockout_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("suggested_reorder_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("unit", sa.String(20), nullable=False, server_default="kg"),
        sa.Column("generated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("basis_json", sa.JSON(), nullable=True),
    )
    op.create_table(
        "feed_reconciliations",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        sa.Column("lot_id", sa.String(36), sa.ForeignKey("feed_lots.id"), nullable=True),
        sa.Column("period_from", sa.DateTime(timezone=True), nullable=False),
        sa.Column("period_to", sa.DateTime(timezone=True), nullable=False),
        sa.Column("opening_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("received_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("issued_to_batches", sa.Float(), nullable=False, server_default="0"),
        sa.Column("issued_to_feeding", sa.Float(), nullable=False, server_default="0"),
        sa.Column("other_issued_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("waste_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("returned_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("adjustment_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("expected_closing_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("counted_closing_quantity", sa.Float(), nullable=True),
        sa.Column("variance_quantity", sa.Float(), nullable=True),
        sa.Column("variance_pct", sa.Float(), nullable=True),
        sa.Column("unit", sa.String(20), nullable=False, server_default="kg"),
        sa.Column("status", sa.String(20), nullable=False, server_default="open"),
        sa.Column("explanation", sa.Text(), nullable=True),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("closed_at", sa.DateTime(timezone=True), nullable=True),
    )

    # The ledger names its lot from now on.
    with op.batch_alter_table("inventory_transactions") as batch:
        batch.add_column(sa.Column("lot_id", sa.String(36), nullable=True))
        batch.create_foreign_key("fk_inventory_transactions_lot", "feed_lots", ["lot_id"], ["id"])

    op.bulk_insert(
        sa.table(
            "feed_nutrients",
            sa.column("code", sa.String), sa.column("name_en", sa.String), sa.column("name_ar", sa.String),
            sa.column("unit", sa.String), sa.column("category", sa.String), sa.column("sort_order", sa.Integer),
        ),
        nutrient_rows(),
    )
    _backfill()


def _backfill() -> None:
    """Every feed inventory item becomes a product; the stock on hand
    becomes its opening-balance lot."""
    conn = op.get_bind()
    items = conn.execute(sa.text(
        "SELECT id, farm_id, name, category, unit, current_qty, supplier_id, supplier_label, unit_cost, last_purchase FROM inventory_items"
    )).mappings().all()
    now = _now()
    codes: dict[tuple[str, str], int] = {}
    for item in items:
        if (item["category"] or "").strip().lower() in _NOT_FEED:
            continue
        base = _slug(item["name"])
        n = codes.get((item["farm_id"], base), 0)
        codes[(item["farm_id"], base)] = n + 1
        code = base if n == 0 else f"{base}-{n + 1}"
        product_id = _id()
        conn.execute(sa.text(
            "INSERT INTO feed_products (id, farm_id, code, name, source_type, is_ingredient, is_feedable, category, unit, inventory_item_id, "
            "default_unit_cost, status, created_at) VALUES (:id, :farm_id, :code, :name, 'purchased', :ing, :feedable, :category, :unit, :item_id, "
            ":cost, 'active', :now)"
        ), {"id": product_id, "farm_id": item["farm_id"], "code": code, "name": item["name"], "ing": True, "feedable": True,
            "category": (item["category"] or "").lower() or None, "unit": (item["unit"] or "kg").lower(), "item_id": item["id"],
            "cost": item["unit_cost"], "now": now})
        qty = item["current_qty"] or 0
        if qty > 0:
            conn.execute(sa.text(
                "INSERT INTO feed_lots (id, farm_id, feed_product_id, lot_code, source_type, supplier_id, supplier_label, received_at, "
                "received_quantity, accepted_quantity, rejected_quantity, quantity_on_hand, unit, unit_cost, status, notes, created_at) VALUES "
                "(:id, :farm_id, :product_id, :lot_code, 'opening_balance', :supplier_id, :supplier_label, :received_at, :qty, :qty, 0, :qty, "
                ":unit, :cost, 'active', 'Opening balance carried over from the inventory item.', :now)"
            ), {"id": _id(), "farm_id": item["farm_id"], "product_id": product_id, "lot_code": f"{code}-OPENING",
                "supplier_id": item["supplier_id"], "supplier_label": item["supplier_label"], "received_at": item["last_purchase"] or now,
                "qty": qty, "unit": (item["unit"] or "kg").lower(), "cost": item["unit_cost"], "now": now})


def downgrade() -> None:
    with op.batch_alter_table("inventory_transactions") as batch:
        batch.drop_constraint("fk_inventory_transactions_lot", type_="foreignkey")
        batch.drop_column("lot_id")
    for table in (
        "feed_reconciliations", "feed_demand_forecasts", "feed_reorder_policies", "feed_allocations", "feed_usage_policy_rules",
        "feed_usage_policies", "feeding_event_components", "feeding_events", "feeding_assignments", "feeding_program_rules",
        "feeding_program_components", "feeding_program_versions", "feeding_programs", "feed_nutrient_values", "feed_nutrient_profiles",
        "feed_nutrients", "feed_batch_components", "feed_lots", "feed_batches", "feed_formula_components", "feed_formula_versions",
        "feed_formulas", "feed_products",
    ):
        op.drop_table(table)
