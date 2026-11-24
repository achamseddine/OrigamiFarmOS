"""The farm's milking routine: handover after each milking, weekly payment.

Revision ID: a2c4e6f8b0d3
Revises: f7b9d1e3a5c8
Create Date: 2026-11-24

After each milking the calves get their milk and the milk collector takes
the rest; he pays once a week for all of it.

New columns (nullable or with a server default — existing rows keep their
meaning)
- farms: second_milking ('evening' | 'afternoon', default 'evening'),
  milk_collector_name, milk_collector_price, milk_collector_currency
  (default 'USD').
- milk_sales, milk_tank_adjustments: session, collection_day — the milking
  a handover belongs to.
- sales: payment_id — the payment that settled a sale.

New table
- customer_payments: money a customer paid for several sales at once (the
  collector's weekly payment), what was due, what was received (USD, with
  the LBP amount and rate when paid in LBP) and the difference.

Downgrade drops the table and the columns.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "a2c4e6f8b0d3"
down_revision = "f7b9d1e3a5c8"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("farms") as batch:
        batch.add_column(sa.Column("second_milking", sa.String(10), nullable=False, server_default="evening"))
        batch.add_column(sa.Column("milk_collector_name", sa.String(200), nullable=True))
        batch.add_column(sa.Column("milk_collector_price", sa.Float(), nullable=True))
        batch.add_column(sa.Column("milk_collector_currency", sa.String(10), nullable=False, server_default="USD"))
    for table in ("milk_sales", "milk_tank_adjustments"):
        with op.batch_alter_table(table) as batch:
            batch.add_column(sa.Column("session", sa.String(10), nullable=True))
            batch.add_column(sa.Column("collection_day", sa.Date(), nullable=True))
    with op.batch_alter_table("sales") as batch:
        batch.add_column(sa.Column("payment_id", sa.String(36), nullable=True))
    op.create_table(
        "customer_payments",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("customer_id", sa.String(36), sa.ForeignKey("customers.id"), nullable=True),
        sa.Column("buyer_name", sa.String(200), nullable=True),
        sa.Column("paid_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("sales_count", sa.Integer(), nullable=False),
        sa.Column("amount_due", sa.Float(), nullable=False),
        sa.Column("amount_received", sa.Float(), nullable=False),
        sa.Column("original_amount", sa.Float(), nullable=True),
        sa.Column("original_currency", sa.String(10), nullable=True),
        sa.Column("exchange_rate", sa.Float(), nullable=True),
        sa.Column("difference_sale_id", sa.String(36), nullable=True),
        sa.Column("reference", sa.String(120), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("recorded_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_customer_payments_farm_paid", "customer_payments", ["farm_id", "paid_at"])


def downgrade() -> None:
    op.drop_index("ix_customer_payments_farm_paid", table_name="customer_payments")
    op.drop_table("customer_payments")
    with op.batch_alter_table("sales") as batch:
        batch.drop_column("payment_id")
    for table in ("milk_tank_adjustments", "milk_sales"):
        with op.batch_alter_table(table) as batch:
            batch.drop_column("collection_day")
            batch.drop_column("session")
    with op.batch_alter_table("farms") as batch:
        batch.drop_column("milk_collector_currency")
        batch.drop_column("milk_collector_price")
        batch.drop_column("milk_collector_name")
        batch.drop_column("second_milking")
