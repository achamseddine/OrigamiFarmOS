"""Numbered feed mixes (FEED-SCHEMA.md §20, CLAUDE.md "Feed mix identity rule").

Revision ID: c9e1a7b2d4f6
Revises: b4d7e2f9a1c3
Create Date: 2026-10-09

Every locally mixed preparation gets one immutable, farm-wide sequential
mix number and a display code, plus its intended use (species /
management profile — classification validated by the usage policy, never
a separate table or sequence), production date, use-by date and mixer.
A per-farm counter row hands out the numbers under a row lock.

Backfill: existing batches are numbered in the order they were started,
per farm, and the counter continues after the highest number given.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "c9e1a7b2d4f6"
down_revision = "b4d7e2f9a1c3"
branch_labels = None
depends_on = None

CODE_FORMAT = "MIX-{n:06d}"


def upgrade() -> None:
    op.create_table(
        "feed_mix_sequences",
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), primary_key=True),
        sa.Column("last_number", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("code_format", sa.String(60), nullable=False, server_default=CODE_FORMAT),
    )
    with op.batch_alter_table("feed_batches") as b:
        b.add_column(sa.Column("mix_number", sa.Integer(), nullable=True))
        b.add_column(sa.Column("mix_code", sa.String(120), nullable=True))
        b.add_column(sa.Column("intended_species_code", sa.String(30), nullable=True))
        b.add_column(sa.Column("intended_management_profile", sa.String(40), nullable=True))
        b.add_column(sa.Column("production_date", sa.DateTime(timezone=True), nullable=True))
        b.add_column(sa.Column("use_by_date", sa.DateTime(timezone=True), nullable=True))
        b.add_column(sa.Column("mixer_asset_id", sa.String(80), nullable=True))
        b.create_foreign_key("fk_feed_batches_intended_species", "species", ["intended_species_code"], ["code"])

    conn = op.get_bind()
    rows = conn.execute(sa.text(
        "SELECT b.id, b.farm_id, b.formula_version_id FROM feed_batches b ORDER BY b.farm_id, b.started_at, b.created_at, b.id"
    )).fetchall()
    per_farm: dict[str, int] = {}
    for row in rows:
        number = per_farm.get(row.farm_id, 0) + 1
        per_farm[row.farm_id] = number
        species = None
        if row.formula_version_id:
            species = conn.execute(sa.text(
                "SELECT f.species_code FROM feed_formula_versions v JOIN feed_formulas f ON f.id = v.formula_id WHERE v.id = :v"
            ), {"v": row.formula_version_id}).scalar()
        conn.execute(sa.text(
            "UPDATE feed_batches SET mix_number = :n, mix_code = :c, intended_species_code = :s, "
            "production_date = COALESCE(produced_at, started_at), use_by_date = ("
            "SELECT l.expiry_date FROM feed_lots l WHERE l.feed_batch_id = feed_batches.id ORDER BY l.received_at LIMIT 1) "
            "WHERE id = :id"
        ), {"n": number, "c": CODE_FORMAT.format(n=number), "s": species, "id": row.id})
    for farm_id, last in per_farm.items():
        conn.execute(sa.text("INSERT INTO feed_mix_sequences (farm_id, last_number, code_format) VALUES (:f, :n, :fmt)"),
                     {"f": farm_id, "n": last, "fmt": CODE_FORMAT})

    # Every row has its identity now; make it mandatory and unique.
    with op.batch_alter_table("feed_batches") as b:
        b.alter_column("mix_number", existing_type=sa.Integer(), nullable=False)
        b.alter_column("mix_code", existing_type=sa.String(120), nullable=False)
        b.alter_column("production_date", existing_type=sa.DateTime(timezone=True), nullable=False)
        b.create_unique_constraint("uq_feed_batch_farm_mix_number", ["farm_id", "mix_number"])
        b.create_unique_constraint("uq_feed_batch_farm_mix_code", ["farm_id", "mix_code"])


def downgrade() -> None:
    with op.batch_alter_table("feed_batches") as b:
        b.drop_constraint("uq_feed_batch_farm_mix_code", type_="unique")
        b.drop_constraint("uq_feed_batch_farm_mix_number", type_="unique")
        b.drop_constraint("fk_feed_batches_intended_species", type_="foreignkey")
        b.drop_column("mixer_asset_id")
        b.drop_column("use_by_date")
        b.drop_column("production_date")
        b.drop_column("intended_management_profile")
        b.drop_column("intended_species_code")
        b.drop_column("mix_code")
        b.drop_column("mix_number")
    op.drop_table("feed_mix_sequences")
