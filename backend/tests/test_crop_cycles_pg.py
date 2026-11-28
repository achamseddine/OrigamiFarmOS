"""A crop cycle from planting to its margin (master prompt Package 7) on a
real PostgreSQL 16.

The same tests as tests/test_crop_cycles.py — a greenhouse planted, worked,
watered, harvested into stock, its produce sold and its actual margin read;
refusals, reversals, unknown costs, farm isolation and permissions — against
the demo farm seeded in PostgreSQL, through the API. And what SQLite cannot
show: two people taking the last of an input, or selling the last of the
produce, at the same moment. Each thread has its own connection and
transaction, released together by a barrier; the first holds its
transaction open while the second decides, so the second is refused rather
than taking stock that is no longer there.

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
from app.domain.registry import import_all
from app.main import app
from app.seed import seed_demo_data
from app.services import crop_cycles_service as cycles
from tests import test_crop_cycles as cc
from tests.test_crop_cycles import greenhouse  # noqa: F401 - the same fixture, on PostgreSQL

pytestmark = pytest.mark.skipif(not os.environ.get("FARMOS_TEST_POSTGRES_URL"), reason="needs FARMOS_TEST_POSTGRES_URL (PostgreSQL 16)")

HOLD_SECONDS = 1.0


@pytest.fixture()
def db_session():
    import_all()
    url = normalize_database_url(os.environ["FARMOS_TEST_POSTGRES_URL"])
    schema = f"crop_cycles_{uuid.uuid4().hex[:10]}"
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


class TestTheAcceptanceScenarioOnPostgres(cc.TestTheAcceptanceScenario):
    pass


class TestRefusalsAndCorrectionsOnPostgres(cc.TestRefusalsAndCorrections):
    pass


class TestWhoAndWhichFarmOnPostgres(cc.TestWhoAndWhichFarm):
    pass


def _race(factory, act) -> list:
    """Runs [act](db, user, barrier, name) in two threads at once; returns each outcome
    ("ok", or "refused" with the reason) in finishing order."""
    barrier = threading.Barrier(2)
    outcomes: list = []
    lock = threading.Lock()

    def run(name: str) -> None:
        with factory() as db:
            try:
                user = db.scalar(select(models.User).where(models.User.email == "rami@origami.farm"))
                act(db, user, barrier, name)
                time.sleep(HOLD_SECONDS)  # hold the transaction open while the other decides
                db.commit()
                result = ("ok", name)
            except cycles.FeedError as exc:  # a crop refusal, or the sale's own (Sales & Finance)
                db.rollback()
                result = ("refused", exc.message)
            except Exception as exc:  # noqa: BLE001 - reported, so a thread that dies fails the test with its reason
                db.rollback()
                result = ("error", repr(exc))
        with lock:
            outcomes.append(result)

    threads = [threading.Thread(target=run, args=(n,)) for n in ("first", "second")]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=30)
    assert len(outcomes) == 2, outcomes
    return outcomes


def _outs(factory, item_id: str) -> float:
    with factory() as db:
        return float(db.scalar(select(func.coalesce(func.sum(models.InventoryTransaction.quantity), 0)).where(
            models.InventoryTransaction.item_id == item_id, models.InventoryTransaction.direction == "out")))


def test_it_is_postgresql_16(db_session):
    session, _ = db_session
    assert int(session.execute(text("SHOW server_version_num")).scalar()) >= 160000


def test_two_people_taking_the_last_fertiliser_at_once_cannot_both_take_it(db_session, greenhouse):  # noqa: F811
    _, factory = db_session
    g = greenhouse

    def take_all(db, user, barrier, _name):
        cycle = db.get(models.CropPlanting, g["cycle"]["id"])
        # The stock line read first and still held, as a request may hold it:
        # the stale copy the lock must not decide on.
        stale = db.get(models.InventoryItem, g["fert"])
        assert stale.current_qty == 50
        barrier.wait(timeout=10)
        cycles.record_operation(db, user, cycle, operation_type="fertilize", inputs=[{"inventory_item_id": g["fert"], "quantity": 50}])
        assert stale is not None  # still held across the lock

    outcomes = _race(factory, take_all)
    assert sorted(o[0] for o in outcomes) == ["ok", "refused"], outcomes
    assert "Not enough NPK 20-20-20" in [o[1] for o in outcomes if o[0] == "refused"][0]
    with factory() as db:
        assert db.get(models.InventoryItem, g["fert"]).current_qty == 0
    assert _outs(factory, g["fert"]) == 50


def test_two_sales_of_the_last_produce_at_once_cannot_both_be_made(client, db_session, greenhouse):  # noqa: F811
    _, factory = db_session
    g = greenhouse
    assert cc._harvest(client, g, total=500, waste=20).status_code == 201  # 480 kg into stock
    with factory() as db:
        produce_id = cycles.produce_item(db, db.get(models.CropPlanting, g["cycle"]["id"])).id

    def sell(db, user, barrier, name):
        cycle = db.get(models.CropPlanting, g["cycle"]["id"])
        # The stock line read before the race, as sell_produce itself first finds it (unlocked).
        stale = cycles.produce_item(db, cycle)
        assert stale.current_qty == 480
        barrier.wait(timeout=10)
        # Two buyers, so the sale's same-sale guard is not what decides: the stock is.
        cycles.sell_produce(db, user, cycle, quantity=300, unit_price=1.0, buyer_name=f"Buyer {name}")
        assert stale is not None  # still held across the lock

    outcomes = _race(factory, sell)
    assert sorted(o[0] for o in outcomes) == ["ok", "refused"], outcomes
    with factory() as db:
        assert db.get(models.InventoryItem, produce_id).current_qty == 180
        assert db.scalar(select(func.count(models.Sale.id)).where(models.Sale.crop_planting_id == g["cycle"]["id"])) == 1
    assert _outs(factory, produce_id) == 300
