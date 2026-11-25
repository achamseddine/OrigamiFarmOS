"""What the animals are fed: concentrate, corn silage, hay & straw.

Revision ID: c4e6a8b0d2f5
Revises: b3d5f7a9c1e4
Create Date: 2026-11-25

The animals are fed three things — the farm's concentrate (its own mix or
a bought one), corn silage, and hay & straw. Grain, meals, minerals and
premix are raw materials: they go into a mix and reach the animals only
through it. Until now a feed bought on the purchase form was marked
"feedable" whatever it was, so raw materials were offered on the feeding
forms.

New column (nullable)
- feed_products.ration_type: concentrate | silage | hay_straw, or null for
  a raw material. `is_feedable` follows it from now on.

Data
- Each feedable product gets the type its standard slot, its use in an
  active feeding program, or its name and category say (see
  `classify` below; the rules are the server's catalog.infer_ration_type).
- A product marked feedable that is none of the three becomes a raw
  material (`is_feedable` false, `is_ingredient` true) unless an active
  feeding program feeds it as it is: then it stays a feed, typed by its
  category. Nothing is deleted; the manager can change a feed's type on the
  Raw materials & lots tab.

Downgrade drops the column (is_feedable keeps its new values).
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "c4e6a8b0d2f5"
down_revision = "b3d5f7a9c1e4"
branch_labels = None
depends_on = None

_WORDS = (
    ("silage", ("silage", "سيلاج", "سيلج")),
    ("hay_straw", ("straw", "hay", "alfalfa", "تبن", "قش", "دريس", "فصة", "برسيم")),
    ("concentrate", ("concentrate", "مركز", "مركّز")),
)
_SLOT_CODES = {"CONCENTRATE": "concentrate", "CORN-SILAGE": "silage", "WHEAT-STRAW": "hay_straw"}


def classify(code, name, name_ar, category, is_ingredient, in_program):
    """The migration's own copy of the rule (a migration never imports the
    application): slot code, then name, then category."""
    if (code or "").upper() in _SLOT_CODES:
        return _SLOT_CODES[(code or "").upper()]
    names = f"{name or ''} {name_ar or ''}".lower()
    for ration, words in _WORDS:
        if any(w in names for w in words):
            return ration
    if (category or "").lower() == "forage":
        return "hay_straw"
    if not is_ingredient:
        return "concentrate"
    if in_program:
        return "hay_straw" if (category or "").lower() == "forage" else "concentrate"
    return None


def upgrade() -> None:
    with op.batch_alter_table("feed_products") as batch:
        batch.add_column(sa.Column("ration_type", sa.String(20), nullable=True))
    bind = op.get_bind()
    in_program = {row[0] for row in bind.execute(sa.text(
        "SELECT DISTINCT c.feed_product_id FROM feeding_program_components c "
        "JOIN feeding_program_versions v ON v.id = c.version_id WHERE v.status = 'active'"))}
    rows = bind.execute(sa.text(
        "SELECT id, code, name, name_ar, category, is_ingredient FROM feed_products WHERE is_feedable = :t"), {"t": True}).fetchall()
    for pid, code, name, name_ar, category, is_ingredient in rows:
        ration = classify(code, name, name_ar, category, bool(is_ingredient), pid in in_program)
        if ration is None:
            bind.execute(sa.text("UPDATE feed_products SET is_feedable = :f, is_ingredient = :t WHERE id = :id"),
                         {"f": False, "t": True, "id": pid})
        else:
            bind.execute(sa.text("UPDATE feed_products SET ration_type = :r WHERE id = :id"), {"r": ration, "id": pid})


def downgrade() -> None:
    with op.batch_alter_table("feed_products") as batch:
        batch.drop_column("ration_type")
