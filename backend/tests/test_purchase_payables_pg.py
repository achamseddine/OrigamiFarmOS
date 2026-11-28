"""Purchases in the farm's books (audit I-9, I-14) on a real PostgreSQL 16.

The same tests as tests/test_purchase_payables.py — 500 kg delivered, 20 kg
rejected, USD 240 accepted, nothing paid on credit, USD 100 paid then USD
140 owed; retries and repeats, LBP at the day's rate, returns, refunds,
reversals, medicine, farm isolation and the reconciliation of deliveries
recorded before — against the demo farm seeded in PostgreSQL. And a real
race: two people pay USD 200 each on the same USD 240 bill at the same
moment; the bill's row lock lets one through and refuses the other, so the
farm never pays more than it owes. And two people reversing the same
payment at once: the second, having waited for the lock, finds it already
reversed, so it is undone once.

Runs when FARMOS_TEST_POSTGRES_URL names a disposable PostgreSQL database;
each test works in a schema of its own, so parallel workers never meet.
"""
from __future__ import annotations

import os
import threading
import time
import uuid
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select, text
from sqlalchemy.orm import sessionmaker

from app.core.config import normalize_database_url
from app.db.base import Base, get_db
from app.domain import feed_models as fm
from app.domain import finance_models as fin
from app.domain import models
from app.domain.registry import import_all
from app.main import app
from app.seed import seed_demo_data
from app.services import feed_inventory_service as inv
from app.services import purchases_service as purchases
from app.services.finance_service import FinanceError
from tests import test_purchase_payables as books
from tests.test_purchase_payables import other_farm  # noqa: F401 - the same fixture, on PostgreSQL

pytestmark = pytest.mark.skipif(not os.environ.get("FARMOS_TEST_POSTGRES_URL"), reason="needs FARMOS_TEST_POSTGRES_URL (PostgreSQL 16)")


@pytest.fixture()
def db_session():
    import_all()
    url = normalize_database_url(os.environ["FARMOS_TEST_POSTGRES_URL"])
    schema = f"purchases_{uuid.uuid4().hex[:10]}"
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


class TestAcceptedStockAndTheSuppliersBillOnPostgres(books.TestAcceptedStockAndTheSuppliersBill):
    pass


class TestReturnsRefundsAndCorrectionsOnPostgres(books.TestReturnsRefundsAndCorrections):
    pass


class TestMedicinePurchasesOnPostgres(books.TestMedicinePurchases):
    pass


class TestWhoAndWhichFarmOnPostgres(books.TestWhoAndWhichFarm):
    pass


class TestDeliveriesFromBeforeThisReleaseOnPostgres(books.TestDeliveriesFromBeforeThisRelease):
    pass


def test_two_people_paying_the_same_bill_at_once_never_pay_more_than_is_owed(db_session):
    _session, factory = db_session
    with factory() as db:
        product = inv.create_product(db, "farm-origami", code="RACE-CORN", name="Race corn", ration_type="raw_material", created_by="user-rami")
        lot = inv.receive(db, product, quantity=500, rejected_quantity=20, unit_cost=0.5, supplier_label="Bekaa Grain Co.", user_id="user-rami")
        bill = purchases.bill_delivery(db, farm_id="farm-origami", user_id="user-rami", lot_type="feed_lot", lot=lot, category="feed",
                                       label=product.name, unit_price=0.5, currency="USD", exchange_rate=None, payment="credit")
        db.commit()
        bill_id = bill.id

    barrier = threading.Barrier(2)
    outcomes: list[str] = []

    def pay(who: str):
        db = factory()
        try:
            user = db.get(models.User, "user-rami")
            barrier.wait()
            locked = purchases.get_bill(db, bill_id, "farm-origami", lock=True)
            purchases.pay_bill(db, user, locked, amount=200, reference=who, confirm_duplicate=True)
            time.sleep(1.0)  # hold the lock: the other is certainly deciding meanwhile
            db.commit()
            outcomes.append("paid")
        except FinanceError as e:
            db.rollback()
            outcomes.append(f"refused: {e}")
        finally:
            db.close()

    threads = [threading.Thread(target=pay, args=(f"T{i}",)) for i in (1, 2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert sorted(o.split(":")[0] for o in outcomes) == ["paid", "refused"], outcomes
    assert any("more than is owed" in o for o in outcomes)
    with factory() as db:
        rows = db.scalars(select(fin.SupplierPayment).where(fin.SupplierPayment.expense_id == bill_id)).all()
        assert [p.amount for p in rows] == [200], "one payment of 200 on a bill of 240"
        assert db.get(models.Expense, bill_id).payment_status == "partial"


def test_two_people_reversing_the_same_payment_at_once_undo_it_once(db_session):
    """Both load the payment, as the route does, then reverse it at the same
    moment. The bill's lock makes the second wait; it must then see the
    payment already reversed, not undo it a second time (which would leave
    the bill owing twice the payment)."""
    _session, factory = db_session
    with factory() as db:
        product = inv.create_product(db, "farm-origami", code="RACE-CORN-2", name="Race corn 2", ration_type="raw_material", created_by="user-rami")
        lot = inv.receive(db, product, quantity=500, rejected_quantity=20, unit_cost=0.5, supplier_label="Bekaa Grain Co.", user_id="user-rami")
        bill = purchases.bill_delivery(db, farm_id="farm-origami", user_id="user-rami", lot_type="feed_lot", lot=lot, category="feed",
                                       label=product.name, unit_price=0.5, currency="USD", exchange_rate=None, payment="credit")
        payment = purchases.pay_bill(db, db.get(models.User, "user-rami"), bill, amount=100, reference="paid by mistake")
        db.commit()
        bill_id, payment_id = bill.id, payment.id

    barrier = threading.Barrier(2)
    outcomes: list[str] = []

    def reverse(who: str):
        db = factory()
        try:
            user = db.get(models.User, "user-rami")
            row = db.get(fin.SupplierPayment, payment_id)  # loaded before the lock, as the route loads it
            barrier.wait()
            purchases.reverse_payment(db, user, row, reason=f"mistake ({who})")
            time.sleep(1.0)  # hold the lock: the other is certainly deciding meanwhile
            db.commit()
            outcomes.append("reversed")
        except FinanceError as e:
            db.rollback()
            outcomes.append(f"refused: {e}")
        finally:
            db.close()

    threads = [threading.Thread(target=reverse, args=(f"T{i}",)) for i in (1, 2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert sorted(o.split(":")[0] for o in outcomes) == ["refused", "reversed"], outcomes
    assert any("already reversed" in o for o in outcomes), outcomes
    with factory() as db:
        rows = db.scalars(select(fin.SupplierPayment).where(fin.SupplierPayment.expense_id == bill_id)).all()
        assert sorted(p.amount for p in rows) == [-100, 100], "the payment and one reversal"
        assert db.get(models.Expense, bill_id).payment_status == "pending"
