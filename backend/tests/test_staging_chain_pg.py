"""The staging chain on a real PostgreSQL 16 (master prompt Package 6,
docs/runbooks/STAGING-POSTGRES.md), the way scripts/staging/staging.sh runs
it, in one test the suite and CI can run:

  an empty database → every migration (the real `alembic upgrade head`) →
  the synthetic demo farm → the API smoke tests (health, contract, sign-in,
  access, idempotent writes of money, milk and feed stock, reads, refusals,
  the reconciliations' dry runs) → `pg_dump` → `pg_restore` into a second
  database → identical table by table (row counts and row checksums) and at
  the head revision → the API on the restored copy finds every record the
  smoke test made → a new connection pool ("restart") finds them too → the
  feed stock check reports every product consistent.

Runs when FARMOS_TEST_POSTGRES_URL names a disposable PostgreSQL server
(its role creates two databases of its own and drops them afterwards).
`pg_dump` and `pg_restore` must be the server's major version or newer.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import sessionmaker

from app.core.config import normalize_database_url
from app.db.base import get_db
from app.domain.registry import import_all
from app.main import app
from app.seed import seed_demo_data
from app.staging import smoke, snapshot

pytestmark = pytest.mark.skipif(not os.environ.get("FARMOS_TEST_POSTGRES_URL"), reason="needs FARMOS_TEST_POSTGRES_URL (PostgreSQL 16)")

BACKEND_DIR = Path(__file__).resolve().parents[1]


def _url(name: str) -> str:
    return make_url(normalize_database_url(os.environ["FARMOS_TEST_POSTGRES_URL"])).set(database=name).render_as_string(hide_password=False)


def _libpq(url: str) -> str:
    """The same database as a plain libpq URL, for pg_dump and pg_restore."""
    return url.replace("postgresql+psycopg2://", "postgresql://", 1)


def _run(*args: str, env: dict | None = None) -> subprocess.CompletedProcess:
    proc = subprocess.run(list(args), cwd=BACKEND_DIR, env={**os.environ, "FARMOS_SCHEDULER": "false", **(env or {})},
                          capture_output=True, text=True, timeout=900)
    assert proc.returncode == 0, f"{' '.join(args[:4])} failed:\n{proc.stdout[-3000:]}\n{proc.stderr[-3000:]}"
    return proc


def _server_major(url: str) -> int:
    engine = create_engine(url)
    try:
        with engine.connect() as conn:
            return int(conn.execute(text("SHOW server_version_num")).scalar()) // 10000
    finally:
        engine.dispose()


def _tool_major(tool: str) -> int:
    out = subprocess.run([tool, "--version"], capture_output=True, text=True).stdout  # "pg_dump (PostgreSQL) 16.15 ..."
    return int(out.split(")")[1].strip().split(".")[0])


@pytest.fixture()
def databases():
    import_all()
    suffix = uuid.uuid4().hex[:8]
    names = (f"origami_staging_{suffix}", f"origami_staging_restore_{suffix}")
    admin = create_engine(normalize_database_url(os.environ["FARMOS_TEST_POSTGRES_URL"]), isolation_level="AUTOCOMMIT")
    with admin.connect() as conn:
        for n in names:
            conn.execute(text(f"CREATE DATABASE {n}"))
    try:
        yield tuple(_url(n) for n in names)
    finally:
        with admin.connect() as conn:
            for n in names:
                conn.execute(text("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :n AND pid <> pg_backend_pid()"), {"n": n})
                conn.execute(text(f"DROP DATABASE IF EXISTS {n}"))
        admin.dispose()


class _Api:
    """The application on one database, as the staging server runs it."""

    def __init__(self, url: str):
        self.engine = create_engine(url, pool_size=4)
        self.factory = sessionmaker(bind=self.engine, autocommit=False, autoflush=False)

    def __enter__(self) -> TestClient:
        def _db():
            db = self.factory()
            try:
                yield db
            finally:
                db.close()

        app.dependency_overrides[get_db] = _db
        app.state.idempotency_session_factory = self.factory
        self.client = TestClient(app)
        return self.client.__enter__()

    def __exit__(self, *exc):
        self.client.__exit__(*exc)
        app.dependency_overrides.clear()
        app.state.idempotency_session_factory = None
        self.engine.dispose()


def test_migrate_seed_smoke_backup_restore_restart_reconcile(databases, tmp_path):
    staging, restored = databases

    # Every migration, from an empty database, to the head revision.
    _run(sys.executable, "-m", "alembic", "-c", "alembic.ini", "upgrade", "head", env={"DATABASE_URL": staging})
    heads = _run(sys.executable, "-m", "alembic", "-c", "alembic.ini", "heads", env={"DATABASE_URL": staging}).stdout.split()[0]
    current = _run(sys.executable, "-m", "alembic", "-c", "alembic.ini", "current", env={"DATABASE_URL": staging}).stdout.split()[0]
    assert current == heads

    # The synthetic farm, on the migrated schema.
    engine = create_engine(staging)
    with sessionmaker(bind=engine, autoflush=False)() as db:
        seed_demo_data(db)
        db.commit()
    engine.dispose()

    with _Api(staging) as client:
        report = smoke.run(client, "/api/v1")
    failed = [c for c in report.checks if c["result"] == "FAIL"]
    assert not failed, failed
    assert {"expense_id", "milk_record_id", "feed_lot_id"} <= report.state.keys()

    # A backup, and a restore into a second database: identical.
    if not (shutil.which("pg_dump") and shutil.which("pg_restore")):
        pytest.skip("pg_dump / pg_restore are not installed")
    if min(_tool_major("pg_dump"), _tool_major("pg_restore")) < _server_major(staging):
        pytest.skip("pg_dump / pg_restore are older than the server")
    dump = tmp_path / "staging.dump"
    _run("pg_dump", "--format=custom", "--no-owner", f"--file={dump}", f"--dbname={_libpq(staging)}")
    before = snapshot.take(staging)
    _run("pg_restore", "--no-owner", "--exit-on-error", f"--dbname={_libpq(restored)}", str(dump))
    after = snapshot.take(restored)
    assert snapshot.differences(before, after) == []
    assert after["alembic"] == [heads]
    assert sum(t["rows"] for t in after["tables"].values()) > 500, "the synthetic farm and the smoke test's records"

    with _Api(restored) as client:
        found = smoke.verify_state(client, "/api/v1", report.state)
    assert found.passed, found.checks

    # A new connection pool on the staging database: what a restart sees.
    with _Api(staging) as client:
        again = smoke.verify_state(client, "/api/v1", report.state)
    assert again.passed, again.checks

    # The feed stock reconciliation's dry run: every product consistent.
    _run(sys.executable, "-m", "app.feed_stock_integrity", "--json", env={"DATABASE_URL": staging})

