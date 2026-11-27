"""Feed performance actions and their measured outcomes (master prompt Package 13) on a real PostgreSQL 16.

The same tests as tests/test_feed_actions.py — an action on the alert,
measured once as expected, a health event lowering the confidence, the
opposite outcome, too few records, the daily cycle measuring once, rules,
roles and farms — on PostgreSQL. And a real race: two managers recording an
action on the same alert at once; the alert's row lock lets one through.
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
from app.domain import feed_action_models as am
from app.domain import models
from app.domain.registry import import_all
from app.main import app
from app.seed import seed_demo_data
from app.services import feed_action_service as actions
from tests import test_feed_actions as fa

pytestmark = pytest.mark.skipif(not os.environ.get("FARMOS_TEST_POSTGRES_URL"), reason="needs FARMOS_TEST_POSTGRES_URL (PostgreSQL 16)")


@pytest.fixture()
def db_session():
    import_all()
    url = normalize_database_url(os.environ["FARMOS_TEST_POSTGRES_URL"])
    schema = f"feedaction_{uuid.uuid4().hex[:10]}"
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


class TestTheLoopOnPostgres(fa.TestTheLoop):
    pass


class TestRulesOnPostgres(fa.TestRules):
    pass


def test_two_managers_acting_on_the_same_alert_at_once_record_one_action(client, db_session):
    session, factory = db_session
    alert = fa._decline_alert(client, session)
    barrier = threading.Barrier(2)
    outcomes: list = []
    lock = threading.Lock()

    def act(what: str) -> None:
        with factory() as db:
            try:
                user = db.scalar(select(models.User).where(models.User.email == "rami@origami.farm"))
                barrier.wait(timeout=10)
                actions.record_action(db, user, alert["id"], action_type="change_lot", description=what, measure_after_days=7, baseline_days=7)
                time.sleep(1.0)  # hold the transaction open while the other decides
                db.commit()
                result = ("ok", what)
            except actions.ActionError as exc:
                db.rollback()
                result = ("refused", exc.message)
            except Exception as exc:  # noqa: BLE001 - a thread that dies fails the test with its reason
                db.rollback()
                result = ("error", repr(exc))
        with lock:
            outcomes.append(result)

    threads = [threading.Thread(target=act, args=(w,)) for w in ("first", "second")]
    for th in threads:
        th.start()
    for th in threads:
        th.join(timeout=30)
    assert sorted(o[0] for o in outcomes) == ["ok", "refused"], outcomes
    with factory() as db:
        assert db.scalar(select(func.count(am.FeedPerformanceAction.id)).where(am.FeedPerformanceAction.alert_id == alert["id"])) == 1
