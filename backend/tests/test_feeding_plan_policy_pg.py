"""The feeding policy of v0.8.6 (ADR-006) on a real PostgreSQL 16 server.

The same tests as tests/test_feeding_plan_policy.py — AF-01 (one base
ration per head), AF-05 (a refusal is not fed), NEW-6 (the farm's day in
Beirut, daylight saving, past days) — run against the demo farm seeded in
PostgreSQL, through the API. On PostgreSQL every time is a `timestamptz`
and the day bounds are compared on the server, which SQLite (naive text
timestamps) cannot show.

Runs when FARMOS_TEST_POSTGRES_URL names a disposable PostgreSQL database;
each test works in a schema of its own, so parallel workers never meet.
"""
from __future__ import annotations

import os
import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker

from app.core.config import normalize_database_url
from app.db.base import Base, get_db
from app.domain.registry import import_all
from app.main import app
from app.seed import seed_demo_data
from tests import test_feeding_plan_policy as policy

pytestmark = pytest.mark.skipif(not os.environ.get("FARMOS_TEST_POSTGRES_URL"), reason="needs FARMOS_TEST_POSTGRES_URL (PostgreSQL 16)")


@pytest.fixture()
def db_session():
    import_all()
    url = normalize_database_url(os.environ["FARMOS_TEST_POSTGRES_URL"])
    schema = f"feeding_policy_{uuid.uuid4().hex[:10]}"
    admin = create_engine(url)
    with admin.begin() as conn:
        conn.execute(text(f"CREATE SCHEMA {schema}"))
    admin.dispose()
    engine = create_engine(url, connect_args={"options": f"-csearch_path={schema}"}, pool_size=4)
    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, autocommit=False, autoflush=False)
    session = factory()
    seed_demo_data(session)
    session.commit()
    try:
        yield session, factory
    finally:
        session.close()
        engine.dispose()
        admin = create_engine(url)
        with admin.begin() as conn:
            conn.execute(text(f"DROP SCHEMA IF EXISTS {schema} CASCADE"))
        admin.dispose()


@pytest.fixture()
def client(db_session):
    _session, factory = db_session

    def _override_get_db():
        db = factory()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = _override_get_db
    app.state.idempotency_session_factory = factory
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.clear()
    app.state.idempotency_session_factory = None


class TestOneBaseAllowancePerHeadOnPostgres(policy.TestOneBaseAllowancePerHead):
    pass


class TestOnlyStockMovingFeedIsFedOnPostgres(policy.TestOnlyStockMovingFeedIsFed):
    pass


class TestFarmDaysOnPostgres(policy.TestFarmDays):
    pass
