"""Approval requests: employee work that waits for the farm manager.

Revision ID: d5f7b9c1e3a6
Revises: c3e5a7b9d1f4
Create Date: 2026-11-20

New table
- approval_requests: a numbered feed mix or a correction to a milk record
  or a feeding, made by an employee without approval on the module. It is
  kept as a request — kind, the employee's version (payload), reason,
  who asked — and nothing in stock, mixes or records changes until a
  manager approves it; approving runs the same service a manager would
  use directly and records the result. Rejected and cancelled requests
  change nothing.

No data change. Downgrade drops the table.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "d5f7b9c1e3a6"
down_revision = "c3e5a7b9d1f4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "approval_requests",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("kind", sa.String(40), nullable=False),
        sa.Column("module_code", sa.String(40), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("subject_type", sa.String(30), nullable=True),
        sa.Column("subject_id", sa.String(36), nullable=True),
        sa.Column("target_id", sa.String(36), nullable=True),
        sa.Column("summary", sa.String(300), nullable=False),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=True),
        sa.Column("requested_by", sa.String(36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("requested_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("decided_by", sa.String(36), nullable=True),
        sa.Column("decided_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("decision_note", sa.Text(), nullable=True),
        sa.Column("result_type", sa.String(40), nullable=True),
        sa.Column("result_id", sa.String(36), nullable=True),
    )
    op.create_index("ix_approval_requests_status", "approval_requests", ["farm_id", "status"])
    op.create_index("ix_approval_requests_target", "approval_requests", ["farm_id", "target_id"])


def downgrade() -> None:
    op.drop_index("ix_approval_requests_target", table_name="approval_requests")
    op.drop_index("ix_approval_requests_status", table_name="approval_requests")
    op.drop_table("approval_requests")
