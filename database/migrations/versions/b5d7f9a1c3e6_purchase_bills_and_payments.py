"""Purchases in the books: accepted stock, the supplier's bill, the cash paid
(v0.8.9, audit 2026-11-25 I-9, I-14).

Revision ID: b5d7f9a1c3e6
Revises: a3c5e7f9b1d2
Create Date: 2026-11-26

A delivery of feed or medicine with a price now posts one supplier bill
(`expenses`, linked to the lot) for what was accepted; the bill is settled
by payments, refunds and credit notes (`supplier_payments`). Profit and
loss takes cash out from those payments only — a delivery on credit is not
cash — and a bill for stock is never a second cost (feed is a cost when
fed, medicine when received).

Schema
- supplier_payments: one row per payment, supplier refund or credit note
  for a bill — cash in USD on its day (`amount`), what it settles in the
  bill's currency (`settles`), the LBP amount and rate, reversal links.
- expenses: unique (linked_entity_type, linked_entity_id) — one bill per
  delivery (NULLs, the plain expenses, are not constrained).

Data — nothing is rewritten. Deliveries recorded before this revision have
no bill: profit and loss no longer assumes they were paid on arrival. A
manager reviews them once (GET / POST /finance/reconciliation/purchases):
link the expense that already paid for one, or say it was paid on arrival
or is still owed. Downgrade drops the table and the constraint.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "b5d7f9a1c3e6"
down_revision = "a3c5e7f9b1d2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "supplier_payments",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("expense_id", sa.String(36), sa.ForeignKey("expenses.id"), nullable=False),
        sa.Column("supplier_id", sa.String(36), sa.ForeignKey("suppliers.id"), nullable=True),
        sa.Column("kind", sa.String(20), nullable=False),
        sa.Column("paid_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("amount", sa.Float(), nullable=False),
        sa.Column("settles", sa.Float(), nullable=False),
        sa.Column("original_amount", sa.Float(), nullable=True),
        sa.Column("original_currency", sa.String(10), nullable=True),
        sa.Column("exchange_rate", sa.Float(), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="recorded"),
        sa.Column("reversal_of_id", sa.String(36), nullable=True),
        sa.Column("reference", sa.String(120), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("recorded_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_supplier_payments_farm_paid", "supplier_payments", ["farm_id", "paid_at"])
    op.create_index("ix_supplier_payments_expense_id", "supplier_payments", ["expense_id"])
    with op.batch_alter_table("expenses") as batch:
        batch.create_unique_constraint("uq_expenses_linked_entity", ["linked_entity_type", "linked_entity_id"])


def downgrade() -> None:
    with op.batch_alter_table("expenses") as batch:
        batch.drop_constraint("uq_expenses_linked_entity", type_="unique")
    op.drop_index("ix_supplier_payments_expense_id", table_name="supplier_payments")
    op.drop_index("ix_supplier_payments_farm_paid", table_name="supplier_payments")
    op.drop_table("supplier_payments")
