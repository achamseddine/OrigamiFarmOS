"""Migration b5e7a9c1d3f8 on a database that already holds a farm.

test_migrations.py proves the schema; this proves the data: a database at
the previous revision, with the flags and free-text herd names the old
model used, comes out of the upgrade with the records those flags stood
for — and the old values unchanged. SQLite always; PostgreSQL too when
FARMOS_TEST_POSTGRES_URL names a disposable database.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import sqlalchemy as sa

from tests.test_migrations import _alembic, database_url  # noqa: F401 - the fixture is used by name

PREVIOUS = "a7c9e1f3b5d7"
NOW = datetime.now(timezone.utc)

_farms = sa.table("farms", *(sa.column(c) for c in ("id", "name", "country", "region", "timezone", "default_currency")),
                  sa.column("created_at", sa.DateTime(timezone=True)))
_animals = sa.table(
    "animals", *(sa.column(c) for c in ("id", "farm_id", "name", "species", "sex", "status", "health_score", "life_stage",
                                        "management_profile", "location_label", "group_name", "pregnancy_days", "lactation_cycle")),
    sa.column("birth_date_estimated", sa.Boolean), sa.column("pregnant", sa.Boolean), sa.column("lactating", sa.Boolean),
    sa.column("active", sa.Boolean), sa.column("created_at", sa.DateTime(timezone=True)), sa.column("updated_at", sa.DateTime(timezone=True)),
    sa.column("lactation_started_at", sa.DateTime(timezone=True)),
)
_flocks = sa.table("flocks", *(sa.column(c) for c in ("id", "farm_id", "name", "species", "group_type", "count", "status", "sex_composition")))


def _animal(id_, name, species, **kw):
    row = {"id": id_, "farm_id": "f1", "name": name, "species": species, "sex": "F", "status": "healthy", "health_score": 100,
           "life_stage": "adult", "management_profile": None, "location_label": None, "group_name": None, "pregnancy_days": None,
           "lactation_cycle": None, "birth_date_estimated": False, "pregnant": False, "lactating": False, "active": True,
           "created_at": NOW - timedelta(days=400), "updated_at": NOW, "lactation_started_at": None}
    row.update(kw)
    return row


def test_existing_flags_and_herds_become_records(database_url: str):  # noqa: F811 - pytest fixture
    _alembic(database_url, "upgrade", PREVIOUS)
    engine = sa.create_engine(database_url)
    try:
        with engine.begin() as conn:
            conn.execute(_farms.insert().values(id="f1", name="Old farm", country="LB", region="Bekaa", timezone="Asia/Beirut",
                                                default_currency="USD", created_at=NOW))
            conn.execute(_flocks.insert().values(id="fl1", farm_id="f1", name="Hens", species="layer_hen", group_type="flock", count=300,
                                                 status="healthy", sex_composition="female"))
            conn.execute(_flocks.insert().values(id="fl2", farm_id="f1", name="Ducks", species="duck", group_type="flock", count=0, status="healthy"))
            conn.execute(_animals.insert(), [
                _animal("a1", "Sara", "cow", management_profile="dairy", location_label="Barn", group_name="Old Herd", pregnant=True,
                        pregnancy_days=100, lactating=True, lactation_cycle=2, lactation_started_at=NOW - timedelta(days=150)),
                _animal("a2", "Mona", "cow", group_name="old herd"),
                _animal("a3", "Hen 1", "layer_hen", life_stage="adult", group_name="Hens"),
                _animal("a4", "Gone", "goat", active=False, group_name="Old Herd"),
            ])
        _alembic(database_url, "upgrade", "head")
        with engine.connect() as conn:
            q = lambda sql, **p: conn.execute(sa.text(sql), p).fetchall()  # noqa: E731

            assert q("SELECT gestation_days FROM species WHERE code = 'cow'")[0][0] == 283
            assert q("SELECT incubation_days FROM species WHERE code = 'duck'")[0][0] == 28

            # Opening history for every animal; an archived one opens archived.
            assert {r[0] for r in q("SELECT state_type FROM animal_state_history WHERE animal_id = 'a1'")} == {
                "STATUS", "LIFE_STAGE", "MANAGEMENT_PROFILE", "LOCATION"}
            assert q("SELECT lifecycle_status FROM animals WHERE id = 'a4'")[0][0] == "archived"
            assert q("SELECT value_code FROM animal_state_history WHERE animal_id = 'a4' AND state_type = 'STATUS'")[0][0] == "archived"

            # The free-text herd is a group of its species, the existing flock hybrid.
            herds = q("SELECT id, tracking_mode, count, group_type FROM flocks WHERE name = 'Old Herd'")
            assert len(herds) == 1 and herds[0][1:] == ("MEMBERSHIP_DERIVED", 2, "herd"), "both cows, not the archived goat"
            members = {r[0] for r in q("SELECT animal_id FROM animal_group_memberships WHERE animal_group_id = :g AND valid_to IS NULL", g=herds[0][0])}
            assert members == {"a1", "a2"}
            assert q("SELECT tracking_mode FROM flocks WHERE id = 'fl1'")[0][0] == "HYBRID"
            assert q("SELECT tracking_mode FROM flocks WHERE id = 'fl2'")[0][0] == "QUANTITY_MANAGED"
            assert q("SELECT event_type, resulting_quantity FROM animal_group_quantity_events WHERE animal_group_id = 'fl1'") == [("INITIAL_COUNT", 300)]
            assert q("SELECT count(*) FROM animal_group_quantity_events WHERE animal_group_id = 'fl2'")[0][0] == 0
            assert q("SELECT animal_id FROM animal_group_memberships WHERE animal_group_id = 'fl1'") == [("a3",)]

            # The flags became the episodes they stood for, the flags untouched.
            pregnancy = q("SELECT status, source, estimated_conception_at, expected_due_date FROM pregnancy_episodes WHERE animal_id = 'a1'")
            assert len(pregnancy) == 1 and pregnancy[0][:2] == ("active", "backfill") and pregnancy[0][2] is not None and pregnancy[0][3] is not None
            lactation = q("SELECT status, lactation_number FROM lactation_episodes WHERE animal_id = 'a1'")
            assert lactation == [("active", 2)]
            assert q("SELECT pregnant, lactating, group_name FROM animals WHERE id = 'a1'")[0] in ((True, True, "Old Herd"), (1, 1, "Old Herd"))
            assert q("SELECT count(*) FROM pregnancy_episodes WHERE animal_id = 'a4'")[0][0] == 0
        # And back: the new tables go, the old data stays readable by the old schema.
        _alembic(database_url, "downgrade", PREVIOUS)
        with engine.connect() as conn:
            assert "animal_group_memberships" not in sa.inspect(conn).get_table_names()
            assert conn.execute(sa.text("SELECT count(*) FROM animals")).scalar() == 4
    finally:
        engine.dispose()
