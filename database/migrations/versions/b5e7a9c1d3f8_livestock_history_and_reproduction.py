"""Livestock history, first-class groups and the reproduction domain.

Revision ID: b5e7a9c1d3f8
Revises: a7c9e1f3b5d7
Create Date: 2026-11-12

Implements the parts of database/LIVESTOCK-SCHEMA.md, REPRODUCTION-SCHEMA.md
and PRODUCTION-SCHEMA.md §8 that the animal model still lacked
(docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md §13 steps 7, 10 and 11).

New tables
- animal_state_history (LIVESTOCK §5): effective-dated STATUS, LIFE_STAGE,
  MANAGEMENT_PROFILE and LOCATION.
- animal_group_type_policies (§8), animal_group_memberships (§7),
  animal_group_quantity_events (§9), animal_relationships (§10).
- breeding_events, pregnancy_episodes, pregnancy_assessments, birth_events,
  birth_offspring, incubation_batches, hatch_events (REPRODUCTION).
- lactation_episodes (PRODUCTION §8).

Column additions
- species: gestation_days, incubation_days (configuration for due dates).
- animals: lifecycle_status, exited_at, pregnancy_started_at,
  expected_due_date — projections, written only by the domain services.
- flocks: tracking_mode, created_at.

Backfill — existing flags become the authoritative records they stood for:
- every animal gets opening state-history rows (status, stage, profile,
  location) dated from its registration;
- an existing flock with individually registered members becomes HYBRID,
  otherwise QUANTITY_MANAGED, and its count becomes an INITIAL_COUNT
  quantity event;
- an animal's free-text `group_name` that names no group of its species
  becomes a MEMBERSHIP_DERIVED group of that name ("Dairy Herd"), and every
  animal whose group_name matches a group gets a membership;
- `pregnant = true` becomes an active pregnancy episode (conception dated
  from `pregnancy_days` where known), `lactating = true` an active
  lactation episode numbered from `lactation_cycle`.

Downgrade drops the new tables and columns. Groups the backfill created stay
as ordinary `flocks` rows — valid under the previous schema, and possibly
referenced by feeding records made since — and animals keep their
`group_name`, so nothing an older build reads is lost.

Verified by backend/tests/test_migrations.py (upgrade, ORM parity, demo
seed, downgrade to base and upgrade again).
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import sqlalchemy as sa
from alembic import op

revision = "b5e7a9c1d3f8"
down_revision = "a7c9e1f3b5d7"
branch_labels = None
depends_on = None

# Frozen at this revision: the catalog may change later, this migration must not.
_GESTATION = {"cow": 283, "sheep": 147, "goat": 150, "horse": 340}
_INCUBATION = {"layer_hen": 21, "duck": 28, "turkey": 28}
_GROUP_TYPES = (
    ("herd", "Herd", "قطيع", True, True),
    ("flock", "Flock", "سرب", True, True),
    ("pen", "Pen", "حظيرة", True, True),
    ("batch", "Batch", "دفعة", True, True),
    ("cohort", "Cohort", "مجموعة متابعة", False, True),
)
_BACKFILL = "backfill"


def _ts(name: str, nullable: bool = False) -> sa.Column:
    return sa.Column(name, sa.DateTime(timezone=True), nullable=nullable)


def _id(name: str = "id") -> sa.Column:
    return sa.Column(name, sa.String(36), primary_key=True)


def _fk(name: str, target: str, nullable: bool = False) -> sa.Column:
    return sa.Column(name, sa.String(36), sa.ForeignKey(target), nullable=nullable)


def upgrade() -> None:
    # ------------------------------------------------------------ columns
    with op.batch_alter_table("species") as b:
        b.add_column(sa.Column("gestation_days", sa.Integer(), nullable=True))
        b.add_column(sa.Column("incubation_days", sa.Integer(), nullable=True))
    with op.batch_alter_table("animals") as b:
        b.add_column(sa.Column("lifecycle_status", sa.String(20), nullable=False, server_default="active"))
        b.add_column(_ts("exited_at", nullable=True))
        b.add_column(_ts("pregnancy_started_at", nullable=True))
        b.add_column(_ts("expected_due_date", nullable=True))
    with op.batch_alter_table("flocks") as b:
        b.add_column(sa.Column("tracking_mode", sa.String(30), nullable=False, server_default="QUANTITY_MANAGED"))
        b.add_column(_ts("created_at", nullable=True))

    # ------------------------------------------------------------ livestock
    policies = op.create_table(
        "animal_group_type_policies",
        sa.Column("group_type", sa.String(30), primary_key=True),
        sa.Column("label_en", sa.String(80), nullable=False),
        sa.Column("label_ar", sa.String(80), nullable=False),
        sa.Column("exclusive_membership", sa.Boolean(), nullable=False),
        sa.Column("allows_individual_members", sa.Boolean(), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False),
    )
    op.bulk_insert(policies, [
        {"group_type": c, "label_en": en, "label_ar": ar, "exclusive_membership": ex, "allows_individual_members": ind, "active": True}
        for c, en, ar, ex, ind in _GROUP_TYPES
    ])
    op.create_table(
        "animal_state_history",
        _id(), _fk("farm_id", "farms.id"), _fk("animal_id", "animals.id"),
        sa.Column("state_type", sa.String(40), nullable=False),
        sa.Column("value_code", sa.String(200), nullable=True),
        sa.Column("value_reference_id", sa.String(36), nullable=True),
        _ts("effective_from"), _ts("effective_to", nullable=True),
        sa.Column("reason_code", sa.String(80), nullable=True),
        sa.Column("source_type", sa.String(40), nullable=True),
        sa.Column("source_id", sa.String(36), nullable=True),
        _ts("recorded_at"),
        sa.Column("recorded_by", sa.String(36), nullable=True),
        sa.CheckConstraint("effective_to IS NULL OR effective_to >= effective_from", name="ck_animal_state_history_range"),
    )
    op.create_index("ix_animal_state_history_animal", "animal_state_history", ["animal_id", "state_type", "effective_from"])
    op.create_table(
        "animal_group_memberships",
        _id(), _fk("farm_id", "farms.id"), _fk("animal_group_id", "flocks.id"), _fk("animal_id", "animals.id"),
        _ts("valid_from"), _ts("valid_to", nullable=True),
        sa.Column("reason_code", sa.String(80), nullable=True),
        sa.Column("end_reason_code", sa.String(80), nullable=True),
        _ts("created_at"),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("ended_by", sa.String(36), nullable=True),
        sa.CheckConstraint("valid_to IS NULL OR valid_to >= valid_from", name="ck_animal_group_membership_range"),
    )
    op.create_index("ix_animal_group_memberships_group", "animal_group_memberships", ["animal_group_id", "valid_from"])
    op.create_index("ix_animal_group_memberships_animal", "animal_group_memberships", ["animal_id", "valid_from"])
    op.create_table(
        "animal_group_quantity_events",
        _id(), _fk("farm_id", "farms.id"), _fk("animal_group_id", "flocks.id"),
        sa.Column("event_type", sa.String(30), nullable=False),
        sa.Column("quantity_delta", sa.Integer(), nullable=False),
        sa.Column("resulting_quantity", sa.Integer(), nullable=False),
        _ts("occurred_at"),
        sa.Column("reason", sa.String(200), nullable=True),
        sa.Column("source_type", sa.String(40), nullable=True),
        sa.Column("source_id", sa.String(36), nullable=True),
        _ts("recorded_at"),
        sa.Column("recorded_by", sa.String(36), nullable=True),
        sa.Column("correlation_id", sa.String(36), nullable=True),
        sa.CheckConstraint("resulting_quantity >= 0", name="ck_animal_group_quantity_non_negative"),
    )
    op.create_index("ix_animal_group_quantity_events_group", "animal_group_quantity_events", ["animal_group_id", "occurred_at"])
    op.create_table(
        "animal_relationships",
        _id(), _fk("farm_id", "farms.id"), _fk("source_animal_id", "animals.id"), _fk("target_animal_id", "animals.id"),
        sa.Column("relationship_type", sa.String(30), nullable=False),
        sa.Column("confidence_code", sa.String(30), nullable=False),
        sa.Column("evidence_type", sa.String(40), nullable=True),
        sa.Column("evidence_id", sa.String(36), nullable=True),
        sa.Column("status", sa.String(20), nullable=False),
        _ts("created_at"),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.CheckConstraint("source_animal_id <> target_animal_id", name="ck_animal_relationship_not_self"),
    )
    op.create_index("ix_animal_relationships_source", "animal_relationships", ["source_animal_id", "relationship_type"])
    op.create_index("ix_animal_relationships_target", "animal_relationships", ["target_animal_id", "relationship_type"])

    # ------------------------------------------------------------ reproduction
    op.create_table(
        "breeding_events",
        _id(), _fk("farm_id", "farms.id"), _fk("female_animal_id", "animals.id"), _fk("male_animal_id", "animals.id", nullable=True),
        sa.Column("sire_reference", sa.String(120), nullable=True),
        sa.Column("event_type", sa.String(40), nullable=False),
        _ts("occurred_at"),
        sa.Column("semen_batch_reference", sa.String(120), nullable=True),
        sa.Column("technician_user_id", sa.String(36), nullable=True),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("void_reason", sa.String(200), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        _ts("recorded_at"),
        sa.Column("recorded_by", sa.String(36), nullable=True),
        sa.Column("correlation_id", sa.String(36), nullable=True),
    )
    op.create_index("ix_breeding_events_female", "breeding_events", ["female_animal_id", "occurred_at"])
    op.create_table(
        "pregnancy_episodes",
        _id(), _fk("farm_id", "farms.id"), _fk("animal_id", "animals.id"), _fk("originating_breeding_event_id", "breeding_events.id", nullable=True),
        sa.Column("status", sa.String(20), nullable=False),
        _ts("estimated_conception_at", nullable=True), _ts("expected_due_date", nullable=True), _ts("ended_at", nullable=True),
        sa.Column("outcome_code", sa.String(30), nullable=True),
        sa.Column("source", sa.String(20), nullable=False),
        sa.Column("notes", sa.Text(), nullable=True),
        _ts("created_at"), _ts("updated_at"),
        sa.Column("created_by", sa.String(36), nullable=True),
    )
    op.create_index("ix_pregnancy_episodes_animal", "pregnancy_episodes", ["animal_id", "status"])
    op.create_table(
        "pregnancy_assessments",
        _id(), _fk("farm_id", "farms.id"), _fk("pregnancy_episode_id", "pregnancy_episodes.id", nullable=True), _fk("animal_id", "animals.id"),
        _ts("assessed_at"),
        sa.Column("assessment_type", sa.String(30), nullable=False),
        sa.Column("result_code", sa.String(20), nullable=False),
        sa.Column("estimated_gestation_days", sa.Integer(), nullable=True),
        _ts("expected_due_date", nullable=True),
        sa.Column("examiner_user_id", sa.String(36), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        _ts("recorded_at"),
        sa.Column("recorded_by", sa.String(36), nullable=True),
    )
    op.create_index("ix_pregnancy_assessments_animal", "pregnancy_assessments", ["animal_id", "assessed_at"])
    op.create_table(
        "birth_events",
        _id(), _fk("farm_id", "farms.id"), _fk("dam_animal_id", "animals.id"),
        _fk("pregnancy_episode_id", "pregnancy_episodes.id", nullable=True), _fk("sire_animal_id", "animals.id", nullable=True),
        sa.Column("sire_reference", sa.String(120), nullable=True),
        _ts("occurred_at"),
        sa.Column("assistance_code", sa.String(20), nullable=False),
        sa.Column("offspring_count", sa.Integer(), nullable=False),
        sa.Column("live_count", sa.Integer(), nullable=False),
        sa.Column("stillborn_count", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("notes", sa.Text(), nullable=True),
        _ts("recorded_at"),
        sa.Column("recorded_by", sa.String(36), nullable=True),
        sa.CheckConstraint("offspring_count >= 0 AND live_count >= 0 AND stillborn_count >= 0", name="ck_birth_counts_non_negative"),
        sa.CheckConstraint("live_count + stillborn_count <= offspring_count", name="ck_birth_counts_add_up"),
    )
    op.create_index("ix_birth_events_dam", "birth_events", ["dam_animal_id", "occurred_at"])
    op.create_table(
        "birth_offspring",
        _id(), _fk("birth_event_id", "birth_events.id"), _fk("offspring_animal_id", "animals.id", nullable=True),
        sa.Column("sequence_no", sa.Integer(), nullable=False),
        sa.Column("sex", sa.String(5), nullable=True),
        sa.Column("birth_weight_kg", sa.Float(), nullable=True),
        sa.Column("outcome_code", sa.String(20), nullable=False),
        _fk("destination_group_id", "flocks.id", nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.UniqueConstraint("birth_event_id", "sequence_no", name="uq_birth_offspring_sequence"),
    )
    op.create_table(
        "lactation_episodes",
        _id(), _fk("farm_id", "farms.id"), _fk("animal_id", "animals.id"), _fk("birth_event_id", "birth_events.id", nullable=True),
        _ts("started_at"), _ts("ended_at", nullable=True),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("lactation_number", sa.Integer(), nullable=True),
        sa.Column("end_reason_code", sa.String(30), nullable=True),
        sa.Column("source", sa.String(20), nullable=False),
        _ts("created_at"),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("ended_by", sa.String(36), nullable=True),
        sa.CheckConstraint("ended_at IS NULL OR ended_at >= started_at", name="ck_lactation_range"),
    )
    op.create_index("ix_lactation_episodes_animal", "lactation_episodes", ["animal_id", "status"])
    op.create_table(
        "incubation_batches",
        _id(), _fk("farm_id", "farms.id"),
        sa.Column("species_code", sa.String(30), sa.ForeignKey("species.code"), nullable=False),
        _fk("source_group_id", "flocks.id", nullable=True),
        sa.Column("code", sa.String(60), nullable=False),
        sa.Column("eggs_set", sa.Integer(), nullable=False),
        _ts("set_at"), _ts("expected_hatch_date", nullable=True),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("notes", sa.Text(), nullable=True),
        _ts("created_at"),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.UniqueConstraint("farm_id", "code", name="uq_incubation_batch_code"),
        sa.CheckConstraint("eggs_set > 0", name="ck_incubation_eggs_set_positive"),
    )
    op.create_table(
        "hatch_events",
        _id(), _fk("incubation_batch_id", "incubation_batches.id"),
        _ts("occurred_at"),
        sa.Column("hatched_live", sa.Integer(), nullable=False),
        sa.Column("unhatched", sa.Integer(), nullable=True),
        sa.Column("culled", sa.Integer(), nullable=True),
        _fk("destination_group_id", "flocks.id", nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        _ts("recorded_at"),
        sa.Column("recorded_by", sa.String(36), nullable=True),
        sa.CheckConstraint("hatched_live >= 0", name="ck_hatch_live_non_negative"),
    )

    _backfill()


# ---------------------------------------------------------------- backfill
_species_t = sa.table("species", sa.column("code", sa.String), sa.column("reproduction_mode", sa.String),
                      sa.column("gestation_days", sa.Integer), sa.column("incubation_days", sa.Integer))
_animals_t = sa.table(
    "animals", sa.column("id", sa.String), sa.column("farm_id", sa.String), sa.column("species", sa.String), sa.column("sex", sa.String),
    sa.column("life_stage", sa.String), sa.column("management_profile", sa.String), sa.column("location_id", sa.String),
    sa.column("location_label", sa.String), sa.column("group_name", sa.String), sa.column("active", sa.Boolean),
    sa.column("pregnant", sa.Boolean), sa.column("pregnancy_days", sa.Integer), sa.column("lactating", sa.Boolean),
    sa.column("lactation_cycle", sa.Integer), sa.column("lactation_started_at", sa.DateTime(timezone=True)),
    sa.column("created_at", sa.DateTime(timezone=True)), sa.column("lifecycle_status", sa.String),
    sa.column("pregnancy_started_at", sa.DateTime(timezone=True)), sa.column("expected_due_date", sa.DateTime(timezone=True)),
)
_flocks_t = sa.table(
    "flocks", sa.column("id", sa.String), sa.column("farm_id", sa.String), sa.column("name", sa.String), sa.column("species", sa.String),
    sa.column("group_type", sa.String), sa.column("count", sa.Integer), sa.column("sex_composition", sa.String), sa.column("status", sa.String),
    sa.column("tracking_mode", sa.String), sa.column("created_at", sa.DateTime(timezone=True)),
)
_history_t = sa.table(
    "animal_state_history", sa.column("id", sa.String), sa.column("farm_id", sa.String), sa.column("animal_id", sa.String),
    sa.column("state_type", sa.String), sa.column("value_code", sa.String), sa.column("value_reference_id", sa.String),
    sa.column("effective_from", sa.DateTime(timezone=True)), sa.column("reason_code", sa.String), sa.column("source_type", sa.String),
    sa.column("recorded_at", sa.DateTime(timezone=True)), sa.column("recorded_by", sa.String),
)
_members_t = sa.table(
    "animal_group_memberships", sa.column("id", sa.String), sa.column("farm_id", sa.String), sa.column("animal_group_id", sa.String),
    sa.column("animal_id", sa.String), sa.column("valid_from", sa.DateTime(timezone=True)), sa.column("reason_code", sa.String),
    sa.column("created_at", sa.DateTime(timezone=True)), sa.column("created_by", sa.String),
)
_qty_t = sa.table(
    "animal_group_quantity_events", sa.column("id", sa.String), sa.column("farm_id", sa.String), sa.column("animal_group_id", sa.String),
    sa.column("event_type", sa.String), sa.column("quantity_delta", sa.Integer), sa.column("resulting_quantity", sa.Integer),
    sa.column("occurred_at", sa.DateTime(timezone=True)), sa.column("reason", sa.String), sa.column("source_type", sa.String),
    sa.column("recorded_at", sa.DateTime(timezone=True)), sa.column("recorded_by", sa.String),
)
_pregnancies_t = sa.table(
    "pregnancy_episodes", sa.column("id", sa.String), sa.column("farm_id", sa.String), sa.column("animal_id", sa.String),
    sa.column("status", sa.String), sa.column("estimated_conception_at", sa.DateTime(timezone=True)),
    sa.column("expected_due_date", sa.DateTime(timezone=True)), sa.column("source", sa.String),
    sa.column("created_at", sa.DateTime(timezone=True)), sa.column("updated_at", sa.DateTime(timezone=True)),
)
_lactations_t = sa.table(
    "lactation_episodes", sa.column("id", sa.String), sa.column("farm_id", sa.String), sa.column("animal_id", sa.String),
    sa.column("started_at", sa.DateTime(timezone=True)), sa.column("status", sa.String), sa.column("lactation_number", sa.Integer),
    sa.column("source", sa.String), sa.column("created_at", sa.DateTime(timezone=True)),
)


def _uid() -> str:
    return str(uuid.uuid4())


def _utc(value: datetime | None, default: datetime) -> datetime:
    if value is None:
        return default
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def _backfill() -> None:
    conn = op.get_bind()
    now = datetime.now(timezone.utc)

    for code, days in _GESTATION.items():
        conn.execute(_species_t.update().where(_species_t.c.code == code).values(gestation_days=days))
    for code, days in _INCUBATION.items():
        conn.execute(_species_t.update().where(_species_t.c.code == code).values(incubation_days=days))
    species = {r.code: r for r in conn.execute(sa.select(_species_t)).fetchall()}

    animals = conn.execute(sa.select(_animals_t)).fetchall()
    conn.execute(_animals_t.update().where(_animals_t.c.active == sa.false()).values(lifecycle_status="archived"))

    # Opening state history: what each animal was registered as.
    history = []
    for a in animals:
        since = _utc(a.created_at, now)
        opening = [("STATUS", "active" if a.active else "archived", None), ("LIFE_STAGE", a.life_stage, None),
                   ("MANAGEMENT_PROFILE", a.management_profile, None), ("LOCATION", a.location_label, a.location_id)]
        for state_type, value, ref in opening:
            if value is None and ref is None:
                continue
            history.append({"id": _uid(), "farm_id": a.farm_id, "animal_id": a.id, "state_type": state_type, "value_code": value,
                            "value_reference_id": ref, "effective_from": since, "reason_code": "opening_state", "source_type": _BACKFILL,
                            "recorded_at": now, "recorded_by": None})
    if history:
        op.bulk_insert(_history_t, history)

    # Groups: an existing flock, and a group for every free-text group name that named none.
    flocks = conn.execute(sa.select(_flocks_t)).fetchall()
    by_key = {(f.farm_id, f.species, (f.name or "").strip().lower()): f.id for f in flocks}
    members_of: dict[str, list] = {}
    new_groups: dict[tuple, dict] = {}
    for a in animals:
        name = (a.group_name or "").strip()
        if not name or not a.active:
            continue
        key = (a.farm_id, a.species, name.lower())
        if key not in by_key:
            mode = species.get(a.species).reproduction_mode if a.species in species else None
            group = new_groups.setdefault(key, {
                "id": _uid(), "farm_id": a.farm_id, "name": name, "species": a.species,
                "group_type": "flock" if mode == "oviparous" else "herd", "count": 0, "sex_composition": None,
                "status": "healthy", "tracking_mode": "MEMBERSHIP_DERIVED", "created_at": now, "_sexes": set(),
            })
            by_key[key] = group["id"]
        group_id = by_key[key]
        members_of.setdefault(group_id, []).append(a)
        if key in new_groups:
            new_groups[key]["count"] += 1
            new_groups[key]["_sexes"].add(a.sex)
    for g in new_groups.values():
        sexes = g.pop("_sexes")
        g["sex_composition"] = "female" if sexes == {"F"} else ("male" if sexes == {"M"} else "mixed")
    if new_groups:
        op.bulk_insert(_flocks_t, list(new_groups.values()))

    for f in flocks:
        mode = "HYBRID" if members_of.get(f.id) else "QUANTITY_MANAGED"
        conn.execute(_flocks_t.update().where(_flocks_t.c.id == f.id).values(tracking_mode=mode))
    quantity = [
        {"id": _uid(), "farm_id": f.farm_id, "animal_group_id": f.id, "event_type": "INITIAL_COUNT", "quantity_delta": f.count,
         "resulting_quantity": f.count, "occurred_at": _utc(f.created_at, now), "reason": "Opening count", "source_type": _BACKFILL,
         "recorded_at": now, "recorded_by": None}
        for f in flocks if (f.count or 0) > 0
    ]
    if quantity:
        op.bulk_insert(_qty_t, quantity)

    memberships = [
        {"id": _uid(), "farm_id": a.farm_id, "animal_group_id": group_id, "animal_id": a.id, "valid_from": _utc(a.created_at, now),
         "reason_code": "opening_state", "created_at": now, "created_by": None}
        for group_id, members in members_of.items() for a in members
    ]
    if memberships:
        op.bulk_insert(_members_t, memberships)

    # Reproduction and lactation: the flags become the episodes they stood for.
    pregnancies, lactations = [], []
    for a in animals:
        if not a.active:
            continue
        if a.pregnant:
            conceived = now - timedelta(days=a.pregnancy_days) if a.pregnancy_days is not None else None
            gestation = species[a.species].gestation_days if a.species in species else None
            due = conceived + timedelta(days=gestation) if conceived is not None and gestation else None
            pregnancies.append({"id": _uid(), "farm_id": a.farm_id, "animal_id": a.id, "status": "active", "estimated_conception_at": conceived,
                                "expected_due_date": due, "source": _BACKFILL, "created_at": now, "updated_at": now})
            conn.execute(_animals_t.update().where(_animals_t.c.id == a.id).values(pregnancy_started_at=conceived, expected_due_date=due))
        if a.lactating:
            started = _utc(a.lactation_started_at, _utc(a.created_at, now))
            lactations.append({"id": _uid(), "farm_id": a.farm_id, "animal_id": a.id, "started_at": started, "status": "active",
                               "lactation_number": a.lactation_cycle, "source": _BACKFILL, "created_at": now})
            if a.lactation_started_at is None:
                conn.execute(_animals_t.update().where(_animals_t.c.id == a.id).values(lactation_started_at=started))
    if pregnancies:
        op.bulk_insert(_pregnancies_t, pregnancies)
    if lactations:
        op.bulk_insert(_lactations_t, lactations)


def downgrade() -> None:
    for table in ("hatch_events", "incubation_batches", "lactation_episodes", "birth_offspring", "birth_events",
                  "pregnancy_assessments", "pregnancy_episodes", "breeding_events", "animal_relationships",
                  "animal_group_quantity_events", "animal_group_memberships", "animal_state_history", "animal_group_type_policies"):
        op.drop_table(table)
    with op.batch_alter_table("flocks") as b:
        b.drop_column("created_at")
        b.drop_column("tracking_mode")
    with op.batch_alter_table("animals") as b:
        b.drop_column("expected_due_date")
        b.drop_column("pregnancy_started_at")
        b.drop_column("exited_at")
        b.drop_column("lifecycle_status")
    with op.batch_alter_table("species") as b:
        b.drop_column("incubation_days")
        b.drop_column("gestation_days")
