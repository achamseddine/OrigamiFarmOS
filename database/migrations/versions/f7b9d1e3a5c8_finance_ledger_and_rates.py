"""The farm's financials: any sale, expenses and bills, USD / LBP.

Revision ID: f7b9d1e3a5c8
Revises: e6a8c0d2f4b7
Create Date: 2026-11-24

New table
- exchange_rates: LBP (or another currency) per USD from a date, set by
  the farm manager; a history, never edited.

New columns (all nullable or with a server default — existing rows keep
their meaning)
- sales: unit_price, buyer_name, reference, notes, status (recorded |
  cancelled | reversal, default recorded), cancel_reason, cancelled_at,
  reversal_of_id, paid_at, original_amount, original_currency,
  exchange_rate, activity, recorded_by, created_at.
- expenses: description, supplier_label, payment_status (paid | pending,
  default paid), due_date, paid_at, reference, notes, status (recorded |
  cancelled, default recorded), cancel_reason, cancelled_at,
  original_amount, original_currency, exchange_rate, activity,
  recorded_by, created_at.

Data: milk sales cancelled under v0.7.9 mark their revenue row
`cancelled` and its negative reversal `reversal` (with reversal_of_id), so
neither is counted as money a customer still owes. Downgrade drops the
columns and the table.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "f7b9d1e3a5c8"
down_revision = "e6a8c0d2f4b7"
branch_labels = None
depends_on = None

_SALE_COLUMNS = [
    ("unit_price", sa.Float()),
    ("buyer_name", sa.String(200)),
    ("reference", sa.String(120)),
    ("notes", sa.Text()),
    ("cancel_reason", sa.Text()),
    ("cancelled_at", sa.DateTime(timezone=True)),
    ("reversal_of_id", sa.String(36)),
    ("paid_at", sa.DateTime(timezone=True)),
    ("original_amount", sa.Float()),
    ("original_currency", sa.String(10)),
    ("exchange_rate", sa.Float()),
    ("activity", sa.String(20)),
    ("recorded_by", sa.String(36)),
    ("created_at", sa.DateTime(timezone=True)),
]

_EXPENSE_COLUMNS = [
    ("description", sa.String(300)),
    ("supplier_label", sa.String(200)),
    ("due_date", sa.DateTime(timezone=True)),
    ("paid_at", sa.DateTime(timezone=True)),
    ("reference", sa.String(120)),
    ("notes", sa.Text()),
    ("cancel_reason", sa.Text()),
    ("cancelled_at", sa.DateTime(timezone=True)),
    ("original_amount", sa.Float()),
    ("original_currency", sa.String(10)),
    ("exchange_rate", sa.Float()),
    ("activity", sa.String(20)),
    ("recorded_by", sa.String(36)),
    ("created_at", sa.DateTime(timezone=True)),
]


def upgrade() -> None:
    op.create_table(
        "exchange_rates",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("currency", sa.String(10), nullable=False),
        sa.Column("rate_per_usd", sa.Float(), nullable=False),
        sa.Column("effective_date", sa.Date(), nullable=False),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("set_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_exchange_rates_farm_currency_date", "exchange_rates", ["farm_id", "currency", "effective_date"])

    with op.batch_alter_table("sales") as batch:
        batch.add_column(sa.Column("status", sa.String(20), nullable=False, server_default="recorded"))
        for name, type_ in _SALE_COLUMNS:
            batch.add_column(sa.Column(name, type_, nullable=True))
    with op.batch_alter_table("expenses") as batch:
        batch.add_column(sa.Column("payment_status", sa.String(20), nullable=False, server_default="paid"))
        batch.add_column(sa.Column("status", sa.String(20), nullable=False, server_default="recorded"))
        for name, type_ in _EXPENSE_COLUMNS:
            batch.add_column(sa.Column(name, type_, nullable=True))

    # Milk sales cancelled under v0.7.9: the revenue row is "cancelled",
    # its negative twin a "reversal" of it.
    op.execute(
        "UPDATE sales SET status = 'cancelled', cancel_reason = (SELECT ms.cancel_reason FROM milk_sales ms WHERE ms.sale_id = sales.id), "
        "cancelled_at = (SELECT ms.cancelled_at FROM milk_sales ms WHERE ms.sale_id = sales.id) "
        "WHERE id IN (SELECT sale_id FROM milk_sales WHERE status = 'cancelled' AND sale_id IS NOT NULL)"
    )
    op.execute(
        "UPDATE sales SET status = 'reversal', reversal_of_id = (SELECT ms.sale_id FROM milk_sales ms WHERE ms.reversal_sale_id = sales.id) "
        "WHERE id IN (SELECT reversal_sale_id FROM milk_sales WHERE reversal_sale_id IS NOT NULL)"
    )
    # A milk sale marked paid under v0.7.9: its payment date.
    op.execute(
        "UPDATE sales SET paid_at = (SELECT ms.paid_at FROM milk_sales ms WHERE ms.sale_id = sales.id) "
        "WHERE id IN (SELECT sale_id FROM milk_sales WHERE paid_at IS NOT NULL AND sale_id IS NOT NULL)"
    )


def downgrade() -> None:
    with op.batch_alter_table("expenses") as batch:
        for name, _ in reversed(_EXPENSE_COLUMNS):
            batch.drop_column(name)
        batch.drop_column("status")
        batch.drop_column("payment_status")
    with op.batch_alter_table("sales") as batch:
        for name, _ in reversed(_SALE_COLUMNS):
            batch.drop_column(name)
        batch.drop_column("status")
    op.drop_index("ix_exchange_rates_farm_currency_date", table_name="exchange_rates")
    op.drop_table("exchange_rates")
