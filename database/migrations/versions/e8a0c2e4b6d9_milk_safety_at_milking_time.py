"""Milk safety judged at the milking time (v0.8.5, ADR-005).

Revision ID: e8a0c2e4b6d9
Revises: d6f8a0c2e4b7
Create Date: 2026-11-25

Audit 2026-11-25 I-3 and I-15: a milking is judged at its own timestamp
from the animal's dated veterinary history and lactation episodes, not
from her record today (backend/app/services/milk_safety_service.py).

Schema
- milk_records.withdrawal_check  clear | withdrawal | uncertain | unchecked
  (NOT NULL, server default 'unchecked': every record made before this
  revision, never assessed at entry).
- milk_records.release_status    saleable | held | released | not_for_sale
  (NOT NULL, server default 'saleable': what older records counted as).
- milk_records.safety_note, checked_at, reviewed_by, reviewed_at,
  review_note, lactation_episode_id (FK lactation_episodes; nullable).
- animals.withdrawal_known_since: when the server first held the animal's
  withdrawal_until — the withdrawal began no later than that.

Data — nothing is rewritten:
- Existing milk records keep their destination, litres and time, are
  `unchecked` and `saleable`: the tank, the handovers, the sales and the
  reports read exactly what they read before. The ones the dated history
  now says were under withdrawal are listed by GET
  /production/milk-safety/review for the manager and the veterinarian to
  decide (docs/runbooks/MILK-SAFETY-REVIEW.md); a sale already made is
  never changed.
- An animal with a withdrawal on her record gets withdrawal_known_since =
  the time of this migration: true (the withdrawal was there then, so it
  began no later), and the only time the server can vouch for. Milk dated
  before it is judged from her dated treatments and doses; where none
  explains the withdrawal, that milk is held for review, never cleared.

Downgrade drops the columns.
"""
from __future__ import annotations

from datetime import datetime, timezone

import sqlalchemy as sa
from alembic import op

revision = "e8a0c2e4b6d9"
down_revision = "d6f8a0c2e4b7"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("milk_records") as batch:
        batch.add_column(sa.Column("withdrawal_check", sa.String(20), nullable=False, server_default="unchecked"))
        batch.add_column(sa.Column("release_status", sa.String(20), nullable=False, server_default="saleable"))
        batch.add_column(sa.Column("safety_note", sa.Text(), nullable=True))
        batch.add_column(sa.Column("checked_at", sa.DateTime(timezone=True), nullable=True))
        batch.add_column(sa.Column("reviewed_by", sa.String(36), nullable=True))
        batch.add_column(sa.Column("reviewed_at", sa.DateTime(timezone=True), nullable=True))
        batch.add_column(sa.Column("review_note", sa.Text(), nullable=True))
        batch.add_column(sa.Column("lactation_episode_id", sa.String(36), nullable=True))
        batch.create_foreign_key("fk_milk_records_lactation_episode", "lactation_episodes", ["lactation_episode_id"], ["id"])
    with op.batch_alter_table("animals") as batch:
        batch.add_column(sa.Column("withdrawal_known_since", sa.DateTime(timezone=True), nullable=True))
    animals = sa.table("animals", sa.column("withdrawal_until", sa.DateTime(timezone=True)),
                       sa.column("withdrawal_known_since", sa.DateTime(timezone=True)))
    op.get_bind().execute(animals.update().where(animals.c.withdrawal_until.is_not(None))
                          .values(withdrawal_known_since=datetime.now(timezone.utc)))


def downgrade() -> None:
    with op.batch_alter_table("animals") as batch:
        batch.drop_column("withdrawal_known_since")
    with op.batch_alter_table("milk_records") as batch:
        batch.drop_constraint("fk_milk_records_lactation_episode", type_="foreignkey")
        for col in ("lactation_episode_id", "review_note", "reviewed_at", "reviewed_by", "checked_at", "safety_note", "release_status", "withdrawal_check"):
            batch.drop_column(col)
