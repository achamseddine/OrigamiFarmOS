"""Platform masters, health cases, procurement requisitions, reservations
and the columns the PR #10 specifications still asked for.

Revision ID: a7c9e1f3b5d7
Revises: f4b6c8d0e2a3
Create Date: 2026-10-18

New tables
- units_of_measure (FOUNDATION uom): the unit table every pharmacy /
  emergency / requisition unit column now references, seeded with the
  built-in catalogue plus any unit code already in use on this database.
- farm_assets (ASSET-MAINTENANCE §2): the mixer a numbered mix names.
- notification_routes, scheduled_job_runs (notification rules, §12 cycles).
- health_cases, diagnoses, treatment_plans, animal_health_conditions,
  animal_weight_records (HEALTH-VETERINARY-SCHEMA).
- purchase_requisitions, purchase_requisition_lines, procurement_approvals
  (PROCUREMENT-SCHEMA §5–§6).
- inventory_reservations (INVENTORY-SCHEMA §5).

Column additions / references
- animals: lactation_started_at, dried_off_at.
- inventory_transactions: location_id, correlation_id (transfers).
- observations / treatments / emergency tables: health_case_id references;
  treatments.medicine_product_id, treatment_plan_id.
- feed_batches: operator_id (backfilled from mixed_by), mixer_asset_id
  becomes a farm_assets reference (free text becomes an asset row),
  intended_management_profile becomes a management_profiles reference.
- feeding_events.assignment_id.
- inventory_lots: supplier_lot_code, manufactured_at, source_reference_*,
  currency, quality_status; unit → units_of_measure.
- medicine products / ingredients / administrations / protocol medication
  steps: unit columns → units_of_measure (values lower-cased first).
- medication_administrations: reservation_id, location_id.
- pharmacy_stock_alerts.requisition_id.
- emergency assessments / runs: offline execution columns.
- notifications.source_id widened to 100 (a routed copy is "<source id>|<user id>").

Verified by backend/tests/test_migrations.py: upgrade, parity with the ORM,
demo seed, downgrade to base and upgrade again, on SQLite and PostgreSQL 16.
"""
from __future__ import annotations

import re
import uuid
from datetime import datetime, timezone

import sqlalchemy as sa
from alembic import op

from app.platform.units import migration_rows

revision = "a7c9e1f3b5d7"
down_revision = "f4b6c8d0e2a3"
branch_labels = None
depends_on = None


def _ts(name: str, nullable: bool = False) -> sa.Column:
    return sa.Column(name, sa.DateTime(timezone=True), nullable=nullable)


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:60] or "asset"


# Unit columns that become references: (table, column, nullable)
UNIT_COLUMNS = (
    ("medicine_products", "strength_uom", True),
    ("medicine_products", "pack_uom", True),
    ("medicine_product_ingredients", "concentration_uom", True),
    ("inventory_lots", "unit", False),
    ("medication_administrations", "dose_unit", False),
    ("medication_administrations", "unit", False),
    ("protocol_medication_steps", "dose_unit", False),
    ("protocol_medication_steps", "weight_unit", True),
)


def upgrade() -> None:
    conn = op.get_bind()

    # ------------------------------------------------------------ platform
    op.create_table(
        "units_of_measure",
        sa.Column("code", sa.String(30), primary_key=True),
        sa.Column("name_en", sa.String(80), nullable=False),
        sa.Column("name_ar", sa.String(80), nullable=True),
        sa.Column("dimension", sa.String(30), nullable=False, server_default="other"),
        sa.Column("base_unit_code", sa.String(30), sa.ForeignKey("units_of_measure.code"), nullable=True),
        sa.Column("factor_to_base", sa.Float(), nullable=False, server_default="1"),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="100"),
    )
    units = sa.table(
        "units_of_measure", sa.column("code", sa.String), sa.column("name_en", sa.String), sa.column("name_ar", sa.String), sa.column("dimension", sa.String),
        sa.column("base_unit_code", sa.String), sa.column("factor_to_base", sa.Float), sa.column("active", sa.Boolean), sa.column("sort_order", sa.Integer),
    )
    rows = migration_rows()
    # Base units first so the self-reference is satisfied on PostgreSQL.
    op.bulk_insert(units, [r for r in rows if r["base_unit_code"] is None])
    op.bulk_insert(units, [r for r in rows if r["base_unit_code"] is not None])
    known = {r["code"] for r in rows}
    # Any unit code already in use becomes a row (dimension other) so the
    # references below hold on every database.
    for table, column, _nullable in UNIT_COLUMNS:
        conn.execute(sa.text(f"UPDATE {table} SET {column} = lower(trim({column})) WHERE {column} IS NOT NULL"))
        for (code,) in conn.execute(sa.text(f"SELECT DISTINCT {column} FROM {table} WHERE {column} IS NOT NULL")).fetchall():
            if code and code not in known:
                conn.execute(sa.text("INSERT INTO units_of_measure (code, name_en, dimension, factor_to_base, active, sort_order) VALUES (:c, :n, 'other', 1, :active, 900)"),
                             {"c": code, "n": code, "active": True})
                known.add(code)

    op.create_table(
        "farm_assets",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("code", sa.String(80), nullable=False),
        sa.Column("name", sa.String(180), nullable=False),
        sa.Column("asset_type", sa.String(60), nullable=False, server_default="other"),
        sa.Column("manufacturer", sa.String(120), nullable=True),
        sa.Column("model", sa.String(120), nullable=True),
        sa.Column("serial_number", sa.String(150), nullable=True),
        _ts("acquisition_date", nullable=True),
        sa.Column("acquisition_cost", sa.Float(), nullable=True),
        sa.Column("currency", sa.String(3), nullable=True),
        sa.Column("current_location_id", sa.String(36), sa.ForeignKey("locations.id"), nullable=True),
        sa.Column("status", sa.String(30), nullable=False, server_default="active"),
        sa.Column("parent_asset_id", sa.String(36), sa.ForeignKey("farm_assets.id"), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        _ts("created_at"),
        _ts("updated_at"),
        sa.UniqueConstraint("farm_id", "code", name="uq_farm_asset_code"),
    )
    op.create_table(
        "notification_routes",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("route_code", sa.String(60), nullable=False),
        sa.Column("role", sa.String(30), nullable=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id"), nullable=True),
        sa.Column("channel", sa.String(20), nullable=False, server_default="in_app"),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_by", sa.String(36), nullable=True),
        _ts("created_at"),
        sa.CheckConstraint("role IS NOT NULL OR user_id IS NOT NULL", name="ck_notification_route_target"),
    )
    op.create_index("ix_notification_routes_farm_route", "notification_routes", ["farm_id", "route_code"])
    op.create_table(
        "scheduled_job_runs",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=True),
        sa.Column("job_code", sa.String(60), nullable=False),
        sa.Column("trigger", sa.String(20), nullable=False, server_default="scheduler"),
        _ts("started_at"),
        _ts("finished_at", nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="running"),
        sa.Column("summary_json", sa.JSON(), nullable=False, server_default="{}"),
        sa.Column("error", sa.Text(), nullable=True),
    )
    op.create_index("ix_scheduled_job_runs_job", "scheduled_job_runs", ["farm_id", "job_code", "started_at"])

    # -------------------------------------------------------------- health
    op.create_table(
        "health_cases",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("animal_id", sa.String(36), sa.ForeignKey("animals.id"), nullable=True),
        sa.Column("animal_group_id", sa.String(36), sa.ForeignKey("flocks.id"), nullable=True),
        sa.Column("case_code", sa.String(100), nullable=False),
        _ts("opened_at"),
        _ts("closed_at", nullable=True),
        sa.Column("status", sa.String(30), nullable=False, server_default="open"),
        sa.Column("severity_code", sa.String(30), nullable=True),
        sa.Column("primary_problem_code", sa.String(100), nullable=True),
        sa.Column("responsible_user_id", sa.String(36), nullable=True),
        sa.Column("source_type", sa.String(40), nullable=True),
        sa.Column("source_id", sa.String(36), nullable=True),
        sa.Column("outcome", sa.Text(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_by", sa.String(36), nullable=True),
        _ts("created_at"),
        sa.UniqueConstraint("farm_id", "case_code", name="uq_health_case_code"),
        sa.CheckConstraint("(animal_id IS NOT NULL AND animal_group_id IS NULL) OR (animal_id IS NULL AND animal_group_id IS NOT NULL)", name="ck_health_case_one_subject"),
    )
    op.create_index("ix_health_cases_subject", "health_cases", ["farm_id", "animal_id", "animal_group_id"])
    op.create_table(
        "diagnoses",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("health_case_id", sa.String(36), sa.ForeignKey("health_cases.id"), nullable=False),
        sa.Column("diagnosis_code", sa.String(120), nullable=False),
        sa.Column("diagnosis_text", sa.String(250), nullable=True),
        sa.Column("certainty_code", sa.String(30), nullable=False, server_default="suspected"),
        _ts("diagnosed_at"),
        sa.Column("diagnosed_by", sa.String(36), nullable=True),
        sa.Column("status", sa.String(30), nullable=False, server_default="active"),
        sa.Column("supersedes_diagnosis_id", sa.String(36), sa.ForeignKey("diagnoses.id"), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
    )
    op.create_table(
        "treatment_plans",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("health_case_id", sa.String(36), sa.ForeignKey("health_cases.id"), nullable=False),
        sa.Column("status", sa.String(30), nullable=False, server_default="prescribed"),
        _ts("prescribed_at"),
        sa.Column("prescribed_by", sa.String(36), nullable=True),
        sa.Column("instructions", sa.Text(), nullable=True),
        sa.Column("source_type", sa.String(40), nullable=True),
        sa.Column("source_id", sa.String(36), nullable=True),
        _ts("completed_at", nullable=True),
        _ts("created_at"),
    )
    op.create_table(
        "animal_health_conditions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("animal_id", sa.String(36), sa.ForeignKey("animals.id"), nullable=False),
        sa.Column("condition_type", sa.String(40), nullable=False),
        sa.Column("code", sa.String(120), nullable=False),
        sa.Column("label", sa.String(200), nullable=False),
        sa.Column("severity", sa.String(30), nullable=True),
        _ts("recorded_at"),
        sa.Column("recorded_by", sa.String(36), nullable=True),
        _ts("ended_at", nullable=True),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("notes", sa.Text(), nullable=True),
    )
    op.create_index("ix_animal_health_conditions_animal", "animal_health_conditions", ["animal_id", "active"])
    op.create_table(
        "animal_weight_records",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("animal_id", sa.String(36), sa.ForeignKey("animals.id"), nullable=False),
        sa.Column("weight_kg", sa.Float(), nullable=False),
        _ts("measured_at"),
        sa.Column("method", sa.String(30), nullable=False, server_default="scale"),
        sa.Column("recorded_by", sa.String(36), nullable=True),
        sa.Column("source_type", sa.String(40), nullable=True),
        sa.Column("source_id", sa.String(36), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        _ts("created_at"),
        sa.CheckConstraint("weight_kg > 0", name="ck_animal_weight_positive"),
    )
    op.create_index("ix_animal_weight_records_animal", "animal_weight_records", ["animal_id", "measured_at"])
    # Every animal with a weight on record gets a dated history row, so the
    # protocol rule "weight no older than N days" has something to read.
    stamp = datetime.now(timezone.utc)
    for animal_id, farm_id, weight, updated_at, created_at in conn.execute(
            sa.text("SELECT id, farm_id, weight_kg, updated_at, created_at FROM animals WHERE weight_kg IS NOT NULL AND weight_kg > 0")).fetchall():
        measured = updated_at or created_at or stamp
        conn.execute(sa.text(
            "INSERT INTO animal_weight_records (id, farm_id, animal_id, weight_kg, measured_at, method, source_type, created_at) "
            "VALUES (:id, :farm, :animal, :w, :m, 'legacy', 'migration', :c)"),
            {"id": str(uuid.uuid4()), "farm": farm_id, "animal": animal_id, "w": float(weight), "m": measured, "c": stamp})

    # --------------------------------------------------------- procurement
    op.create_table(
        "purchase_requisitions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("requisition_no", sa.String(80), nullable=False),
        sa.Column("requested_by", sa.String(36), sa.ForeignKey("users.id"), nullable=False),
        _ts("requested_at"),
        _ts("needed_by", nullable=True),
        sa.Column("purpose_code", sa.String(60), nullable=True),
        sa.Column("status", sa.String(30), nullable=False, server_default="draft"),
        sa.Column("justification", sa.Text(), nullable=True),
        sa.Column("source_type", sa.String(60), nullable=True),
        sa.Column("source_reference_id", sa.String(36), nullable=True),
        sa.Column("total_estimated_amount", sa.Float(), nullable=True),
        sa.Column("currency", sa.String(3), nullable=True),
        _ts("submitted_at", nullable=True),
        _ts("decided_at", nullable=True),
        sa.Column("decided_by", sa.String(36), nullable=True),
        sa.Column("task_id", sa.String(36), nullable=True),
        _ts("created_at"),
        sa.UniqueConstraint("farm_id", "requisition_no", name="uq_purchase_requisition_no"),
    )
    op.create_index("ix_purchase_requisitions_status", "purchase_requisitions", ["farm_id", "status"])
    op.create_table(
        "purchase_requisition_lines",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("requisition_id", sa.String(36), sa.ForeignKey("purchase_requisitions.id"), nullable=False),
        sa.Column("line_no", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("inventory_items.id"), nullable=False),
        sa.Column("requested_quantity", sa.Float(), nullable=False),
        sa.Column("uom_code", sa.String(30), sa.ForeignKey("units_of_measure.code"), nullable=False),
        sa.Column("estimated_unit_price", sa.Float(), nullable=True),
        sa.Column("preferred_supplier_id", sa.String(36), sa.ForeignKey("suppliers.id"), nullable=True),
        sa.Column("specification", sa.Text(), nullable=True),
        sa.Column("status", sa.String(30), nullable=False, server_default="open"),
        sa.Column("source_recommendation_id", sa.String(36), nullable=True),
        sa.UniqueConstraint("requisition_id", "line_no", name="uq_purchase_requisition_line_no"),
        sa.CheckConstraint("requested_quantity > 0", name="ck_purchase_requisition_line_qty"),
    )
    op.create_table(
        "procurement_approvals",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("document_type", sa.String(40), nullable=False),
        sa.Column("document_id", sa.String(36), nullable=False),
        sa.Column("approval_stage", sa.String(60), nullable=False, server_default="manager"),
        sa.Column("decision", sa.String(30), nullable=False),
        sa.Column("decided_by", sa.String(36), sa.ForeignKey("users.id"), nullable=False),
        _ts("decided_at"),
        sa.Column("authority_snapshot", sa.JSON(), nullable=False, server_default="{}"),
        sa.Column("comments", sa.Text(), nullable=True),
    )

    # ------------------------------------------------------------ inventory
    op.create_table(
        "inventory_reservations",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("inventory_items.id"), nullable=False),
        sa.Column("inventory_lot_id", sa.String(36), sa.ForeignKey("inventory_lots.id"), nullable=True),
        sa.Column("location_id", sa.String(36), sa.ForeignKey("locations.id"), nullable=True),
        sa.Column("quantity", sa.Float(), nullable=False),
        sa.Column("consumed_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("unit", sa.String(30), sa.ForeignKey("units_of_measure.code"), nullable=False),
        sa.Column("purpose_type", sa.String(80), nullable=False),
        sa.Column("purpose_id", sa.String(36), nullable=True),
        sa.Column("purpose_label", sa.String(300), nullable=True),
        _ts("valid_from"),
        _ts("valid_to", nullable=True),
        sa.Column("status", sa.String(30), nullable=False, server_default="active"),
        _ts("created_at"),
        sa.Column("created_by", sa.String(36), nullable=True),
        _ts("released_at", nullable=True),
        sa.Column("release_reason", sa.String(300), nullable=True),
        sa.CheckConstraint("quantity > 0", name="ck_inventory_reservation_qty"),
    )
    op.create_index("ix_inventory_reservations_item", "inventory_reservations", ["farm_id", "inventory_item_id", "status"])

    # ------------------------------------------------- column additions
    with op.batch_alter_table("animals") as b:
        b.add_column(sa.Column("lactation_started_at", sa.DateTime(timezone=True), nullable=True))
        b.add_column(sa.Column("dried_off_at", sa.DateTime(timezone=True), nullable=True))
    with op.batch_alter_table("inventory_transactions") as b:
        b.add_column(sa.Column("location_id", sa.String(36), nullable=True))
        b.add_column(sa.Column("correlation_id", sa.String(36), nullable=True))
        b.create_foreign_key("fk_inventory_tx_location", "locations", ["location_id"], ["id"])
    with op.batch_alter_table("observations") as b:
        b.add_column(sa.Column("health_case_id", sa.String(36), nullable=True))
        b.create_foreign_key("fk_observation_health_case", "health_cases", ["health_case_id"], ["id"])
    with op.batch_alter_table("treatments") as b:
        b.add_column(sa.Column("medicine_product_id", sa.String(36), nullable=True))
        b.add_column(sa.Column("health_case_id", sa.String(36), nullable=True))
        b.add_column(sa.Column("treatment_plan_id", sa.String(36), nullable=True))
        b.create_foreign_key("fk_treatment_medicine_product", "medicine_products", ["medicine_product_id"], ["inventory_item_id"])
        b.create_foreign_key("fk_treatment_health_case", "health_cases", ["health_case_id"], ["id"])
        b.create_foreign_key("fk_treatment_plan", "treatment_plans", ["treatment_plan_id"], ["id"])

    # Feed batches: the free-text mixer becomes an asset row per farm, the
    # operator is backfilled from the account that opened the batch, and
    # an intended profile that is not a configured profile is cleared.
    assets: dict[tuple[str, str], str] = {}
    for batch_id, farm_id, mixer in conn.execute(sa.text("SELECT id, farm_id, mixer_asset_id FROM feed_batches WHERE mixer_asset_id IS NOT NULL AND trim(mixer_asset_id) <> ''")).fetchall():
        key = (farm_id, mixer.strip())
        if key not in assets:
            asset_id = str(uuid.uuid4())
            conn.execute(sa.text(
                "INSERT INTO farm_assets (id, farm_id, code, name, asset_type, status, created_at, updated_at) VALUES (:id, :farm, :code, :name, 'mixer', 'active', :c, :c)"),
                {"id": asset_id, "farm": farm_id, "code": _slug(mixer), "name": mixer.strip(), "c": stamp})
            assets[key] = asset_id
        conn.execute(sa.text("UPDATE feed_batches SET mixer_asset_id = :a WHERE id = :b"), {"a": assets[key], "b": batch_id})
    conn.execute(sa.text("UPDATE feed_batches SET intended_management_profile = NULL WHERE intended_management_profile IS NOT NULL "
                         "AND intended_management_profile NOT IN (SELECT code FROM management_profiles)"))
    with op.batch_alter_table("feed_batches") as b:
        b.add_column(sa.Column("operator_id", sa.String(36), nullable=True))
        b.alter_column("mixer_asset_id", type_=sa.String(36), existing_type=sa.String(80), existing_nullable=True)
        b.create_foreign_key("fk_feed_batch_operator", "users", ["operator_id"], ["id"])
        b.create_foreign_key("fk_feed_batch_mixer_asset", "farm_assets", ["mixer_asset_id"], ["id"])
        b.create_foreign_key("fk_feed_batch_intended_profile", "management_profiles", ["intended_management_profile"], ["code"])
    conn.execute(sa.text("UPDATE feed_batches SET operator_id = mixed_by WHERE operator_id IS NULL AND mixed_by IS NOT NULL"))
    with op.batch_alter_table("feeding_events") as b:
        b.add_column(sa.Column("assignment_id", sa.String(36), nullable=True))
        b.create_foreign_key("fk_feeding_event_assignment", "feeding_assignments", ["assignment_id"], ["id"])
    # A notification routed to a person carries "<source id>|<user id>" as
    # its source, which is wider than one id.
    with op.batch_alter_table("notifications") as b:
        b.alter_column("source_id", type_=sa.String(100), existing_type=sa.String(36), existing_nullable=True)

    with op.batch_alter_table("medicine_products") as b:
        b.create_foreign_key("fk_medicine_product_strength_uom", "units_of_measure", ["strength_uom"], ["code"])
        b.create_foreign_key("fk_medicine_product_pack_uom", "units_of_measure", ["pack_uom"], ["code"])
    with op.batch_alter_table("medicine_product_ingredients") as b:
        b.create_foreign_key("fk_medicine_ingredient_uom", "units_of_measure", ["concentration_uom"], ["code"])
    with op.batch_alter_table("inventory_lots") as b:
        b.add_column(sa.Column("supplier_lot_code", sa.String(120), nullable=True))
        b.add_column(sa.Column("manufactured_at", sa.DateTime(timezone=True), nullable=True))
        b.add_column(sa.Column("source_reference_type", sa.String(80), nullable=True))
        b.add_column(sa.Column("source_reference_id", sa.String(36), nullable=True))
        b.add_column(sa.Column("currency", sa.String(3), nullable=True))
        b.add_column(sa.Column("quality_status", sa.String(30), nullable=False, server_default="RELEASED"))
        b.alter_column("unit", type_=sa.String(30), existing_type=sa.String(20), existing_nullable=False, existing_server_default="items")
        b.create_foreign_key("fk_inventory_lot_unit", "units_of_measure", ["unit"], ["code"])
    conn.execute(sa.text("UPDATE inventory_lots SET quality_status = CASE status WHEN 'quarantined' THEN 'QUARANTINED' WHEN 'blocked' THEN 'BLOCKED' "
                         "WHEN 'recalled' THEN 'RECALLED' WHEN 'expired' THEN 'EXPIRED' ELSE 'RELEASED' END"))
    with op.batch_alter_table("medication_administrations") as b:
        b.add_column(sa.Column("reservation_id", sa.String(36), nullable=True))
        b.add_column(sa.Column("location_id", sa.String(36), nullable=True))
        b.alter_column("dose_unit", type_=sa.String(30), existing_type=sa.String(20), existing_nullable=False)
        b.alter_column("unit", type_=sa.String(30), existing_type=sa.String(20), existing_nullable=False)
        b.create_foreign_key("fk_medication_admin_reservation", "inventory_reservations", ["reservation_id"], ["id"])
        b.create_foreign_key("fk_medication_admin_location", "locations", ["location_id"], ["id"])
        b.create_foreign_key("fk_medication_admin_dose_unit", "units_of_measure", ["dose_unit"], ["code"])
        b.create_foreign_key("fk_medication_admin_unit", "units_of_measure", ["unit"], ["code"])
    with op.batch_alter_table("pharmacy_stock_alerts") as b:
        b.add_column(sa.Column("requisition_id", sa.String(36), nullable=True))
        b.create_foreign_key("fk_pharmacy_alert_requisition", "purchase_requisitions", ["requisition_id"], ["id"])
    with op.batch_alter_table("protocol_medication_steps") as b:
        b.alter_column("dose_unit", type_=sa.String(30), existing_type=sa.String(20), existing_nullable=False)
        b.alter_column("weight_unit", type_=sa.String(30), existing_type=sa.String(20), existing_nullable=True)
        b.create_foreign_key("fk_protocol_medication_dose_unit", "units_of_measure", ["dose_unit"], ["code"])
        b.create_foreign_key("fk_protocol_medication_weight_unit", "units_of_measure", ["weight_unit"], ["code"])
    with op.batch_alter_table("emergency_assessments") as b:
        b.add_column(sa.Column("offline_operation_id", sa.String(80), nullable=True))
        b.add_column(sa.Column("device_id", sa.String(100), nullable=True))
        b.add_column(sa.Column("package_signature", sa.String(64), nullable=True))
        b.add_column(sa.Column("offline_discrepancies", sa.JSON(), nullable=False, server_default="[]"))
        b.create_unique_constraint("uq_emergency_assessment_offline_op", ["offline_operation_id"])
        b.create_foreign_key("fk_emergency_assessment_health_case", "health_cases", ["health_case_id"], ["id"])
    with op.batch_alter_table("emergency_protocol_runs") as b:
        b.add_column(sa.Column("offline", sa.Boolean(), nullable=False, server_default=sa.false()))
        b.add_column(sa.Column("offline_operation_id", sa.String(80), nullable=True))
        b.add_column(sa.Column("package_signature", sa.String(64), nullable=True))
        b.add_column(sa.Column("offline_discrepancies", sa.JSON(), nullable=False, server_default="[]"))
        b.create_unique_constraint("uq_emergency_run_offline_op", ["offline_operation_id"])
        b.create_foreign_key("fk_emergency_run_health_case", "health_cases", ["health_case_id"], ["id"])


def downgrade() -> None:
    conn = op.get_bind()
    # Routed notification copies do not fit the old width; the next scan
    # regenerates the farm-wide ones.
    conn.execute(sa.text("DELETE FROM notifications WHERE source_id IS NOT NULL AND length(source_id) > 36"))
    with op.batch_alter_table("notifications") as b:
        b.alter_column("source_id", type_=sa.String(36), existing_type=sa.String(100), existing_nullable=True)
    with op.batch_alter_table("emergency_protocol_runs") as b:
        b.drop_constraint("fk_emergency_run_health_case", type_="foreignkey")
        b.drop_constraint("uq_emergency_run_offline_op", type_="unique")
        b.drop_column("offline_discrepancies")
        b.drop_column("package_signature")
        b.drop_column("offline_operation_id")
        b.drop_column("offline")
    with op.batch_alter_table("emergency_assessments") as b:
        b.drop_constraint("fk_emergency_assessment_health_case", type_="foreignkey")
        b.drop_constraint("uq_emergency_assessment_offline_op", type_="unique")
        b.drop_column("offline_discrepancies")
        b.drop_column("package_signature")
        b.drop_column("device_id")
        b.drop_column("offline_operation_id")
    with op.batch_alter_table("protocol_medication_steps") as b:
        b.drop_constraint("fk_protocol_medication_weight_unit", type_="foreignkey")
        b.drop_constraint("fk_protocol_medication_dose_unit", type_="foreignkey")
        b.alter_column("weight_unit", type_=sa.String(20), existing_type=sa.String(30), existing_nullable=True)
        b.alter_column("dose_unit", type_=sa.String(20), existing_type=sa.String(30), existing_nullable=False)
    with op.batch_alter_table("pharmacy_stock_alerts") as b:
        b.drop_constraint("fk_pharmacy_alert_requisition", type_="foreignkey")
        b.drop_column("requisition_id")
    with op.batch_alter_table("medication_administrations") as b:
        b.drop_constraint("fk_medication_admin_unit", type_="foreignkey")
        b.drop_constraint("fk_medication_admin_dose_unit", type_="foreignkey")
        b.drop_constraint("fk_medication_admin_location", type_="foreignkey")
        b.drop_constraint("fk_medication_admin_reservation", type_="foreignkey")
        b.alter_column("unit", type_=sa.String(20), existing_type=sa.String(30), existing_nullable=False)
        b.alter_column("dose_unit", type_=sa.String(20), existing_type=sa.String(30), existing_nullable=False)
        b.drop_column("location_id")
        b.drop_column("reservation_id")
    with op.batch_alter_table("inventory_lots") as b:
        b.drop_constraint("fk_inventory_lot_unit", type_="foreignkey")
        b.alter_column("unit", type_=sa.String(20), existing_type=sa.String(30), existing_nullable=False, existing_server_default="items")
        b.drop_column("quality_status")
        b.drop_column("currency")
        b.drop_column("source_reference_id")
        b.drop_column("source_reference_type")
        b.drop_column("manufactured_at")
        b.drop_column("supplier_lot_code")
    with op.batch_alter_table("medicine_product_ingredients") as b:
        b.drop_constraint("fk_medicine_ingredient_uom", type_="foreignkey")
    with op.batch_alter_table("medicine_products") as b:
        b.drop_constraint("fk_medicine_product_pack_uom", type_="foreignkey")
        b.drop_constraint("fk_medicine_product_strength_uom", type_="foreignkey")
    with op.batch_alter_table("feeding_events") as b:
        b.drop_constraint("fk_feeding_event_assignment", type_="foreignkey")
        b.drop_column("assignment_id")
    conn = op.get_bind()
    # The mixer reference goes back to the asset's name as free text: the
    # names are read while the key still points at the asset, the key and
    # the width are released, and only then are the names written (a
    # name is not an asset id, and PostgreSQL checks that).
    names = conn.execute(sa.text("SELECT fb.id, fa.name FROM feed_batches fb JOIN farm_assets fa ON fa.id = fb.mixer_asset_id")).fetchall()
    with op.batch_alter_table("feed_batches") as b:
        b.drop_constraint("fk_feed_batch_intended_profile", type_="foreignkey")
        b.drop_constraint("fk_feed_batch_mixer_asset", type_="foreignkey")
        b.drop_constraint("fk_feed_batch_operator", type_="foreignkey")
        b.alter_column("mixer_asset_id", type_=sa.String(80), existing_type=sa.String(36), existing_nullable=True)
        b.drop_column("operator_id")
    for batch_id, name in names:
        conn.execute(sa.text("UPDATE feed_batches SET mixer_asset_id = :n WHERE id = :b"), {"n": name, "b": batch_id})
    with op.batch_alter_table("treatments") as b:
        b.drop_constraint("fk_treatment_plan", type_="foreignkey")
        b.drop_constraint("fk_treatment_health_case", type_="foreignkey")
        b.drop_constraint("fk_treatment_medicine_product", type_="foreignkey")
        b.drop_column("treatment_plan_id")
        b.drop_column("health_case_id")
        b.drop_column("medicine_product_id")
    with op.batch_alter_table("observations") as b:
        b.drop_constraint("fk_observation_health_case", type_="foreignkey")
        b.drop_column("health_case_id")
    with op.batch_alter_table("inventory_transactions") as b:
        b.drop_constraint("fk_inventory_tx_location", type_="foreignkey")
        b.drop_column("correlation_id")
        b.drop_column("location_id")
    with op.batch_alter_table("animals") as b:
        b.drop_column("dried_off_at")
        b.drop_column("lactation_started_at")
    op.drop_index("ix_inventory_reservations_item", table_name="inventory_reservations")
    op.drop_table("inventory_reservations")
    op.drop_table("procurement_approvals")
    op.drop_table("purchase_requisition_lines")
    op.drop_index("ix_purchase_requisitions_status", table_name="purchase_requisitions")
    op.drop_table("purchase_requisitions")
    op.drop_index("ix_animal_weight_records_animal", table_name="animal_weight_records")
    op.drop_table("animal_weight_records")
    op.drop_index("ix_animal_health_conditions_animal", table_name="animal_health_conditions")
    op.drop_table("animal_health_conditions")
    op.drop_table("treatment_plans")
    op.drop_table("diagnoses")
    op.drop_index("ix_health_cases_subject", table_name="health_cases")
    op.drop_table("health_cases")
    op.drop_index("ix_scheduled_job_runs_job", table_name="scheduled_job_runs")
    op.drop_table("scheduled_job_runs")
    op.drop_index("ix_notification_routes_farm_route", table_name="notification_routes")
    op.drop_table("notification_routes")
    op.drop_table("farm_assets")
    op.drop_table("units_of_measure")
