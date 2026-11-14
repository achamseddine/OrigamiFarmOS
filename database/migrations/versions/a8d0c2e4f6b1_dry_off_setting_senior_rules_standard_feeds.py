"""Farm dry-off setting, senior-stage capability rules, standard feeds.

Revision ID: a8d0c2e4f6b1
Revises: b5e7a9c1d3f8
Create Date: 2026-11-13

Column addition
- farms.dry_off_days_before_birth (integer, default 60): how many days
  before an expected birth a lactating animal stops being milked. A farm
  setting, changed with PATCH /farms/me; the reproduction overview and the
  Digital Twin show the resulting "dry off from" date. A plan, never a
  record — the dry-off itself is still recorded when it happens.

Reference data
- species_capability_rules: every adult-only rule also for the `senior`
  stage (an old cow still calves and is milked, an old mare still foals).
  Before this, a female registered "senior" could not be recorded pregnant
  or in milk. Inserted only where the same rule is not there already.

Farm data
- For every farm, the three standard feeds of the animal feeding form —
  Concentrate (farm-produced: the farm's mixes make it), Corn silage, Wheat
  straw (purchased) — as ordinary feedable feed products, each with its
  inventory item and an EMPTY ledger (no stock
  is invented; feeding beyond counted stock stays an explicit override).
  A farm that already has a matching feed (same code, the keyword in its
  name, or for concentrate any concentrate) keeps it and gets no second one.

Downgrade drops the column and the senior rules this revision inserted. The
standard feeds stay: they are valid rows under the previous schema and may
already be referenced by feeding records and stock movements.

Verified by backend/tests/test_migrations.py (upgrade, ORM parity, demo
seed, downgrade to base and upgrade again).
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

import sqlalchemy as sa
from alembic import op

revision = "a8d0c2e4f6b1"
down_revision = "b5e7a9c1d3f8"
branch_labels = None
depends_on = None

# Frozen at this revision: the catalog may change later, this migration must not.
# (species, capability, sex, management_profile) — life stage "senior".
_SENIOR_RULES = (
    ("cow", "BREEDING", None, None), ("cow", "PREGNANCY", "F", None), ("cow", "LIVE_BIRTH", "F", None),
    ("cow", "MILK_PRODUCTION", "F", "dairy"), ("cow", "LACTATION", "F", "dairy"),
    ("cow", "MILK_PRODUCTION", "F", "dual_purpose"), ("cow", "LACTATION", "F", "dual_purpose"),
    ("sheep", "BREEDING", None, None), ("sheep", "PREGNANCY", "F", None), ("sheep", "LIVE_BIRTH", "F", None),
    ("sheep", "MILK_PRODUCTION", "F", "dairy"), ("sheep", "LACTATION", "F", "dairy"),
    ("goat", "BREEDING", None, None), ("goat", "PREGNANCY", "F", None), ("goat", "LIVE_BIRTH", "F", None),
    ("goat", "MILK_PRODUCTION", "F", "dairy"), ("goat", "LACTATION", "F", "dairy"),
    ("goat", "MILK_PRODUCTION", "F", "dual_purpose"), ("goat", "LACTATION", "F", "dual_purpose"),
    ("horse", "BREEDING", None, None), ("horse", "PREGNANCY", "F", None), ("horse", "LIVE_BIRTH", "F", None),
    ("layer_hen", "BREEDING", None, None), ("layer_hen", "EGG_PRODUCTION", "F", None),
    ("duck", "BREEDING", None, None), ("duck", "EGG_PRODUCTION", "F", None),
    ("turkey", "BREEDING", None, None), ("turkey", "EGG_PRODUCTION", "F", None),
)

# (slot, code, name_en, name_ar, category, unit, name keywords)
_STANDARD_FEEDS = (
    ("concentrate", "CONCENTRATE", "Concentrate", "علف مركّز", "concentrate", "kg", ("concentrate", "مركز", "مركّز")),
    ("corn_silage", "CORN-SILAGE", "Corn silage", "سيلاج الذرة", "forage", "kg", ("silage", "سيلاج")),
    ("wheat_straw", "WHEAT-STRAW", "Wheat straw", "تبن القمح", "forage", "kg", ("straw", "تبن")),
)


def _senior_rule_exists(bind, species, capability, sex, profile) -> bool:
    return bind.execute(
        sa.text(
            "select 1 from species_capability_rules where species_code = :s and capability_code = :c and life_stage = 'senior'"
            " and coalesce(sex, '') = :sex and coalesce(management_profile, '') = :p"
        ),
        {"s": species, "c": capability, "sex": sex or "", "p": profile or ""},
    ).first() is not None


def _has_matching_feed(bind, farm_id, slot, code, category, keywords) -> bool:
    rows = bind.execute(
        sa.text("select code, name, name_ar, category from feed_products where farm_id = :f and status = 'active' and is_feedable = :t"),
        {"f": farm_id, "t": True},
    ).fetchall()
    for row_code, name, name_ar, row_category in rows:
        if (row_code or "").upper() == code:
            return True
        names = f"{name or ''} {name_ar or ''}".lower()
        if any(k.lower() in names for k in keywords):
            return True
        if slot == "concentrate" and (row_category or "").lower() == category:
            return True
    return False


def _free_code(bind, farm_id, base) -> str:
    code, n = base, 2
    while bind.execute(sa.text("select 1 from feed_products where farm_id = :f and code = :c"), {"f": farm_id, "c": code}).first():
        code = f"{base}-{n}"
        n += 1
    return code


def upgrade() -> None:
    with op.batch_alter_table("farms") as b:
        b.add_column(sa.Column("dry_off_days_before_birth", sa.Integer(), nullable=False, server_default="60"))

    bind = op.get_bind()
    rules = sa.table(
        "species_capability_rules",
        sa.column("id", sa.String), sa.column("species_code", sa.String), sa.column("capability_code", sa.String),
        sa.column("sex", sa.String), sa.column("life_stage", sa.String), sa.column("management_profile", sa.String),
        sa.column("enabled", sa.Boolean), sa.column("required", sa.Boolean), sa.column("configuration_json", sa.JSON),
        sa.column("priority", sa.Integer),
    )
    known_species = {r[0] for r in bind.execute(sa.text("select code from species")).fetchall()}
    new_rules = [
        {"id": str(uuid.uuid4()), "species_code": s, "capability_code": c, "sex": sex, "life_stage": "senior", "management_profile": p,
         "enabled": True, "required": False, "configuration_json": None, "priority": 0}
        for s, c, sex, p in _SENIOR_RULES
        if s in known_species and not _senior_rule_exists(bind, s, c, sex, p)
    ]
    if new_rules:
        op.bulk_insert(rules, new_rules)

    items = sa.table(
        "inventory_items",
        sa.column("id", sa.String), sa.column("farm_id", sa.String), sa.column("name", sa.String), sa.column("category", sa.String),
        sa.column("unit", sa.String), sa.column("current_qty", sa.Float), sa.column("reorder_level", sa.Float),
    )
    products = sa.table(
        "feed_products",
        sa.column("id", sa.String), sa.column("farm_id", sa.String), sa.column("code", sa.String), sa.column("name", sa.String),
        sa.column("name_ar", sa.String), sa.column("source_type", sa.String), sa.column("is_ingredient", sa.Boolean),
        sa.column("is_feedable", sa.Boolean), sa.column("category", sa.String), sa.column("unit", sa.String),
        sa.column("inventory_item_id", sa.String), sa.column("status", sa.String), sa.column("notes", sa.Text),
        sa.column("created_at", sa.DateTime(timezone=True)),
    )
    at = datetime.now(timezone.utc)
    for (farm_id,) in bind.execute(sa.text("select id from farms")).fetchall():
        for slot, code, name_en, name_ar, category, unit, keywords in _STANDARD_FEEDS:
            if _has_matching_feed(bind, farm_id, slot, code, category, keywords):
                continue
            item_id = str(uuid.uuid4())
            op.bulk_insert(items, [{"id": item_id, "farm_id": farm_id, "name": name_en, "category": category.capitalize(), "unit": unit,
                                    "current_qty": 0.0, "reorder_level": 0.0}])
            op.bulk_insert(products, [{
                "id": str(uuid.uuid4()), "farm_id": farm_id, "code": _free_code(bind, farm_id, code), "name": name_en, "name_ar": name_ar,
                "source_type": "farm_produced" if slot == "concentrate" else "purchased", "is_ingredient": True, "is_feedable": True,
                "category": category, "unit": unit,
                "inventory_item_id": item_id, "status": "active", "notes": "Standard feed of the animal feeding form.", "created_at": at,
            }])


def downgrade() -> None:
    bind = op.get_bind()
    for s, c, sex, p in _SENIOR_RULES:
        bind.execute(
            sa.text(
                "delete from species_capability_rules where species_code = :s and capability_code = :c and life_stage = 'senior'"
                " and coalesce(sex, '') = :sex and coalesce(management_profile, '') = :p"
            ),
            {"s": s, "c": c, "sex": sex or "", "p": p or ""},
        )
    with op.batch_alter_table("farms") as b:
        b.drop_column("dry_off_days_before_birth")
