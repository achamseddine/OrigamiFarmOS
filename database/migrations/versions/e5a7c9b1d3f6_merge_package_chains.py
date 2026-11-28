"""Merge the two package chains' migration heads (integrated release v0.8.20).

Revision ID: e5a7c9b1d3f6
Revises: d9b1c3e5f7a2, d1f3a5c7e9b2
Create Date: 2026-11-28

Packages 1, 2 and 7 (… → d9b1c3e5f7a2, crop cycles) and Packages 11–13
(… → d1f3a5c7e9b2, feed performance actions) each start from the main
branch's head a3c5e7f9b1d2 and touch different tables. This revision only
joins them so `alembic upgrade head` has one head; it changes no schema.
"""
from __future__ import annotations

revision = "e5a7c9b1d3f6"
down_revision = ("d9b1c3e5f7a2", "d1f3a5c7e9b2")
branch_labels = None
depends_on = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass
