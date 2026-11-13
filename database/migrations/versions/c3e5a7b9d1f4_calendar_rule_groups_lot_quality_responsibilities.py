"""Breeding/milk calendar settings, rule groups, receipt quality, responsibilities.

Revision ID: c3e5a7b9d1f4
Revises: a8d0c2e4f6b1
Create Date: 2026-11-13

Column additions
- farms: milk_peak_start_days (40), milk_peak_end_days (70),
  breeding_wait_days (50), heat_cycle_days (21) — the calendar after a birth
  the Digital Twin and the reproduction overview plan from (milk peak window,
  voluntary waiting period before the next insemination, return-to-heat
  watch after a service). Plans, never records.
- flocks.membership_rule: PREGNANT | NOT_PREGNANT | IN_MILK | DRY — a group
  whose members follow the herd records (group_service.sync_rule_groups);
  null for an ordinary group. Memberships stay effective-dated rows.
- feed_lots: quality_grade, moisture_pct, quality_notes — quality at
  receipt (FEED-SCHEMA §26).

New table
- work_responsibilities: an employee's animals / group / species / field
  and duties (milking, feeding, observation, …), active or ended.

Reference data
- species_capability_rules: GROUP_TRACKING for cattle, so a herd can also be
  kept as a counted group (heifers on pasture) besides its member groups
  (milking, pregnant, dry). Inserted only where absent.

Downgrade drops the table, the columns and the rule.
"""
from __future__ import annotations

import uuid

import sqlalchemy as sa
from alembic import op

revision = "c3e5a7b9d1f4"
down_revision = "a8d0c2e4f6b1"
branch_labels = None
depends_on = None

_GROUP_RULES = ("cow",)


def _rule_exists(bind, species: str) -> bool:
    return bind.execute(
        sa.text(
            "select 1 from species_capability_rules where species_code = :s and capability_code = 'GROUP_TRACKING'"
            " and sex is null and life_stage is null and management_profile is null"
        ),
        {"s": species},
    ).first() is not None


def upgrade() -> None:
    with op.batch_alter_table("farms") as b:
        b.add_column(sa.Column("milk_peak_start_days", sa.Integer(), nullable=False, server_default="40"))
        b.add_column(sa.Column("milk_peak_end_days", sa.Integer(), nullable=False, server_default="70"))
        b.add_column(sa.Column("breeding_wait_days", sa.Integer(), nullable=False, server_default="50"))
        b.add_column(sa.Column("heat_cycle_days", sa.Integer(), nullable=False, server_default="21"))
    with op.batch_alter_table("flocks") as b:
        b.add_column(sa.Column("membership_rule", sa.String(30), nullable=True))
    with op.batch_alter_table("feed_lots") as b:
        b.add_column(sa.Column("quality_grade", sa.String(20), nullable=True))
        b.add_column(sa.Column("moisture_pct", sa.Float(), nullable=True))
        b.add_column(sa.Column("quality_notes", sa.Text(), nullable=True))

    op.create_table(
        "work_responsibilities",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("scope_type", sa.String(20), nullable=False),
        sa.Column("scope_id", sa.String(36), nullable=False),
        sa.Column("duties", sa.JSON(), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("valid_from", sa.DateTime(timezone=True), nullable=False),
        sa.Column("valid_to", sa.DateTime(timezone=True), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_work_responsibilities_user", "work_responsibilities", ["user_id"])

    bind = op.get_bind()
    known = {r[0] for r in bind.execute(sa.text("select code from species")).fetchall()}
    rules = sa.table(
        "species_capability_rules",
        sa.column("id", sa.String), sa.column("species_code", sa.String), sa.column("capability_code", sa.String),
        sa.column("sex", sa.String), sa.column("life_stage", sa.String), sa.column("management_profile", sa.String),
        sa.column("enabled", sa.Boolean), sa.column("required", sa.Boolean), sa.column("configuration_json", sa.JSON),
        sa.column("priority", sa.Integer),
    )
    rows = [
        {"id": str(uuid.uuid4()), "species_code": s, "capability_code": "GROUP_TRACKING", "sex": None, "life_stage": None,
         "management_profile": None, "enabled": True, "required": False, "configuration_json": None, "priority": 0}
        for s in _GROUP_RULES
        if s in known and not _rule_exists(bind, s)
    ]
    if rows:
        op.bulk_insert(rules, rows)


def downgrade() -> None:
    bind = op.get_bind()
    for s in _GROUP_RULES:
        bind.execute(
            sa.text(
                "delete from species_capability_rules where species_code = :s and capability_code = 'GROUP_TRACKING'"
                " and sex is null and life_stage is null and management_profile is null"
            ),
            {"s": s},
        )
    op.drop_index("ix_work_responsibilities_user", table_name="work_responsibilities")
    op.drop_table("work_responsibilities")
    with op.batch_alter_table("feed_lots") as b:
        b.drop_column("quality_notes")
        b.drop_column("moisture_pct")
        b.drop_column("quality_grade")
    with op.batch_alter_table("flocks") as b:
        b.drop_column("membership_rule")
    with op.batch_alter_table("farms") as b:
        b.drop_column("heat_cycle_days")
        b.drop_column("breeding_wait_days")
        b.drop_column("milk_peak_end_days")
        b.drop_column("milk_peak_start_days")
