"""Nutrient requirements and formula assessments (v0.8.18, master prompt Package 11).

Revision ID: b7d9f1a3c5e8
Revises: a3c5e7f9b1d2
Create Date: 2026-11-27

Schema
- nutrition_requirement_sets: what a kind of animal at a stage needs on the
  ration's dry matter — species, stage, reference weight, milk, expected
  dry-matter intake — with its source and a version (code + version unique
  per farm); a revision is a new version, the old one retired.
- nutrition_requirement_values: per nutrient a minimum and/or a maximum, in
  the nutrient catalog's unit.
- nutrition_assessments: a formula version (and an optional premix on top)
  in a ration against one version of a set, stored as computed — inputs and
  result as JSON — and never recomputed.
- feed_nutrients: the catalog gains PENDF (physically effective NDF, %).

Data — nothing existing is changed: formulas, versions, batches and
nutrient profiles are read, never written. Downgrade drops the three
tables and the PENDF row when no profile uses it.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "b7d9f1a3c5e8"
down_revision = "a3c5e7f9b1d2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    bind = op.get_bind()
    if not bind.execute(sa.text("SELECT 1 FROM feed_nutrients WHERE code = 'PENDF'")).first():
        op.bulk_insert(
            sa.table("feed_nutrients", sa.column("code", sa.String), sa.column("name_en", sa.String), sa.column("name_ar", sa.String),
                     sa.column("unit", sa.String), sa.column("category", sa.String), sa.column("sort_order", sa.Integer)),
            [{"code": "PENDF", "name_en": "Physically effective NDF", "name_ar": "الألياف الفعّالة peNDF", "unit": "%", "category": "fibre", "sort_order": 43}],
        )
    op.create_table(
        "nutrition_requirement_sets",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("code", sa.String(60), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("species_code", sa.String(30), sa.ForeignKey("species.code"), nullable=False),
        sa.Column("production_stage", sa.String(60), nullable=True),
        sa.Column("reference_body_weight_kg", sa.Float(), nullable=True),
        sa.Column("milk_yield_kg", sa.Float(), nullable=True),
        sa.Column("expected_dmi_kg", sa.Float(), nullable=True),
        sa.Column("basis", sa.String(20), nullable=False),
        sa.Column("source_type", sa.String(30), nullable=False),
        sa.Column("source_reference", sa.String(400), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("retired_at", sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint("farm_id", "code", "version", name="uq_nutrition_requirement_sets_version"),
        sa.CheckConstraint("version >= 1", name="ck_nutrition_requirement_sets_version"),
    )
    op.create_index("ix_nutrition_requirement_sets_farm_id", "nutrition_requirement_sets", ["farm_id"])
    op.create_table(
        "nutrition_requirement_values",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("requirement_set_id", sa.String(36), sa.ForeignKey("nutrition_requirement_sets.id"), nullable=False),
        sa.Column("nutrient_code", sa.String(30), sa.ForeignKey("feed_nutrients.code"), nullable=False),
        sa.Column("min_value", sa.Float(), nullable=True),
        sa.Column("max_value", sa.Float(), nullable=True),
        sa.Column("unit", sa.String(20), nullable=False),
        sa.UniqueConstraint("requirement_set_id", "nutrient_code", name="uq_nutrition_requirement_values_nutrient"),
        sa.CheckConstraint("min_value IS NOT NULL OR max_value IS NOT NULL", name="ck_nutrition_requirement_values_bound"),
        sa.CheckConstraint("min_value IS NULL OR max_value IS NULL OR min_value <= max_value", name="ck_nutrition_requirement_values_order"),
    )
    op.create_index("ix_nutrition_requirement_values_requirement_set_id", "nutrition_requirement_values", ["requirement_set_id"])
    op.create_table(
        "nutrition_assessments",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("formula_version_id", sa.String(36), sa.ForeignKey("feed_formula_versions.id"), nullable=False),
        sa.Column("requirement_set_id", sa.String(36), sa.ForeignKey("nutrition_requirement_sets.id"), nullable=False),
        sa.Column("status", sa.String(30), nullable=False),
        sa.Column("premix_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=True),
        sa.Column("premix_quantity_kg", sa.Float(), nullable=True),
        sa.Column("inputs", sa.JSON(), nullable=False),
        sa.Column("result", sa.JSON(), nullable=False),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_nutrition_assessments_version", "nutrition_assessments", ["farm_id", "formula_version_id", "created_at"])


def downgrade() -> None:
    op.drop_index("ix_nutrition_assessments_version", table_name="nutrition_assessments")
    op.drop_table("nutrition_assessments")
    op.drop_index("ix_nutrition_requirement_values_requirement_set_id", table_name="nutrition_requirement_values")
    op.drop_table("nutrition_requirement_values")
    op.drop_index("ix_nutrition_requirement_sets_farm_id", table_name="nutrition_requirement_sets")
    op.drop_table("nutrition_requirement_sets")
    op.execute("DELETE FROM feed_nutrients WHERE code = 'PENDF' AND NOT EXISTS (SELECT 1 FROM feed_nutrient_values WHERE nutrient_code = 'PENDF')")
