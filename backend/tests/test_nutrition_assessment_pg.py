"""Nutrient requirements and formula assessments (master prompt Package 11) on a real PostgreSQL 16.

The same tests as tests/test_nutrition_assessment.py — the 1,210 kg base
concentrate and its premix, insufficient data, dry matter, versioned
requirement sets with their source, species, roles and farms — against the
demo farm seeded in PostgreSQL, through the API (JSON results included).
And a real race: two managers revising the same requirement set at once;
the latest version's row lock lets one make version 2 and tells the other.

Runs when FARMOS_TEST_POSTGRES_URL names a disposable PostgreSQL database;
each test works in a schema of its own, so parallel workers never meet.
"""
from __future__ import annotations

import os
import threading
import time
import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, select, text
from sqlalchemy.orm import sessionmaker

from app.core.config import normalize_database_url
from app.db.base import Base, get_db
from app.domain import models
from app.domain import nutrition_models as nm
from app.domain.registry import import_all
from app.main import app
from app.seed import seed_demo_data
from app.services import nutrition_service as nut
from tests import test_nutrition_assessment as na
from tests.test_nutrition_assessment import farm_mix  # noqa: F401 - the same fixture, on PostgreSQL

pytestmark = pytest.mark.skipif(not os.environ.get("FARMOS_TEST_POSTGRES_URL"), reason="needs FARMOS_TEST_POSTGRES_URL (PostgreSQL 16)")


@pytest.fixture()
def db_session():
    import_all()
    url = normalize_database_url(os.environ["FARMOS_TEST_POSTGRES_URL"])
    schema = f"nutrition_{uuid.uuid4().hex[:10]}"
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


class TestTheBaseConcentrateOnPostgres(na.TestTheBaseConcentrate):
    pass


class TestDryMatterOnPostgres(na.TestDryMatter):
    pass


class TestRequirementSetsOnPostgres(na.TestRequirementSets):
    pass


class TestWhoAndWhichFarmOnPostgres(na.TestWhoAndWhichFarm):
    pass


def test_two_managers_revising_the_same_requirements_at_once_make_one_version(client, db_session):
    _, factory = db_session
    v1 = na._requirements(client).json()
    barrier = threading.Barrier(2)
    outcomes: list = []
    lock = threading.Lock()

    def revise(note: str) -> None:
        with factory() as db:
            try:
                user = db.scalar(select(models.User).where(models.User.email == "rami@origami.farm"))
                stale = nut.get_set(db, v1["id"], user.farm_id)  # read before the race and held
                assert stale.status == "active"
                barrier.wait(timeout=10)
                nut.new_version(db, user, stale, source_reference=f"Nutritionist revision: {note}",
                                values=[{"nutrient_code": "CP", "min_value": 16.5, "max_value": 18.0}])
                time.sleep(1.0)  # hold the transaction open while the other decides
                db.commit()
                result = ("ok", note)
            except nut.NutritionError as exc:
                db.rollback()
                result = ("refused", exc.message)
            except Exception as exc:  # noqa: BLE001 - a thread that dies fails the test with its reason
                db.rollback()
                result = ("error", repr(exc))
        with lock:
            outcomes.append(result)

    threads = [threading.Thread(target=revise, args=(n,)) for n in ("first", "second")]
    for th in threads:
        th.start()
    for th in threads:
        th.join(timeout=30)
    assert sorted(o[0] for o in outcomes) == ["ok", "refused"], outcomes
    with factory() as db:
        rows = db.scalars(select(nm.NutritionRequirementSet).where(nm.NutritionRequirementSet.code == "DAIRY-EARLY")).all()
        assert sorted((r.version, r.status) for r in rows) == [(1, "retired"), (2, "active")]
        assert db.scalar(select(func.count(nm.NutritionRequirementValue.id))) == len(v1["values"]) + 1
