"""Ordering and receiving feed (master prompt Package 2) on a real PostgreSQL 16.

The same tests as tests/test_procurement_orders.py — two suppliers' prices,
an approved request ordered from the cheaper one, two deliveries with a
rejection, bills paid in parts, the match, the mix traced back to the
order and the supplier, LBP orders, closing short, refusals, permissions,
the farm boundary and retries — against the demo farm seeded in
PostgreSQL. And a real race: two people receive the last 100 kg of a
100 kg order at the same moment; the order's row lock lets one through and
refuses the other, so no order is received twice over.

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
from app.domain import procurement_models as prm
from app.domain.registry import import_all
from app.main import app
from app.seed import seed_demo_data
from app.services import purchase_orders_service as orders
from app.services.procurement_service import ProcurementError
from tests import test_procurement_orders as chain
from tests.test_procurement_orders import suppliers  # noqa: F401 - the same fixture, on PostgreSQL

pytestmark = pytest.mark.skipif(not os.environ.get("FARMOS_TEST_POSTGRES_URL"), reason="needs FARMOS_TEST_POSTGRES_URL (PostgreSQL 16)")


@pytest.fixture()
def db_session():
    import_all()
    url = normalize_database_url(os.environ["FARMOS_TEST_POSTGRES_URL"])
    schema = f"procurement_{uuid.uuid4().hex[:10]}"
    admin = create_engine(url)
    with admin.begin() as conn:
        conn.execute(text(f"CREATE SCHEMA {schema}"))
    admin.dispose()
    engine = create_engine(url, connect_args={"options": f"-csearch_path={schema}"}, pool_size=6)
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


class TestTheProcurementChainOnPostgres(chain.TestTheProcurementChain):
    pass


class TestPartialOrdersAndRefusalsOnPostgres(chain.TestPartialOrdersAndRefusals):
    pass


class TestWhoAndWhichFarmOnPostgres(chain.TestWhoAndWhichFarm):
    pass


def test_two_people_receiving_the_last_of_an_order_at_once_receive_it_once(db_session, suppliers):  # noqa: F811
    _session, factory = db_session
    bekaa, _ = suppliers
    with factory() as db:
        manager = db.get(models.User, "user-rami")
        po = orders.create_order(db, manager, supplier_id=bekaa, lines=[{"feed_product_id": "fp-barley", "quantity": 100, "unit": "kg", "unit_price": 0.5}])
        orders.approve_order(db, manager, po)
        db.commit()
        po_id, line_id = po.id, po.lines[0].id

    barrier = threading.Barrier(2)
    outcomes: list[str] = []

    def receive(who: str):
        db = factory()
        try:
            user = db.get(models.User, "user-worker-1")
            barrier.wait()
            locked = orders.get_order(db, po_id, "farm-origami", lock=True)
            orders.receive(db, user, locked, lines=[{"purchase_order_line_id": line_id, "received_quantity": 100}], delivery_note_no=who)
            time.sleep(1.0)  # hold the lock: the other is certainly waiting meanwhile
            db.commit()
            outcomes.append("received")
        except ProcurementError as e:
            db.rollback()
            outcomes.append(f"refused: {e}")
        finally:
            db.close()

    threads = [threading.Thread(target=receive, args=(f"DN-{i}",)) for i in (1, 2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(o.split(":")[0] for o in outcomes) == ["received", "refused"], outcomes
    with factory() as db:
        assert db.scalar(select(func.count(prm.GoodsReceipt.id)).where(prm.GoodsReceipt.purchase_order_id == po_id)) == 1
        assert db.get(prm.PurchaseOrder, po_id).status == "received"
