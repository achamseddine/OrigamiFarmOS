"""Milk entered offline, cleared by the server (audit I-11, I-16; ADR-008)
on a real PostgreSQL 16.

The same tests as tests/test_offline_milk_clearance.py — tablet A's 10 L
under the withdrawal tablet B recorded, kept but held, out of the tank,
the collector's handover and every sale; the review that cannot release
it; one record however often the replay comes; clear milk counting as a
live entry's; a milking she cannot have given still refused; the other
order of the two tablets; the farm's clock with its daylight-saving
changes; the older batch push — against the demo farm seeded in
PostgreSQL, where the times are `timestamptz`.

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
from tests import test_offline_milk_clearance as offline

pytestmark = pytest.mark.skipif(not os.environ.get("FARMOS_TEST_POSTGRES_URL"), reason="needs FARMOS_TEST_POSTGRES_URL (PostgreSQL 16)")


@pytest.fixture()
def db_session():
    import_all()
    url = normalize_database_url(os.environ["FARMOS_TEST_POSTGRES_URL"])
    schema = f"offline_milk_{uuid.uuid4().hex[:10]}"
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


class TestTheMandatoryScenarioOnPostgres(offline.TestTheMandatoryScenario):
    pass


class TestEveryOtherAnswerOnPostgres(offline.TestEveryOtherAnswer):
    pass


class TestTheFarmsClockOnPostgres(offline.TestTheFarmsClock):
    pass


class TestTheOlderSyncPushOnPostgres(offline.TestTheOlderSyncPush):
    pass
