"""Replay protection for writes queued on an offline tablet.

Revision ID: 3d92c6a5f1b7
Revises: 8b41d0c7e2a9
Create Date: 2026-08-27

A tablet that loses the farm network queues the write it was making and
sends it again when it is back in range. If the first attempt actually
committed and only its response was lost, the replay would record the
same milking, treatment or harvest twice. `idempotency_records` stores
the first completed response against the key the tablet sent, so the
replay is answered with it instead of writing anything.

Keyed per (key, user): two tablets can never collide, and a replayed key
can never hand back another account's response body.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "3d92c6a5f1b7"
down_revision: Union[str, None] = "8b41d0c7e2a9"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "idempotency_records",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("idempotency_key", sa.String(length=100), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("method", sa.String(length=10), nullable=False),
        sa.Column("path", sa.String(length=300), nullable=False),
        sa.Column("status_code", sa.Integer(), nullable=False),
        sa.Column("response_body", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("idempotency_key", "user_id", name="uq_idempotency_key_user"),
    )
    op.create_index("ix_idempotency_records_key", "idempotency_records", ["idempotency_key"])


def downgrade() -> None:
    op.drop_index("ix_idempotency_records_key", table_name="idempotency_records")
    op.drop_table("idempotency_records")
