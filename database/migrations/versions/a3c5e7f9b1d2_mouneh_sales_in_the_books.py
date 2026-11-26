"""Mouneh sales in the farm's books (v0.8.8, audit 2026-11-25 I-8).

Revision ID: a3c5e7f9b1d2
Revises: e8a0c2e4b6d9
Create Date: 2026-11-26

A sale in the Mouneh shop now also posts one canonical `sales` row (revenue)
linked from its line (`mouneh_sale_lines.sale_id`, which existed and was
never set), and its payment is cash received — at the till, later, or in
parts (backend/app/services/mouneh_sales_service.py).

Schema
- mouneh_sale_lines.status  recorded | cancelled (NOT NULL, server default
  'recorded': every line made before this revision is a sale on record).
- mouneh_sale_lines.cancel_reason, cancelled_at, cancelled_by.
- an index on mouneh_sale_lines.sale_id (the books look lines up by sale).
- customer_payments.sale_id (FK sales, nullable, indexed): a receipt toward
  one sale paid in parts, or the refund of those parts when it is cancelled.

Data — nothing is rewritten here. Lines recorded before this revision have
no sale in the books (that is I-8). They are posted by the reconciliation,
which a manager runs as a dry run first and then applies, and which never
posts a line twice (GET / POST /finance/reconciliation/mouneh-sales,
docs/runbooks/MOUNEH-SALES-RECONCILIATION.md).

Downgrade drops the columns and indexes; sales posted meanwhile stay (they
are ordinary sales rows).
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "a3c5e7f9b1d2"
down_revision = "e8a0c2e4b6d9"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("mouneh_sale_lines") as batch:
        batch.add_column(sa.Column("status", sa.String(20), nullable=False, server_default="recorded"))
        batch.add_column(sa.Column("cancel_reason", sa.Text(), nullable=True))
        batch.add_column(sa.Column("cancelled_at", sa.DateTime(timezone=True), nullable=True))
        batch.add_column(sa.Column("cancelled_by", sa.String(36), nullable=True))
        batch.create_index("ix_mouneh_sale_lines_sale_id", ["sale_id"])
    with op.batch_alter_table("customer_payments") as batch:
        batch.add_column(sa.Column("sale_id", sa.String(36), nullable=True))
        batch.create_foreign_key("fk_customer_payments_sale", "sales", ["sale_id"], ["id"])
        batch.create_index("ix_customer_payments_sale_id", ["sale_id"])


def downgrade() -> None:
    with op.batch_alter_table("customer_payments") as batch:
        batch.drop_index("ix_customer_payments_sale_id")
        batch.drop_constraint("fk_customer_payments_sale", type_="foreignkey")
        batch.drop_column("sale_id")
    with op.batch_alter_table("mouneh_sale_lines") as batch:
        batch.drop_index("ix_mouneh_sale_lines_sale_id")
        for col in ("cancelled_by", "cancelled_at", "cancel_reason", "status"):
            batch.drop_column(col)
