"""Two people feed the last 10 kg at the same moment (audit 2026-11-25,
I-13, "unverified" until now). Proven on a real PostgreSQL 16 server, with
real concurrent transactions — not an SQLite approximation, which takes
one lock for the whole database and could never show the race.

Each test runs two threads, each with its own connection and transaction,
released together by a barrier. The first to take the stock holds its
transaction open for a moment before committing, so the second is
certainly deciding while the first is in flight:

- with the row lock (feed_inventory_service.lock_stock), the second waits
  for the first, then sees the lot empty and is refused — one feeding of
  10 kg, the lot at 0, the stock line at 0, the ledger at −10 net;
- without it (the control test, lock replaced by a plain read), both
  succeed and 20 kg leave a 10 kg lot: the race this test exists to catch
  is real on this server, and the lock is what stops it.

Runs when FARMOS_TEST_POSTGRES_URL names a disposable PostgreSQL database
(CI's backend-tests workflow has a postgres:16 service); it works in a
schema of its own, so it never touches what the migration tests drop.
"""
from __future__ import annotations

import os
import threading
import time

import pytest
from sqlalchemy import create_engine, func, select, text
from sqlalchemy.orm import sessionmaker

from app.core.config import normalize_database_url
from app.db.base import Base
from app.domain import feed_models as fm
from app.domain import models
from app.domain.registry import import_all
from app.services import feed_inventory_service as inv

pytestmark = pytest.mark.skipif(not os.environ.get("FARMOS_TEST_POSTGRES_URL"), reason="needs FARMOS_TEST_POSTGRES_URL (PostgreSQL 16)")

SCHEMA = "feed_stock_concurrency"
FARM, USER = "farm-race", "user-race"
HOLD_SECONDS = 1.0


@pytest.fixture()
def pg():
    import_all()
    url = normalize_database_url(os.environ["FARMOS_TEST_POSTGRES_URL"])
    admin = create_engine(url)
    with admin.begin() as conn:
        conn.execute(text(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE"))
        conn.execute(text(f"CREATE SCHEMA {SCHEMA}"))
        version = conn.execute(text("SHOW server_version_num")).scalar()
    admin.dispose()
    engine = create_engine(url, connect_args={"options": f"-csearch_path={SCHEMA}"}, pool_size=4)
    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, autocommit=False, autoflush=False, expire_on_commit=False)
    with factory() as db:
        db.add(models.Farm(id=FARM, name="Race farm"))
        db.flush()
        db.add(models.User(id=USER, farm_id=FARM, name="Race manager", password_hash="x", role="manager"))
        db.commit()
    try:
        yield factory, int(version)
    finally:
        engine.dispose()
        admin = create_engine(url)
        with admin.begin() as conn:
            conn.execute(text(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE"))
        admin.dispose()


def _product_with_last_kilos(factory, code: str, kilos: float = 10) -> tuple[str, str]:
    with factory() as db:
        product = inv.create_product(db, FARM, code=code, name=f"Race hay {code}", ration_type="hay_straw", created_by=USER)
        lot = inv.receive(db, product, quantity=kilos, unit_cost=0.2, lot_code=f"{code}-LAST", source_type="opening_balance", user_id=USER)
        db.commit()
        return product.id, lot.id


def _race(factory, product_id: str, *, quantity: float = 10, lot_id: str | None = None, override: inv.Override | None = None) -> list:
    """Two simultaneous issues of [quantity]; returns each thread's outcome
    ("ok" or the refusal) in finishing order."""
    barrier = threading.Barrier(2)
    outcomes: list = []
    lock = threading.Lock()

    def feed(name: str) -> None:
        with factory() as db:
            try:
                product = db.get(fm.FeedProduct, product_id)
                # Read the product and its lots before the race starts, as a
                # request does: the stale copy the lock must not decide on.
                _ = [l.quantity_on_hand for l in product.lots]
                barrier.wait(timeout=10)
                inv.consume(db, product, quantity, "kg", reason="feeding", linked_entity_type="race", linked_entity_id=name,
                            lot_id=lot_id, override=override, user_id=USER)
                time.sleep(HOLD_SECONDS)  # hold the transaction open while the other decides
                db.commit()
                result = ("ok", name)
            except inv.FeedError as exc:
                db.rollback()
                result = ("refused", exc.message)
        with lock:
            outcomes.append(result)

    threads = [threading.Thread(target=feed, args=(n,)) for n in ("first", "second")]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=30)
    assert len(outcomes) == 2, outcomes
    return outcomes


def _state(factory, product_id: str) -> dict:
    with factory() as db:
        product = db.get(fm.FeedProduct, product_id)
        state = inv.ledger_state(db, product)
        outs = db.scalar(select(func.coalesce(func.sum(models.InventoryTransaction.quantity), 0)).where(
            models.InventoryTransaction.item_id == product.inventory_item_id, models.InventoryTransaction.direction == "out"))
        exceptions = db.scalars(select(fm.FeedStockException).where(fm.FeedStockException.feed_product_id == product_id)).all()
        return {"lots": {l["lot_code"]: (l["cached"], l["ledger"]) for l in state.lots}, "stock_line": state.item_cached,
                "ledger": state.ledger_total, "issued": float(outs), "problems": state.problems(), "exceptions": exceptions}


def test_it_is_postgresql_16(pg):
    _factory, version = pg
    assert version >= 160000, f"server_version_num {version}"


def test_two_simultaneous_feedings_of_the_last_10kg_cannot_both_succeed(pg):
    factory, _ = pg
    product_id, _lot = _product_with_last_kilos(factory, "RACE-FIFO")
    outcomes = _race(factory, product_id)
    assert sorted(o[0] for o in outcomes) == ["ok", "refused"], outcomes
    refused = next(o for o in outcomes if o[0] == "refused")
    assert "Not enough" in refused[1] and "0.0 kg available" in refused[1], refused
    s = _state(factory, product_id)
    assert s["lots"] == {"RACE-FIFO-LAST": (0.0, 0.0)} and s["stock_line"] == 0 and s["ledger"] == 0 and s["issued"] == 10, s
    assert s["problems"] == [] and s["exceptions"] == []


def test_two_simultaneous_feedings_naming_the_last_lot_cannot_both_succeed(pg):
    factory, _ = pg
    product_id, lot_id = _product_with_last_kilos(factory, "RACE-LOT")
    outcomes = _race(factory, product_id, lot_id=lot_id)
    assert sorted(o[0] for o in outcomes) == ["ok", "refused"], outcomes
    assert "RACE-LOT-LAST" in next(o for o in outcomes if o[0] == "refused")[1]
    s = _state(factory, product_id)
    assert s["lots"] == {"RACE-LOT-LAST": (0.0, 0.0)} and s["issued"] == 10 and s["problems"] == []


def test_two_simultaneous_overrides_never_take_the_lot_below_zero(pg):
    """With an approved override both feedings are recorded — the second
    finds the lot empty and its 10 kg become an open exception, not a lot
    at −10 and not a stock line out of step."""
    factory, _ = pg
    product_id, _lot = _product_with_last_kilos(factory, "RACE-OVR")
    override = inv.Override(reason="Delivery on the truck, not entered yet", approved_by=USER, requested_by=USER)
    outcomes = _race(factory, product_id, override=override)
    assert [o[0] for o in outcomes] == ["ok", "ok"], outcomes
    s = _state(factory, product_id)
    assert s["lots"] == {"RACE-OVR-LAST": (0.0, 0.0)}, s
    assert s["stock_line"] == -10 and s["ledger"] == -10 and s["issued"] == 20 and s["problems"] == [], s
    [exc] = s["exceptions"]
    assert exc.quantity == 10 and exc.status == "open" and exc.approved_by == USER


def test_two_feedings_of_the_same_feeds_in_opposite_order_do_not_deadlock(pg):
    """Locks are taken in one order (by inventory item id), so A-then-B and
    B-then-A wait for each other instead of deadlocking."""
    factory, _ = pg
    a, _ = _product_with_last_kilos(factory, "RACE-A", 100)
    b, _ = _product_with_last_kilos(factory, "RACE-B", 100)
    barrier = threading.Barrier(2)
    errors: list = []

    def feed(order: tuple[str, str], name: str) -> None:
        try:
            with factory() as db:
                products = [db.get(fm.FeedProduct, pid) for pid in order]
                barrier.wait(timeout=10)
                inv.lock_stock(db, *products)
                for p in products:
                    inv.consume(db, p, 5, "kg", reason="feeding", linked_entity_type="race", linked_entity_id=name, user_id=USER)
                    time.sleep(0.3)
                db.commit()
        except Exception as exc:  # noqa: BLE001 - a deadlock would surface here
            errors.append(repr(exc))

    threads = [threading.Thread(target=feed, args=(o, n)) for o, n in (((a, b), "a-then-b"), ((b, a), "b-then-a"))]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=30)
    assert errors == []
    for pid in (a, b):
        s = _state(factory, pid)
        assert s["stock_line"] == 90 and s["problems"] == [], s


def test_control_without_the_row_lock_the_same_race_oversells(pg, monkeypatch):
    """The control: the same race with `lock_stock` reduced to a plain
    re-read. Both feedings pass, 20 kg leave a 10 kg lot, and the stored
    figures no longer match the ledger — so the passing tests above are
    the lock's doing, not luck."""
    factory, _ = pg
    product_id, _lot = _product_with_last_kilos(factory, "RACE-NOLOCK")

    def no_lock(db, *products):
        db.flush()
        for product in products:
            if product is not None:
                db.refresh(product, attribute_names=["lots"])

    monkeypatch.setattr(inv, "lock_stock", no_lock)
    outcomes = _race(factory, product_id)
    assert [o[0] for o in outcomes] == ["ok", "ok"], outcomes
    s = _state(factory, product_id)
    assert s["issued"] == 20, s
    assert s["problems"], "two issues of the last 10 kg leave the stored figures out of step with the ledger"
