"""Milk sales and the milk tank.

Revision ID: e6a8c0d2f4b7
Revises: d5f7b9c1e3a6
Create Date: 2026-11-23

New tables
- milk_sales: milk sold from the tank — litres, price per litre, amount,
  buyer, paid / pending, cancelled with a reason; each sale also writes the
  farm's revenue record (`sales`, product_type "milk") and a cancelled sale
  is reversed by a second, negative one.
- milk_tank_adjustments: milk that left the tank outside a sale (spoiled,
  fed to calves, home use) and tank counts, signed litres.

The tank itself is never stored: stored milk records − sales + adjustments.
No data change. Downgrade drops both tables.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "e6a8c0d2f4b7"
down_revision = "d5f7b9c1e3a6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "milk_sales",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("sold_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("liters", sa.Float(), nullable=False),
        sa.Column("price_per_liter", sa.Float(), nullable=False),
        sa.Column("amount", sa.Float(), nullable=False),
        sa.Column("currency", sa.String(10), nullable=False),
        sa.Column("customer_id", sa.String(36), sa.ForeignKey("customers.id"), nullable=True),
        sa.Column("buyer_name", sa.String(200), nullable=True),
        sa.Column("payment_status", sa.String(20), nullable=False),
        sa.Column("paid_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("reference", sa.String(120), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("cancel_reason", sa.Text(), nullable=True),
        sa.Column("cancelled_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("sale_id", sa.String(36), sa.ForeignKey("sales.id"), nullable=True),
        sa.Column("reversal_sale_id", sa.String(36), nullable=True),
        sa.Column("recorded_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_milk_sales_farm_sold", "milk_sales", ["farm_id", "sold_at"])
    op.create_table(
        "milk_tank_adjustments",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("liters", sa.Float(), nullable=False),
        sa.Column("reason", sa.String(20), nullable=False),
        sa.Column("counted_level", sa.Float(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("recorded_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_milk_tank_adjustments_farm", "milk_tank_adjustments", ["farm_id", "occurred_at"])


def downgrade() -> None:
    op.drop_index("ix_milk_tank_adjustments_farm", table_name="milk_tank_adjustments")
    op.drop_table("milk_tank_adjustments")
    op.drop_index("ix_milk_sales_farm_sold", table_name="milk_sales")
    op.drop_table("milk_sales")
