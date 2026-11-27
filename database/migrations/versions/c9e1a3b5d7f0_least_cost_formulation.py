"""Least-cost formulation runs (v0.8.19, master prompt Package 12).

Revision ID: c9e1a3b5d7f0
Revises: b7d9f1a3c5e8
Create Date: 2026-11-27

Schema
- formulation_runs: one least-cost run — the requirement set version, the
  base formula version (if any), the ingredients allowed and their limits,
  the ration — and its result as computed (up to three drafts with the
  prices of the day, or what was infeasible, or what was not known), and the
  approval of one draft (who, when, why) with the draft formula version it
  became.

Data — nothing existing is changed: formulas, batches, lots and prices are
read, never written; an approval adds a new *draft* formula version through
the formula service. Downgrade drops the table.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "c9e1a3b5d7f0"
down_revision = "b7d9f1a3c5e8"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "formulation_runs",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("requirement_set_id", sa.String(36), sa.ForeignKey("nutrition_requirement_sets.id"), nullable=False),
        sa.Column("base_formula_version_id", sa.String(36), sa.ForeignKey("feed_formula_versions.id"), nullable=True),
        sa.Column("status", sa.String(30), nullable=False),
        sa.Column("inputs", sa.JSON(), nullable=False),
        sa.Column("result", sa.JSON(), nullable=False),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("approved_draft", sa.String(10), nullable=True),
        sa.Column("approved_by", sa.String(36), sa.ForeignKey("users.id"), nullable=True),
        sa.Column("approved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("approval_note", sa.Text(), nullable=True),
        sa.Column("approved_formula_version_id", sa.String(36), sa.ForeignKey("feed_formula_versions.id"), nullable=True),
    )
    op.create_index("ix_formulation_runs_farm_created", "formulation_runs", ["farm_id", "created_at"])


def downgrade() -> None:
    op.drop_index("ix_formulation_runs_farm_created", table_name="formulation_runs")
    op.drop_table("formulation_runs")
