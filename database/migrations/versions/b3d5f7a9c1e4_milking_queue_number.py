"""Each cow's number in the milking queue.

Revision ID: b3d5f7a9c1e4
Revises: a2c4e6f8b0d3
Create Date: 2026-11-24

The farm milks its cows in the same order every time. The manager gives
each animal in milk her number in that line; the milking queue and the
manual milk entry follow it, opening the next number after each save.

New column (nullable — existing animals simply have no number yet and are
queued after the numbered ones, by tag, as before)
- animals.milking_queue_number: the animal's place in the milking line.
  Unique among the animals on the farm, checked by the service (an animal
  that left keeps its old number on record without holding it).

Downgrade drops the column.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "b3d5f7a9c1e4"
down_revision = "a2c4e6f8b0d3"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("animals") as batch:
        batch.add_column(sa.Column("milking_queue_number", sa.Integer(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("animals") as batch:
        batch.drop_column("milking_queue_number")
