"""The Alembic chain and the ORM are one schema.

Runs the real `alembic` command (a subprocess, because the application's
Settings read DATABASE_URL once at import) against a throwaway database:
upgrade to head, compare every table with what the models declare —
columns, nullability, types, primary and foreign keys, indexes, unique
constraints — seed the demo farm onto the migrated schema, downgrade all
the way to the beginning, and upgrade again. SQLite always; PostgreSQL too
when FARMOS_TEST_POSTGRES_URL names a disposable database (CI does this
with a service container; the schema there is dropped and recreated).
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest
from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.orm import sessionmaker

from app.core.config import normalize_database_url
from app.db.base import Base
from app.domain.registry import import_all

BACKEND_DIR = Path(__file__).resolve().parents[1]
ALEMBIC_INI = BACKEND_DIR / "alembic.ini"


def _alembic(url: str, *args: str) -> subprocess.CompletedProcess:
    env = {**os.environ, "DATABASE_URL": url, "FARMOS_SCHEDULER": "false"}
    proc = subprocess.run([sys.executable, "-m", "alembic", "-c", str(ALEMBIC_INI), *args], cwd=BACKEND_DIR, env=env,
                          capture_output=True, text=True, timeout=600)
    assert proc.returncode == 0, f"alembic {' '.join(args)} failed:\n{proc.stdout}\n{proc.stderr}"
    return proc


def _urls() -> list[str]:
    urls = ["sqlite"]
    if os.environ.get("FARMOS_TEST_POSTGRES_URL"):
        urls.append("postgresql")
    return urls


@pytest.fixture(params=_urls())
def database_url(request, tmp_path) -> str:
    if request.param == "sqlite":
        return f"sqlite:///{tmp_path / 'migrated.db'}"
    # A bare postgresql:// URL, as a deployment would set it; the driver pin is the application's job.
    url = normalize_database_url(os.environ["FARMOS_TEST_POSTGRES_URL"])
    engine = create_engine(url)
    with engine.begin() as conn:
        conn.execute(text("DROP SCHEMA public CASCADE"))
        conn.execute(text("CREATE SCHEMA public"))
    engine.dispose()
    return url


def _shape(inspector, table: str, schema: str | None = None) -> dict:
    cols = {c["name"]: (bool(c["nullable"]), str(c["type"]).upper()) for c in inspector.get_columns(table, schema=schema)}
    return {
        "columns": cols,
        "pk": tuple(inspector.get_pk_constraint(table, schema=schema)["constrained_columns"]),
        # Referred tables by bare name: on PostgreSQL the reference copy lives in another schema.
        "fks": {(tuple(f["constrained_columns"]), f["referred_table"], tuple(f["referred_columns"])) for f in inspector.get_foreign_keys(table, schema=schema)},
        "indexes": {i["name"]: (tuple(i["column_names"]), bool(i["unique"])) for i in inspector.get_indexes(table, schema=schema)},
        "uniques": {tuple(u["column_names"]) for u in inspector.get_unique_constraints(table, schema=schema)},
    }


def _compare(migrated_inspector, reference_inspector, tables: set[str], reference_schema: str | None = None) -> list[str]:
    mismatches = []
    for table in sorted(tables):
        a, b = _shape(migrated_inspector, table), _shape(reference_inspector, table, schema=reference_schema)
        for key in a:
            if a[key] != b[key]:
                mismatches.append(f"{table}.{key}: migrated={a[key]} orm={b[key]}")
    return mismatches


def test_the_migration_chain_has_one_head():
    script = ScriptDirectory.from_config(Config(str(ALEMBIC_INI)))
    heads = script.get_heads()
    assert len(heads) == 1, f"the migration history forks: {heads}"
    revisions = list(script.walk_revisions())
    assert len(revisions) >= 10 and all(r.down_revision is not None or r is revisions[-1] for r in revisions)


def test_upgrade_matches_the_orm_then_seeds_then_round_trips(database_url: str):
    import_all()
    _alembic(database_url, "upgrade", "head")

    migrated = create_engine(database_url)
    reference_url = "sqlite://" if database_url.startswith("sqlite") else database_url
    try:
        inspector = inspect(migrated)
        tables = set(inspector.get_table_names()) - {"alembic_version"}
        assert "alembic_version" in inspector.get_table_names()
        assert tables == set(Base.metadata.tables), f"tables only in migrations: {tables - set(Base.metadata.tables)}; only in ORM: {set(Base.metadata.tables) - tables}"

        if reference_url == "sqlite://":
            # The reference is `create_all` into an in-memory SQLite database.
            reference = create_engine(reference_url)
            Base.metadata.create_all(reference)
            mismatches = _compare(inspector, inspect(reference), tables)
            reference.dispose()
        else:
            # On PostgreSQL the reference is `create_all` into a second schema of the same database.
            with migrated.begin() as conn:
                conn.execute(text("DROP SCHEMA IF EXISTS orm_reference CASCADE"))
                conn.execute(text("CREATE SCHEMA orm_reference"))
            ref_engine = create_engine(database_url, execution_options={"schema_translate_map": {None: "orm_reference"}})
            Base.metadata.create_all(ref_engine)
            mismatches = _compare(inspector, inspect(ref_engine), tables, reference_schema="orm_reference")
            ref_engine.dispose()
            with migrated.begin() as conn:
                conn.execute(text("DROP SCHEMA orm_reference CASCADE"))
        assert not mismatches, "migrations and ORM disagree:\n" + "\n".join(mismatches)

        # The reference rows the application expects are there, and the demo farm seeds onto the migrated schema.
        with migrated.connect() as conn:
            assert conn.execute(text("SELECT count(*) FROM units_of_measure")).scalar() >= 20
            assert conn.execute(text("SELECT count(*) FROM species")).scalar() >= 5
            assert conn.execute(text("SELECT count(*) FROM medicine_categories")).scalar() >= 5
        from app.seed import seed_demo_data

        session = sessionmaker(bind=migrated)()
        try:
            seed_demo_data(session)
            session.commit()
            assert session.execute(text("SELECT count(*) FROM animals")).scalar() > 0
            assert session.execute(text("SELECT count(*) FROM feed_batches WHERE mix_number IS NOT NULL")).scalar() > 0
        finally:
            session.close()
    finally:
        migrated.dispose()

    _alembic(database_url, "downgrade", "base")
    bare = create_engine(database_url)
    try:
        assert set(inspect(bare).get_table_names()) <= {"alembic_version"}, "downgrade to base leaves tables behind"
    finally:
        bare.dispose()
    _alembic(database_url, "upgrade", "head")
    again = create_engine(database_url)
    try:
        assert set(inspect(again).get_table_names()) - {"alembic_version"} == set(Base.metadata.tables)
    finally:
        again.dispose()
