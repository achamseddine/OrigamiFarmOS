"""Medicine & farm pharmacy management (database/MEDICINE-PHARMACY-SCHEMA.md).

Revision ID: e3a5b7c9d1f2
Revises: d2f4a6c8e0b1
Create Date: 2026-10-09

Pharmaceutical semantics over inventory items (`medicine_products` with
ingredients and categories), the canonical lot for non-feed stock
(`inventory_lots`, extended by `medicine_lot_details`), the farm's
essential-stock policy, deduplicated pharmacy alerts and the
administration record bound to the exact lot. `inventory_transactions`
gains `inventory_lot_id` so every pharmacy movement names its lot.
Reference categories and common active ingredients are inserted.
"""
from __future__ import annotations

import uuid

import sqlalchemy as sa
from alembic import op

revision = "e3a5b7c9d1f2"
down_revision = "d2f4a6c8e0b1"
branch_labels = None
depends_on = None

CATEGORIES = (
    ("FEVER_SUPPORT", "Fever support", "دعم الحمّى"), ("PAIN_INFLAMMATION", "Pain & inflammation", "الألم والالتهاب"),
    ("COLIC_SUPPORT", "Colic support", "دعم المغص"), ("IV_FLUID", "IV fluids", "سوائل وريدية"), ("ELECTROLYTE", "Electrolytes", "إلكتروليتات"),
    ("ANTIBIOTIC", "Antibiotics", "مضادات حيوية"), ("ANTIPARASITIC", "Antiparasitics", "مضادات الطفيليات"), ("VACCINE", "Vaccines", "لقاحات"),
    ("WOUND_CARE", "Wound care", "العناية بالجروح"), ("OTHER", "Other", "أخرى"),
)
INGREDIENTS = (
    ("oxytetracycline", "Oxytetracycline"), ("flunixin_meglumine", "Flunixin meglumine"), ("sodium_chloride", "Sodium chloride"),
    ("ivermectin", "Ivermectin"), ("penicillin_g", "Penicillin G"), ("dextrose", "Dextrose"), ("calcium_borogluconate", "Calcium borogluconate"),
    ("meloxicam", "Meloxicam"), ("clostridial_toxoid", "Clostridial toxoid"), ("glucose_electrolyte", "Glucose / electrolyte"),
)


def _ts(name: str, nullable: bool = False) -> sa.Column:
    return sa.Column(name, sa.DateTime(timezone=True), nullable=nullable)


def upgrade() -> None:
    op.create_table(
        "medicine_categories",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("code", sa.String(80), nullable=False, unique=True),
        sa.Column("name", sa.String(150), nullable=False),
        sa.Column("name_ar", sa.String(150), nullable=True),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
    )
    op.create_table(
        "medicine_active_ingredients",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("code", sa.String(80), nullable=False, unique=True),
        sa.Column("name", sa.String(180), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
    )
    op.create_table(
        "medicine_products",
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("inventory_items.id"), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("generic_name", sa.String(200), nullable=True),
        sa.Column("brand_name", sa.String(200), nullable=True),
        sa.Column("dosage_form", sa.String(60), nullable=False, server_default="injectable"),
        sa.Column("strength_value", sa.Float(), nullable=True),
        sa.Column("strength_uom", sa.String(30), nullable=True),
        sa.Column("strength_basis", sa.String(80), nullable=True),
        sa.Column("administration_routes", sa.JSON(), nullable=False, server_default="[]"),
        sa.Column("prescription_required", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("antimicrobial", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("controlled_medicine", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("cold_chain_required", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("storage_min_c", sa.Float(), nullable=True),
        sa.Column("storage_max_c", sa.Float(), nullable=True),
        sa.Column("opened_shelf_life_days", sa.Integer(), nullable=True),
        sa.Column("default_pack_size", sa.Float(), nullable=True),
        sa.Column("pack_uom", sa.String(30), nullable=True),
        sa.Column("manufacturer_name", sa.String(200), nullable=True),
        sa.Column("authorization_reference", sa.String(150), nullable=True),
        sa.Column("species_codes", sa.JSON(), nullable=False, server_default="[]"),
        sa.Column("withdrawal_rules_json", sa.JSON(), nullable=False, server_default="{}"),
        sa.Column("lot_tracking_exception", sa.Text(), nullable=True),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_by", sa.String(36), nullable=True),
        _ts("created_at"),
        _ts("updated_at"),
    )
    op.create_table(
        "medicine_product_ingredients",
        sa.Column("medicine_product_id", sa.String(36), sa.ForeignKey("medicine_products.inventory_item_id"), primary_key=True),
        sa.Column("active_ingredient_id", sa.String(36), sa.ForeignKey("medicine_active_ingredients.id"), primary_key=True),
        sa.Column("concentration_value", sa.Float(), nullable=True),
        sa.Column("concentration_uom", sa.String(30), nullable=True),
        sa.Column("concentration_basis", sa.String(80), nullable=True),
    )
    op.create_table(
        "medicine_product_categories",
        sa.Column("medicine_product_id", sa.String(36), sa.ForeignKey("medicine_products.inventory_item_id"), primary_key=True),
        sa.Column("category_id", sa.String(36), sa.ForeignKey("medicine_categories.id"), primary_key=True),
    )
    op.create_table(
        "inventory_lots",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("inventory_items.id"), nullable=False),
        sa.Column("lot_code", sa.String(120), nullable=False),
        sa.Column("source_type", sa.String(30), nullable=False, server_default="purchased"),
        sa.Column("supplier_id", sa.String(36), sa.ForeignKey("suppliers.id"), nullable=True),
        sa.Column("supplier_label", sa.String(200), nullable=True),
        sa.Column("location_id", sa.String(36), sa.ForeignKey("locations.id"), nullable=True),
        _ts("received_at"),
        _ts("expiry_date", nullable=True),
        sa.Column("received_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("accepted_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("rejected_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("quantity_on_hand", sa.Float(), nullable=False, server_default="0"),
        sa.Column("unit", sa.String(20), nullable=False, server_default="items"),
        sa.Column("unit_cost", sa.Float(), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("reference", sa.String(150), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_by", sa.String(36), nullable=True),
        _ts("created_at"),
        sa.UniqueConstraint("inventory_item_id", "lot_code", name="uq_inventory_lot_item_code"),
    )
    op.create_index("ix_inventory_lots_item", "inventory_lots", ["farm_id", "inventory_item_id"])
    op.create_table(
        "medicine_lot_details",
        sa.Column("inventory_lot_id", sa.String(36), sa.ForeignKey("inventory_lots.id"), primary_key=True),
        _ts("opened_at", nullable=True),
        _ts("use_by_after_opening", nullable=True),
        sa.Column("storage_status", sa.String(30), nullable=False, server_default="COMPLIANT"),
        sa.Column("cold_chain_exception", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("storage_note", sa.Text(), nullable=True),
        sa.Column("quarantine_reason", sa.Text(), nullable=True),
        _ts("recalled_at", nullable=True),
        sa.Column("recall_reference", sa.String(150), nullable=True),
    )
    op.create_table(
        "pharmacy_stock_policies",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("medicine_products.inventory_item_id"), nullable=False),
        sa.Column("location_id", sa.String(36), sa.ForeignKey("locations.id"), nullable=True),
        sa.Column("essential", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("minimum_stock_base", sa.Float(), nullable=True),
        sa.Column("target_stock_base", sa.Float(), nullable=True),
        sa.Column("critical_stock_base", sa.Float(), nullable=True),
        sa.Column("minimum_days_cover", sa.Float(), nullable=True),
        sa.Column("lead_time_days", sa.Float(), nullable=True),
        sa.Column("preferred_supplier_id", sa.String(36), sa.ForeignKey("suppliers.id"), nullable=True),
        sa.Column("alert_enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("expiry_warning_days", sa.Integer(), nullable=False, server_default="60"),
        sa.Column("auto_draft_requisition", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("version", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("updated_by", sa.String(36), nullable=True),
        _ts("updated_at"),
        sa.UniqueConstraint("farm_id", "inventory_item_id", "location_id", name="uq_pharmacy_policy_item_location"),
        sa.CheckConstraint("minimum_stock_base IS NULL OR minimum_stock_base >= 0", name="ck_pharmacy_policy_min"),
        sa.CheckConstraint("target_stock_base IS NULL OR target_stock_base >= 0", name="ck_pharmacy_policy_target"),
        sa.CheckConstraint("critical_stock_base IS NULL OR critical_stock_base >= 0", name="ck_pharmacy_policy_critical"),
    )
    op.create_table(
        "pharmacy_stock_alerts",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("medicine_products.inventory_item_id"), nullable=False),
        sa.Column("location_id", sa.String(36), sa.ForeignKey("locations.id"), nullable=True),
        sa.Column("alert_type", sa.String(50), nullable=False),
        sa.Column("severity", sa.String(20), nullable=False, server_default="medium"),
        _ts("detected_at"),
        _ts("last_seen_at"),
        sa.Column("eligible_available_base", sa.Float(), nullable=True),
        sa.Column("minimum_stock_base", sa.Float(), nullable=True),
        sa.Column("target_stock_base", sa.Float(), nullable=True),
        _ts("earliest_expiry_date", nullable=True),
        sa.Column("expiring_quantity", sa.Float(), nullable=True),
        sa.Column("recommended_reorder_base", sa.Float(), nullable=True),
        sa.Column("explanation", sa.Text(), nullable=False, server_default=""),
        sa.Column("status", sa.String(30), nullable=False, server_default="open"),
        sa.Column("acknowledged_by", sa.String(36), nullable=True),
        _ts("acknowledged_at", nullable=True),
        _ts("resolved_at", nullable=True),
        sa.Column("resolution_note", sa.Text(), nullable=True),
        sa.Column("deduplication_key", sa.String(255), nullable=False),
        sa.Column("requisition_task_id", sa.String(36), nullable=True),
        sa.UniqueConstraint("farm_id", "deduplication_key", "detected_at", name="uq_pharmacy_alert_dedup"),
    )
    op.create_index("ix_pharmacy_alerts_status", "pharmacy_stock_alerts", ["farm_id", "status"])
    op.create_table(
        "medication_administrations",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("subject_type", sa.String(10), nullable=False),
        sa.Column("subject_id", sa.String(36), nullable=False),
        sa.Column("treatment_id", sa.String(36), sa.ForeignKey("treatments.id"), nullable=True),
        sa.Column("protocol_run_step_id", sa.String(36), nullable=True),
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("medicine_products.inventory_item_id"), nullable=False),
        sa.Column("inventory_lot_id", sa.String(36), sa.ForeignKey("inventory_lots.id"), nullable=False),
        sa.Column("dose_quantity", sa.Float(), nullable=False),
        sa.Column("dose_unit", sa.String(20), nullable=False),
        sa.Column("route_code", sa.String(40), nullable=False),
        sa.Column("head_count", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("quantity_consumed", sa.Float(), nullable=False),
        sa.Column("unit", sa.String(20), nullable=False),
        _ts("administered_at"),
        sa.Column("administered_by", sa.String(36), nullable=False),
        sa.Column("inventory_transaction_id", sa.String(36), nullable=True),
        _ts("withdrawal_milk_until", nullable=True),
        _ts("withdrawal_meat_until", nullable=True),
        sa.Column("reason", sa.Text(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="recorded"),
        _ts("reversed_at", nullable=True),
        sa.Column("reversal_reason", sa.Text(), nullable=True),
        _ts("created_at"),
    )
    op.create_index("ix_medication_admin_subject", "medication_administrations", ["farm_id", "subject_type", "subject_id"])

    with op.batch_alter_table("inventory_transactions") as b:
        b.add_column(sa.Column("inventory_lot_id", sa.String(36), nullable=True))
        b.create_foreign_key("fk_inventory_tx_inventory_lot", "inventory_lots", ["inventory_lot_id"], ["id"])

    conn = op.get_bind()
    for code, name, name_ar in CATEGORIES:
        conn.execute(sa.text("INSERT INTO medicine_categories (id, code, name, name_ar, active) VALUES (:id, :code, :name, :name_ar, 1)"),
                     {"id": str(uuid.uuid4()), "code": code, "name": name, "name_ar": name_ar})
    for code, name in INGREDIENTS:
        conn.execute(sa.text("INSERT INTO medicine_active_ingredients (id, code, name, active) VALUES (:id, :code, :name, 1)"),
                     {"id": str(uuid.uuid4()), "code": code, "name": name})


def downgrade() -> None:
    with op.batch_alter_table("inventory_transactions") as b:
        b.drop_constraint("fk_inventory_tx_inventory_lot", type_="foreignkey")
        b.drop_column("inventory_lot_id")
    op.drop_index("ix_medication_admin_subject", table_name="medication_administrations")
    op.drop_table("medication_administrations")
    op.drop_index("ix_pharmacy_alerts_status", table_name="pharmacy_stock_alerts")
    op.drop_table("pharmacy_stock_alerts")
    op.drop_table("pharmacy_stock_policies")
    op.drop_table("medicine_lot_details")
    op.drop_index("ix_inventory_lots_item", table_name="inventory_lots")
    op.drop_table("inventory_lots")
    op.drop_table("medicine_product_categories")
    op.drop_table("medicine_product_ingredients")
    op.drop_table("medicine_products")
    op.drop_table("medicine_active_ingredients")
    op.drop_table("medicine_categories")
