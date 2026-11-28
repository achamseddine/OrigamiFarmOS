"""Crop cycles: the work, the inputs, the water, the harvest and the sales of
each (master prompt Package 7; CROPS-SCHEMA §4, §5, §6, §8).

Revision ID: d9b1c3e5f7a2
Revises: c7e9a1b3d5f8
Create Date: 2026-11-26

Schema
- fields.unit_type: the growing unit (open_field | greenhouse | tunnel | orchard).
- crop_plantings: the crop cycle's farm-wide cycle_code (unique per farm),
  production_purpose and closed_at.
- field_operations / field_operation_inputs: the work done on a cycle,
  its labour hours and cost, and each input taken out of stock by its own
  inventory movement.
- irrigation_events: the water given, its source and the pumping cost.
- harvest_records.crop_planting_id, loss_reason: what each harvest came
  from, and why some was lost.
- sales.crop_planting_id: the cycle whose produce a sale was.

Data: nothing is rewritten. Existing plantings keep no cycle code until one
is given; existing harvests and sales are not linked to a cycle.
Downgrade drops what this adds.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "d9b1c3e5f7a2"
down_revision = "c7e9a1b3d5f8"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("fields") as batch:
        batch.add_column(sa.Column("unit_type", sa.String(30), nullable=True))
    with op.batch_alter_table("crop_plantings") as batch:
        batch.add_column(sa.Column("cycle_code", sa.String(100), nullable=True))
        batch.add_column(sa.Column("production_purpose", sa.String(30), nullable=True))
        batch.add_column(sa.Column("closed_at", sa.DateTime(timezone=True), nullable=True))
        batch.create_unique_constraint("uq_crop_plantings_cycle_code", ["farm_id", "cycle_code"])
    op.create_table(
        "field_operations",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("crop_planting_id", sa.String(36), sa.ForeignKey("crop_plantings.id"), nullable=False),
        sa.Column("field_id", sa.String(36), sa.ForeignKey("fields.id"), nullable=False),
        sa.Column("operation_type", sa.String(30), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("labour_hours", sa.Float(), nullable=True),
        sa.Column("labour_cost", sa.Float(), nullable=True),
        sa.Column("performed_by", sa.String(36), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_field_operations_cycle", "field_operations", ["crop_planting_id", "completed_at"])
    op.create_table(
        "field_operation_inputs",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("field_operation_id", sa.String(36), sa.ForeignKey("field_operations.id"), nullable=False),
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("inventory_items.id"), nullable=False),
        sa.Column("quantity", sa.Float(), nullable=False),
        sa.Column("unit", sa.String(20), nullable=False),
        sa.Column("unit_cost", sa.Float(), nullable=True),
        sa.Column("cost", sa.Float(), nullable=True),
        sa.Column("inventory_transaction_id", sa.String(36), sa.ForeignKey("inventory_transactions.id"), nullable=True),
    )
    op.create_index("ix_field_operation_inputs_field_operation_id", "field_operation_inputs", ["field_operation_id"])
    op.create_table(
        "irrigation_events",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("crop_planting_id", sa.String(36), sa.ForeignKey("crop_plantings.id"), nullable=True),
        sa.Column("field_id", sa.String(36), sa.ForeignKey("fields.id"), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("water_quantity", sa.Float(), nullable=True),
        sa.Column("unit", sa.String(10), nullable=True),
        sa.Column("source_code", sa.String(60), nullable=True),
        sa.Column("energy_cost", sa.Float(), nullable=True),
        sa.Column("recorded_by", sa.String(36), nullable=True),
        sa.Column("recorded_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_irrigation_events_cycle", "irrigation_events", ["crop_planting_id", "started_at"])
    with op.batch_alter_table("harvest_records") as batch:
        batch.add_column(sa.Column("crop_planting_id", sa.String(36), sa.ForeignKey("crop_plantings.id", name="fk_harvest_records_crop_planting"), nullable=True))
        batch.add_column(sa.Column("loss_reason", sa.String(120), nullable=True))
        batch.create_index("ix_harvest_records_crop_planting_id", ["crop_planting_id"])
    with op.batch_alter_table("sales") as batch:
        batch.add_column(sa.Column("crop_planting_id", sa.String(36), sa.ForeignKey("crop_plantings.id", name="fk_sales_crop_planting"), nullable=True))
        batch.create_index("ix_sales_crop_planting_id", ["crop_planting_id"])


def downgrade() -> None:
    with op.batch_alter_table("sales") as batch:
        batch.drop_index("ix_sales_crop_planting_id")
        batch.drop_constraint("fk_sales_crop_planting", type_="foreignkey")
        batch.drop_column("crop_planting_id")
    with op.batch_alter_table("harvest_records") as batch:
        batch.drop_index("ix_harvest_records_crop_planting_id")
        batch.drop_constraint("fk_harvest_records_crop_planting", type_="foreignkey")
        batch.drop_column("loss_reason")
        batch.drop_column("crop_planting_id")
    op.drop_index("ix_irrigation_events_cycle", table_name="irrigation_events")
    op.drop_table("irrigation_events")
    op.drop_index("ix_field_operation_inputs_field_operation_id", table_name="field_operation_inputs")
    op.drop_table("field_operation_inputs")
    op.drop_index("ix_field_operations_cycle", table_name="field_operations")
    op.drop_table("field_operations")
    with op.batch_alter_table("crop_plantings") as batch:
        batch.drop_constraint("uq_crop_plantings_cycle_code", type_="unique")
        batch.drop_column("closed_at")
        batch.drop_column("production_purpose")
        batch.drop_column("cycle_code")
    with op.batch_alter_table("fields") as batch:
        batch.drop_column("unit_type")
