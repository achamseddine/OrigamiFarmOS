"""The v0.8.4 migration (d6f8a0c2e4b7) on data written before it.

Builds, at the previous revision, the shapes older code left behind:

  A  stock recorded before lots, carried into an opening lot with no
     movement, then issued from that lot          (a lot ≠ its movements)
  B  an approved override and a named short lot: 50 kg issued with no lot
                                                   (stock line < lots)
  C  a correction that took a lot below zero       (lot at −5)
  D  a stock line changed with no movement         (line ≠ ledger, +5)
  E  a feed with stock but no lot yet              (gets its opening lot)

then upgrades and checks: every stored stock line is what it was, no
existing movement changed, and every product passes the integrity
reconciliation — with the gaps as open exceptions that list what made
them. SQLite always; PostgreSQL 16 too with FARMOS_TEST_POSTGRES_URL (in a
schema of its own).
"""
from __future__ import annotations

import os
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
import sqlalchemy as sa
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker

from app.core.config import normalize_database_url

BACKEND_DIR = Path(__file__).resolve().parents[1]
ALEMBIC_INI = BACKEND_DIR / "alembic.ini"
BEFORE = "c4e6a8b0d2f5"
SCHEMA = "feed_stock_migration"


def _alembic(db: dict, *args: str) -> None:
    env = {**os.environ, "DATABASE_URL": db["url"], "FARMOS_SCHEDULER": "false", **db["env"]}
    proc = subprocess.run([sys.executable, "-m", "alembic", "-c", str(ALEMBIC_INI), *args], cwd=BACKEND_DIR, env=env,
                          capture_output=True, text=True, timeout=600)
    assert proc.returncode == 0, f"alembic {' '.join(args)} failed:\n{proc.stdout}\n{proc.stderr}"


def _urls() -> list[str]:
    return ["sqlite"] + (["postgresql"] if os.environ.get("FARMOS_TEST_POSTGRES_URL") else [])


@pytest.fixture(params=_urls())
def database(request, tmp_path):
    """{url, env for the alembic subprocess, connect_args for engines here}.
    PostgreSQL works in a schema of its own (search_path), so it never
    touches what the other migration tests drop."""
    if request.param == "sqlite":
        yield {"url": f"sqlite:///{tmp_path / 'before.db'}", "env": {}, "connect_args": {}}
        return
    base = normalize_database_url(os.environ["FARMOS_TEST_POSTGRES_URL"])
    admin = create_engine(base)
    with admin.begin() as conn:
        conn.execute(text(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE"))
        conn.execute(text(f"CREATE SCHEMA {SCHEMA}"))
    try:
        yield {"url": base, "env": {"PGOPTIONS": f"-csearch_path={SCHEMA}"}, "connect_args": {"options": f"-csearch_path={SCHEMA}"}}
    finally:
        with admin.begin() as conn:
            conn.execute(text(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE"))
        admin.dispose()


class _Rows:
    """Inserts rows at the old revision with the table as it was then: any
    NOT NULL column the test does not care about gets a plain value."""

    def __init__(self, conn):
        self.conn = conn
        self.meta = sa.MetaData()

    def add(self, table: str, **values) -> str:
        t = sa.Table(table, self.meta, autoload_with=self.conn) if table not in self.meta.tables else self.meta.tables[table]
        row = {}
        for col in t.columns:
            if col.name in values or col.nullable or col.server_default is not None:
                continue
            try:
                py = col.type.python_type
            except NotImplementedError:
                py = str
            row[col.name] = {str: "x", int: 0, float: 0.0, bool: False, dict: {}}.get(py, datetime.now(timezone.utc))
            if col.name == "id":
                row[col.name] = str(uuid.uuid4())
        row.update(values)
        self.conn.execute(t.insert().values(**row))
        return row.get("id")


def _tx(rows: _Rows, item: str, direction: str, qty: float, *, lot: str | None, at: datetime, reason: str, linked=("feeding_event", None)) -> str:
    return rows.add("inventory_transactions", id=str(uuid.uuid4()), item_id=item, direction=direction, quantity=qty, lot_id=lot, reason=reason,
                    linked_entity_type=linked[0], linked_entity_id=linked[1] or str(uuid.uuid4()), created_at=at, unit_cost=0.2)


def _feed(rows: _Rows, key: str, farm: str, *, line: float, lots: list[tuple[str, float, datetime]]) -> dict:
    item = rows.add("inventory_items", id=f"item-{key}", farm_id=farm, name=f"Hay {key}", unit="kg", current_qty=line, reorder_level=0)
    product = rows.add("feed_products", id=f"fp-{key}", farm_id=farm, code=f"HAY-{key}", name=f"Hay {key}", unit="kg", inventory_item_id=item,
                       source_type="purchased", is_ingredient=False, is_feedable=True, ration_type="hay_straw", status="active",
                       created_at=datetime.now(timezone.utc) - timedelta(days=30))
    out = {"item": item, "product": product, "lots": {}}
    for code, qoh, created in lots:
        out["lots"][code] = rows.add("feed_lots", id=f"lot-{key}-{code}", farm_id=farm, feed_product_id=product, lot_code=f"{key}-{code}",
                                     source_type="purchased", received_at=created, created_at=created, received_quantity=max(qoh, 0),
                                     accepted_quantity=max(qoh, 0), rejected_quantity=0, quantity_on_hand=qoh, unit="kg", status="active")
    return out


def test_the_migration_keeps_every_figure_and_makes_every_gap_an_exception(database):
    _alembic(database, "upgrade", BEFORE)
    engine = create_engine(database["url"], connect_args=database["connect_args"])
    day = lambda n: datetime.now(timezone.utc) - timedelta(days=n)  # noqa: E731
    with engine.begin() as conn:
        rows = _Rows(conn)
        farm = rows.add("farms", id="farm-mig", name="Migration farm")
        # A: 100 in and 20 out before lots (no lot), then an opening lot of 80
        # with no movement, then 30 issued from it.
        a = _feed(rows, "A", farm, line=50, lots=[("OPENING", 50, day(20))])
        _tx(rows, a["item"], "in", 100, lot=None, at=day(25), reason="purchase", linked=("inventory_item", a["item"]))
        _tx(rows, a["item"], "out", 20, lot=None, at=day(24), reason="feeding", linked=("inventory_item", a["item"]))
        _tx(rows, a["item"], "out", 30, lot=a["lots"]["OPENING"], at=day(10), reason="feeding")
        # B: a 10 kg lot, a 60 kg feeding: 10 from the lot, 50 with no lot.
        b = _feed(rows, "B", farm, line=-50, lots=[("L1", 0, day(9))])
        _tx(rows, b["item"], "in", 10, lot=b["lots"]["L1"], at=day(9), reason="purchase", linked=("feed_lot", b["lots"]["L1"]))
        _tx(rows, b["item"], "out", 10, lot=b["lots"]["L1"], at=day(8), reason="feeding")
        b_untraced = _tx(rows, b["item"], "out", 50, lot=None, at=day(8), reason="feeding")
        # C: 20 received, a correction of −25 on the lot.
        c = _feed(rows, "C", farm, line=-5, lots=[("L1", -5, day(7))])
        _tx(rows, c["item"], "in", 20, lot=c["lots"]["L1"], at=day(7), reason="purchase", linked=("feed_lot", c["lots"]["L1"]))
        _tx(rows, c["item"], "out", 25, lot=c["lots"]["L1"], at=day(6), reason="waste", linked=("feed_product", c["product"]))
        # D: 40 received; the stock line says 45 with no movement for the 5.
        d = _feed(rows, "D", farm, line=45, lots=[("L1", 40, day(5))])
        _tx(rows, d["item"], "in", 40, lot=d["lots"]["L1"], at=day(5), reason="purchase", linked=("feed_lot", d["lots"]["L1"]))
        # E: stock, no lot yet.
        e = _feed(rows, "E", farm, line=30, lots=[])
        _tx(rows, e["item"], "in", 30, lot=None, at=day(4), reason="purchase", linked=("inventory_item", e["item"]))
    with engine.connect() as conn:
        lines_before = dict(conn.execute(text("SELECT id, current_qty FROM inventory_items")).all())
        lots_before = dict(conn.execute(text("SELECT id, quantity_on_hand FROM feed_lots")).all())
        moves_before = {r[0]: tuple(r[1:]) for r in conn.execute(text(
            "SELECT id, item_id, direction, quantity, lot_id, reason, created_at FROM inventory_transactions")).all()}
    engine.dispose()

    _alembic(database, "upgrade", "head")

    engine = create_engine(database["url"], connect_args=database["connect_args"])
    try:
        with engine.connect() as conn:
            assert dict(conn.execute(text("SELECT id, current_qty FROM inventory_items")).all()) == lines_before, "no stock line moves"
            moves_after = {r[0]: tuple(r[1:]) for r in conn.execute(text(
                "SELECT id, item_id, direction, quantity, lot_id, reason, created_at FROM inventory_transactions")).all()}
            assert {k: moves_after[k] for k in moves_before} == moves_before, "no movement is edited"
            added = [moves_after[k] for k in set(moves_after) - set(moves_before)]
            assert all(m[4] is not None or m[5] == "ledger_carry_over" for m in added)
            lots_after = dict(conn.execute(text("SELECT id, quantity_on_hand FROM feed_lots")).all())
            assert {k: lots_after[k] for k in lots_before} == {**lots_before, c["lots"]["L1"]: 0}, "only the lot below zero moves, to zero"

        from app.domain import feed_models as fm
        from app.domain.registry import import_all
        from app.services import feed_inventory_service as inv

        import_all()
        db = sessionmaker(bind=engine)()
        try:
            states = {k: inv.ledger_state(db, db.get(fm.FeedProduct, f"fp-{k}")) for k in "ABCDE"}
            for k in "ABCDE":
                assert states[k].problems() == [], (k, states[k].problems())
            # A: the opening lot keeps 50 and now has its rows; nothing open.
            assert states["A"].lots[0]["ledger"] == 50 and states["A"].untraced == 0 and states["A"].open_exceptions == 0
            # B: the 50 kg are one open exception that lists the movement.
            exc_b = db.query(fm.FeedStockException).filter_by(feed_product_id="fp-B").one()
            assert (exc_b.kind, exc_b.status, exc_b.quantity, exc_b.approved_by) == ("legacy_untraced", "open", 50, None)
            assert [t["id"] for t in exc_b.detail["transactions"]] == [b_untraced]
            assert states["B"].ledger_total == -50 and states["B"].untraced == -50
            # C: the lot is at zero and its 5 kg are the exception, naming it.
            exc_c = db.query(fm.FeedStockException).filter_by(feed_product_id="fp-C").one()
            assert exc_c.quantity == 5 and exc_c.lot_id == c["lots"]["L1"]
            assert exc_c.detail["negative_lots"][0]["quantity"] == -5
            # D: the 5 kg the line held with no movement have a lot of their own.
            assert sorted(l["ledger"] for l in states["D"].lots) == [5, 40]
            assert any(l["lot_code"] == "HAY-D-CARRIED" for l in states["D"].lots)
            # E: its stock gets an opening lot, with its rows.
            assert [(l["lot_code"], l["ledger"]) for l in states["E"].lots] == [("HAY-E-OPENING", 30)]
            assert inv.availability(db, db.get(fm.FeedProduct, "fp-E")).on_hand == 30
            # The service's whole-farm reconciliation agrees.
            report = inv.integrity_report(db, "farm-mig")
            assert report["consistent"], report["inconsistent"]
        finally:
            db.close()
    finally:
        engine.dispose()
    _alembic(database, "downgrade", BEFORE)
