"""Least-cost formulation drafts (master prompt Package 12) on a real PostgreSQL 16.

The same tests as tests/test_least_cost_formulation.py — three drafts at
today's prices, limits, infeasible and insufficient data, other species and
blocked premixes, approval as a draft formula version, prices that never
rewrite a run or a batch, roles, farms and retries — on PostgreSQL, through
the API. And a real race: two managers approving drafts of the same run at
once; the run's row lock lets one through, the other is told.
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
from app.domain import feed_models as fm
from app.domain import models
from app.domain.registry import import_all
from app.main import app
from app.seed import seed_demo_data
from app.services import least_cost_service as lcf
from app.services.nutrition_service import NutritionError
from tests import test_least_cost_formulation as lc
from tests.test_nutrition_assessment import farm_mix  # noqa: F401 - the same fixture, on PostgreSQL

pytestmark = pytest.mark.skipif(not os.environ.get("FARMOS_TEST_POSTGRES_URL"), reason="needs FARMOS_TEST_POSTGRES_URL (PostgreSQL 16)")


@pytest.fixture()
def db_session():
    import_all()
    url = normalize_database_url(os.environ["FARMOS_TEST_POSTGRES_URL"])
    schema = f"leastcost_{uuid.uuid4().hex[:10]}"
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


class TestDraftsOnPostgres(lc.TestDrafts):
    pass


class TestNothingIsGuessedOnPostgres(lc.TestNothingIsGuessed):
    pass


class TestApprovalAndHistoryOnPostgres(lc.TestApprovalAndHistory):
    pass


def test_two_managers_approving_the_same_run_at_once_approve_it_once(client, db_session, farm_mix):  # noqa: F811
    _, factory = db_session
    rs = lc._ready(client, farm_mix)
    run_id = lc._run(client, farm_mix, rs["id"]).json()["id"]
    barrier = threading.Barrier(2)
    outcomes: list = []
    lock = threading.Lock()

    def approve(draft: str) -> None:
        with factory() as db:
            try:
                user = db.scalar(select(models.User).where(models.User.email == "rami@origami.farm"))
                stale = lcf.get_run(db, run_id, user.farm_id)  # read before the race and held
                assert stale.approved_draft is None
                barrier.wait(timeout=10)
                lcf.approve(db, user, stale, draft_key=draft, note=f"Approved {draft}")
                time.sleep(1.0)  # hold the transaction open while the other decides
                db.commit()
                result = ("ok", draft)
            except NutritionError as exc:
                db.rollback()
                result = ("refused", exc.message)
            except Exception as exc:  # noqa: BLE001 - a thread that dies fails the test with its reason
                db.rollback()
                result = ("error", repr(exc))
        with lock:
            outcomes.append(result)

    threads = [threading.Thread(target=approve, args=(d,)) for d in ("A", "C")]
    for th in threads:
        th.start()
    for th in threads:
        th.join(timeout=30)
    assert sorted(o[0] for o in outcomes) == ["ok", "refused"], outcomes
    with factory() as db:
        versions = db.scalars(select(fm.FeedFormulaVersion).where(fm.FeedFormulaVersion.formula_id == farm_mix["formula"]["id"])).all()
        assert sorted((v.version, v.status) for v in versions) == [(1, "active"), (2, "draft")]
        assert db.scalar(select(func.count(models.AuditLog.id)).where(models.AuditLog.action == "least_cost_draft_approved")) == 1
