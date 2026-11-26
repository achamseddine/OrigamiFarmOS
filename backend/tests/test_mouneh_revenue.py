"""Mouneh sales in the farm's books (audit 2026-11-25 I-8).

A sale in the Mouneh shop is three accounting events, each recorded once:

* the jars leave the shelf — finished-goods stock and the Mouneh sale line
  (inventory movement);
* the revenue — one canonical `sales` row, product_type "mouneh", linked
  from the line (`mouneh_sale_lines.sale_id`): what Sales & Finance, the
  owed list, the reports and profit and loss read;
* the cash — when it is paid: at the till, later in Sales & Finance, or in
  parts (`customer_payments.sale_id`).

Cancelling puts the jars back, undoes the revenue with a negative row and
refunds what was received. Sales recorded before this release are posted by
an idempotent reconciliation (a dry run, then apply) — never twice, never
rewritten; a jar sold in the farm shop during a visit is already in that
purchase's sale and is linked to it, not posted again.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from app.core.security import hash_password
from app.domain import finance_models as fin
from app.domain import models, mouneh_models
from app.repositories.base import new_id
from tests.conftest import auth_headers

API = "/api/v1"
FARM = "farm-origami"
MANAGER = "rami@origami.farm"
WORKER = "karim.worker@origami.farm"
OPERATOR = "mouneh.op@origami.farm"
OTHER_MANAGER = "mgr@other.farm"
PRODUCT = "prod-makdous"
STOCK = "stock-makdous-001"


def _h(client, email=MANAGER):
    return auth_headers(client, email)


def _sell(client, headers, **body):
    payload = {"product_id": PRODUCT, "quantity": 1, "unit_price": 7, "channel": "retail"}
    payload.update(body)
    return client.post(f"{API}/mouneh/sales", json=payload, headers=headers)


def _books(client, headers) -> dict:
    """What the farm's books say now: revenue, Mouneh revenue, cash in
    (profit and loss, last 12 months) and what customers owe."""
    pl = client.get(f"{API}/finance/profit-loss", headers=headers).json()
    owed = client.get(f"{API}/finance/owed", headers=headers).json()
    mouneh = next((a["revenue"] for a in pl["by_activity"] if a["activity"] == "mouneh"), 0.0)
    return {"revenue": pl["totals"]["revenue"], "mouneh": mouneh, "cash_in": pl["totals"]["cash_in"], "owed": owed["receivables"]["total"]}


def _delta(before: dict, after: dict) -> dict:
    return {k: round(after[k] - before[k], 2) for k in before}


def _sales(client, headers) -> list[dict]:
    return client.get(f"{API}/finance/sales", headers=headers).json()


def _canonical(client, headers, line: dict) -> dict:
    return next(s for s in _sales(client, headers) if s["id"] == line["sale_id"])


def _mouneh_line(client, headers, line_id: str) -> dict:
    return next(s for s in client.get(f"{API}/mouneh/sales", headers=headers).json() if s["id"] == line_id)


def _stock(client, headers) -> dict:
    return next(s for s in client.get(f"{API}/mouneh/finished-goods", headers=headers, params={"product_id": PRODUCT}).json() if s["id"] == STOCK)


def _when(value: str) -> datetime:
    t = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


@pytest.fixture()
def operator(db_session):
    """A Mouneh employee: sells in the shop, cancels nothing."""
    session, _ = db_session
    session.add(models.User(id=new_id(), farm_id=FARM, name="Mouneh Operator", email=OPERATOR, password_hash=hash_password("farmos123"),
                            role="mouneh_operator", department="mouneh"))
    session.commit()
    return OPERATOR


@pytest.fixture()
def other_farm(db_session):
    """A second farm, licensed for Mouneh, with its own manager and customer."""
    session, _ = db_session
    session.add(models.Farm(id="farm-other", name="Other Farm", country="X", region="Y", timezone="UTC", default_currency="USD"))
    session.flush()
    session.add(models.User(id="user-other-mgr", farm_id="farm-other", name="Other manager", email=OTHER_MANAGER,
                            password_hash=hash_password("farmos123"), role="manager", language="en"))
    session.add(mouneh_models.ModuleLicense(id=new_id(), farm_id="farm-other", module_code="mouneh", status="active"))
    session.add(models.Customer(id="customer-other", farm_id="farm-other", name="Their customer"))
    session.commit()
    return "farm-other"


class TestMounehSalesInTheBooks:
    def test_I8_a_7_dollar_mouneh_sale_is_revenue_once_in_sales_reports_and_profit_and_loss(self, client):
        manager = _h(client)
        before = _books(client, manager)
        report_before = client.get(f"{API}/reports/sales", headers=manager).json()["kpis"]

        r = _sell(client, manager)
        assert r.status_code == 201, r.text
        line = r.json()
        assert line["revenue"] == 7 and line["sale_id"] and line["payment_status"] == "paid" and line["balance_due"] == 0

        sale = _canonical(client, manager, line)
        assert (sale["product_type"], sale["activity"], sale["amount"], sale["currency"]) == ("mouneh", "mouneh", 7, "USD")
        assert (sale["product_label"], sale["quantity"], sale["unit"], sale["unit_price"]) == ("Makdous", 1, "jar", 7)
        assert sale["mouneh_sale_id"] == line["id"] and sale["status"] == "recorded"
        assert sale["cost_of_goods"] == pytest.approx(line["cost_per_unit"]), "the production cost stays with the sale"
        assert _when(sale["sold_at"]) == _when(line["sold_at"])
        assert [s["id"] for s in _sales(client, manager) if s.get("mouneh_sale_id") == line["id"]] == [sale["id"]], "posted exactly once"

        assert _delta(before, _books(client, manager)) == {"revenue": 7, "mouneh": 7, "cash_in": 7, "owed": 0}
        report = client.get(f"{API}/reports/sales", headers=manager).json()["kpis"]
        assert round(report["revenue"] - report_before["revenue"], 2) == 7 and report["sales"] == report_before["sales"] + 1

    def test_the_line_and_its_sale_agree_on_the_money(self, client):
        manager = _h(client)
        line = _sell(client, manager, quantity=3, unit_price=2.333, discount=0.5).json()
        sale = _canonical(client, manager, line)
        assert sale["amount"] == line["revenue"] == 6.5, "3 × 2.333 − 0.5, in cents, on both records"
        assert line["margin"] == pytest.approx(6.5 - 3 * line["cost_per_unit"], abs=1e-4)
        assert _sell(client, manager, quantity=1, unit_price=5, discount=5).status_code == 422, "a sale for nothing is not a sale"

    def test_an_unpaid_sale_is_owed_by_its_buyer_until_it_is_paid(self, client):
        manager = _h(client)
        before = _books(client, manager)
        refused = _sell(client, manager, payment_status="pending")
        assert refused.status_code == 422 and "who" in refused.json()["detail"].lower()

        line = _sell(client, manager, payment_status="pending", buyer_name="Um Ali").json()
        assert (line["payment_status"], line["amount_paid"], line["balance_due"], line["buyer_name"]) == ("pending", 0, 7, "Um Ali")
        assert _delta(before, _books(client, manager)) == {"revenue": 7, "mouneh": 7, "cash_in": 0, "owed": 7}
        owed = client.get(f"{API}/finance/owed", headers=manager).json()["receivables"]
        assert any(b["buyer_name"] == "Um Ali" and b["amount"] == 7 for b in owed["by_buyer"])

        paid = client.post(f"{API}/finance/sales/{line['sale_id']}/paid", json={}, headers=manager)
        assert paid.status_code == 200, paid.text
        assert _delta(before, _books(client, manager)) == {"revenue": 7, "mouneh": 7, "cash_in": 7, "owed": 0}
        assert _mouneh_line(client, manager, line["id"])["payment_status"] == "paid"

    def test_a_part_payment_leaves_the_rest_owed_until_it_is_received(self, client, db_session):
        manager = _h(client)
        before = _books(client, manager)
        assert _sell(client, manager, payment_status="partial", buyer_name="Um Ali").status_code == 422, "how much was paid?"
        assert _sell(client, manager, payment_status="partial", amount_paid=7, buyer_name="Um Ali").status_code == 422, "that is paid in full"

        line = _sell(client, manager, payment_status="partial", amount_paid=4, buyer_name="Um Ali").json()
        assert (line["payment_status"], line["amount_paid"], line["balance_due"]) == ("partial", 4, 3)
        assert _delta(before, _books(client, manager)) == {"revenue": 7, "mouneh": 7, "cash_in": 4, "owed": 3}
        sale = _canonical(client, manager, line)
        assert (sale["payment_status"], sale["amount_paid"], sale["balance_due"]) == ("partial", 4, 3)

        # The rest, in Sales & Finance: what is due is the balance, not the whole sale.
        rest = client.post(f"{API}/finance/payments", json={"sale_ids": [line["sale_id"]], "amount_received": 3}, headers=manager)
        assert rest.status_code == 201, rest.text
        assert (rest.json()["amount_due"], rest.json()["difference"]) == (3, 0)
        assert _delta(before, _books(client, manager)) == {"revenue": 7, "mouneh": 7, "cash_in": 7, "owed": 0}
        assert _mouneh_line(client, manager, line["id"])["balance_due"] == 0

        # Paid in parts in Sales & Finance too: 2, then the last 4.
        second = _sell(client, manager, unit_price=6, payment_status="pending", buyer_name="Abu Fadi").json()
        third = _sell(client, manager, unit_price=5, payment_status="pending", buyer_name="Abu Fadi").json()
        two = client.post(f"{API}/finance/payments", json={"sale_ids": [second["sale_id"], third["sale_id"]], "amount_received": 1,
                                                            "part_payment": True}, headers=manager)
        assert two.status_code == 422, "a part payment is toward one sale"
        assert client.post(f"{API}/mouneh/sales/{third['id']}/cancel", json={"reason": "Entered by mistake"}, headers=manager).status_code == 200
        part = client.post(f"{API}/finance/payments", json={"sale_ids": [second["sale_id"]], "amount_received": 2, "part_payment": True},
                           headers=manager)
        assert part.status_code == 201, part.text
        assert (_canonical(client, manager, second)["payment_status"], _canonical(client, manager, second)["balance_due"]) == ("partial", 4)
        assert _delta(before, _books(client, manager)) == {"revenue": 13, "mouneh": 13, "cash_in": 9, "owed": 4}
        last = client.post(f"{API}/finance/payments", json={"sale_ids": [second["sale_id"]], "amount_received": 4, "part_payment": True},
                           headers=manager)
        assert last.status_code == 201, last.text
        assert _canonical(client, manager, second)["payment_status"] == "paid"
        assert _delta(before, _books(client, manager)) == {"revenue": 13, "mouneh": 13, "cash_in": 13, "owed": 0}

        session, factory = db_session
        with factory() as db:
            receipts = db.scalars(select(fin.CustomerPayment).where(fin.CustomerPayment.sale_id == second["sale_id"])).all()
            assert sorted(p.amount_received for p in receipts) == [2, 4], "each part is its own receipt"
            audits = db.scalars(select(models.AuditLog).where(models.AuditLog.action == "payment_received")).all()
            assert len(audits) >= 3

    def test_a_sale_in_lbp_keeps_the_lbp_amount_and_the_rate(self, client):
        manager = _h(client)
        assert client.post(f"{API}/finance/exchange-rates", json={"currency": "LBP", "rate_per_usd": 89500}, headers=manager).status_code == 201
        line = _sell(client, manager, unit_price=626500, currency="LBP").json()
        assert line["revenue"] == 7 and line["unit_price"] == 7, "the Mouneh shop counts in dollars"
        sale = _canonical(client, manager, line)
        assert (sale["amount"], sale["original_amount"], sale["original_currency"], sale["exchange_rate"]) == (7, 626500, "LBP", 89500)
        assert (line["original_amount"], line["original_currency"]) == (626500, "LBP")

    def test_a_sale_made_offline_keeps_the_time_it_was_made(self, client):
        manager = _h(client)
        made = datetime.now(timezone.utc).replace(microsecond=0) - timedelta(days=2, hours=3)
        key = {"Idempotency-Key": str(uuid.uuid4())}
        line = _sell(client, {**manager, **key}, sold_at=made.isoformat()).json()
        assert _when(line["sold_at"]) == made
        assert _when(_canonical(client, manager, line)["sold_at"]) == made, "revenue on the day of the sale, not the day it synced"
        future = _sell(client, manager, sold_at=(datetime.now(timezone.utc) + timedelta(hours=2)).isoformat())
        assert future.status_code == 422

    def test_a_retried_request_records_one_sale_and_a_repeat_is_asked(self, client):
        manager = _h(client)
        before, stock = _books(client, manager), _stock(client, manager)["quantity_available"]
        key = {**manager, "Idempotency-Key": str(uuid.uuid4())}
        first = _sell(client, key)
        again = _sell(client, key)
        assert first.status_code == again.status_code == 201
        assert again.json()["id"] == first.json()["id"] and again.json()["sale_id"] == first.json()["sale_id"]
        assert _delta(before, _books(client, manager))["revenue"] == 7 and _stock(client, manager)["quantity_available"] == stock - 1

        typed_twice = _sell(client, manager)
        assert typed_twice.status_code == 409 and typed_twice.json()["detail"].startswith("Possible duplicate")
        confirmed = _sell(client, manager, confirm_duplicate=True)
        assert confirmed.status_code == 201 and confirmed.json()["sale_id"] != first.json()["sale_id"]
        assert _delta(before, _books(client, manager))["revenue"] == 14 and _stock(client, manager)["quantity_available"] == stock - 2
        lines = {s["mouneh_sale_id"] for s in _sales(client, manager) if s["product_type"] == "mouneh" and s["status"] == "recorded"}
        assert {first.json()["id"], confirmed.json()["id"]} <= lines

    def test_another_farm_can_neither_see_nor_touch_our_sales(self, client, other_farm):
        manager, other = _h(client), _h(client, OTHER_MANAGER)
        line = _sell(client, manager).json()
        assert _sell(client, manager, customer_id="customer-other").status_code == 404, "their customer is not ours"
        assert all(s["id"] != line["id"] for s in client.get(f"{API}/mouneh/sales", headers=other).json())
        assert all(s["id"] != line["sale_id"] for s in _sales(client, other))
        assert client.post(f"{API}/mouneh/sales/{line['id']}/cancel", json={"reason": "not ours"}, headers=other).status_code == 404
        assert client.post(f"{API}/finance/sales/{line['sale_id']}/cancel", json={"reason": "not ours"}, headers=other).status_code == 404
        assert client.get(f"{API}/finance/reconciliation/mouneh-sales", headers=other).json()["to_post"]["count"] == 0
        assert _canonical(client, manager, line)["status"] == "recorded"

    def test_who_may_sell_and_who_may_cancel(self, client, operator):
        assert _sell(client, _h(client, WORKER)).status_code == 403
        line = _sell(client, _h(client, operator))
        assert line.status_code == 201, line.text
        cancel = client.post(f"{API}/mouneh/sales/{line.json()['id']}/cancel", json={"reason": "typo"}, headers=_h(client, operator))
        assert cancel.status_code == 403, "cancelling a sale is the manager's"
        assert client.get(f"{API}/finance/reconciliation/mouneh-sales", headers=_h(client, operator)).status_code == 403
        assert client.get(f"{API}/finance/reconciliation/mouneh-sales", headers=_h(client, WORKER)).status_code == 403
        ok = client.post(f"{API}/mouneh/sales/{line.json()['id']}/cancel", json={"reason": "typo"}, headers=_h(client))
        assert ok.status_code == 200, ok.text

    def test_mouneh_profitability_and_the_books_agree(self, client):
        manager = _h(client)
        before_books = _books(client, manager)
        before = client.get(f"{API}/mouneh/products/{PRODUCT}/profitability", headers=manager).json()
        kept = _sell(client, manager, quantity=2, unit_price=7).json()
        undone = _sell(client, manager, quantity=1, unit_price=8).json()
        client.post(f"{API}/mouneh/sales/{undone['id']}/cancel", json={"reason": "returned"}, headers=manager)
        after = client.get(f"{API}/mouneh/products/{PRODUCT}/profitability", headers=manager).json()
        assert round(after["total_revenue"] - before["total_revenue"], 2) == kept["revenue"] == 14
        assert after["units_sold"] - before["units_sold"] == 2
        assert round(after["total_profit"] - before["total_profit"], 2) == round(kept["margin"], 2)
        assert _delta(before_books, _books(client, manager))["mouneh"] == 14


class TestCancellingAMounehSale:
    def test_cancelling_puts_the_jar_back_and_undoes_the_revenue_and_the_cash(self, client, db_session):
        manager = _h(client)
        before, stock = _books(client, manager), _stock(client, manager)
        line = _sell(client, manager).json()
        assert client.post(f"{API}/mouneh/sales/{line['id']}/cancel", json={"reason": " "}, headers=manager).status_code == 422

        r = client.post(f"{API}/mouneh/sales/{line['id']}/cancel", json={"reason": "Wrong product scanned"}, headers=manager)
        assert r.status_code == 200, r.text
        assert (r.json()["status"], r.json()["cancel_reason"]) == ("cancelled", "Wrong product scanned")
        after_stock = _stock(client, manager)
        assert (after_stock["quantity_available"], after_stock["quantity_sold"]) == (stock["quantity_available"], stock["quantity_sold"])
        assert _delta(before, _books(client, manager)) == {"revenue": 0, "mouneh": 0, "cash_in": 0, "owed": 0}

        rows = _sales(client, manager)
        original = next(s for s in rows if s["id"] == line["sale_id"])
        reversal = next(s for s in rows if s["reversal_of_id"] == line["sale_id"])
        assert (original["status"], original["amount"]) == ("cancelled", 7), "the sale stays on file"
        assert (reversal["status"], reversal["amount"], reversal["activity"]) == ("reversal", -7, "mouneh")
        assert client.post(f"{API}/mouneh/sales/{line['id']}/cancel", json={"reason": "again"}, headers=manager).status_code == 409

        session, factory = db_session
        with factory() as db:
            audit = db.scalar(select(models.AuditLog).where(models.AuditLog.action == "mouneh_sale_cancelled",
                                                            models.AuditLog.entity_id == line["id"]))
            assert audit is not None and audit.metadata_json["reversal_sale_id"] == reversal["id"]
            events = {e.event_type for e in db.scalars(select(mouneh_models.MounehEvent).where(mouneh_models.MounehEvent.entity_id == line["id"]))}
            assert {"sale_recorded", "sale_cancelled"} <= events

    def test_cancelling_a_part_paid_sale_refunds_what_was_received(self, client):
        manager = _h(client)
        before = _books(client, manager)
        line = _sell(client, manager, payment_status="partial", amount_paid=4, buyer_name="Um Ali").json()
        r = client.post(f"{API}/mouneh/sales/{line['id']}/cancel", json={"reason": "She brought it back"}, headers=manager)
        assert r.status_code == 200, r.text
        assert _delta(before, _books(client, manager)) == {"revenue": 0, "mouneh": 0, "cash_in": 0, "owed": 0}
        refund = [p for p in client.get(f"{API}/finance/payments", headers=manager).json() if p["sale_id"] == line["sale_id"]]
        assert sorted(p["amount_received"] for p in refund) == [-4, 4], "the 4 received, and its refund"

    def test_cancelling_in_sales_and_finance_cancels_it_in_mouneh(self, client):
        manager = _h(client)
        stock = _stock(client, manager)["quantity_available"]
        line = _sell(client, manager).json()
        r = client.post(f"{API}/finance/sales/{line['sale_id']}/cancel", json={"reason": "Typed in twice"}, headers=manager)
        assert r.status_code == 200, r.text
        assert _mouneh_line(client, manager, line["id"])["status"] == "cancelled"
        assert _stock(client, manager)["quantity_available"] == stock, "the jar is back on the shelf"
        assert len([s for s in _sales(client, manager) if s["reversal_of_id"] == line["sale_id"]]) == 1

    def test_a_farm_shop_jar_is_in_the_visit_purchase_once_and_cancelled_in_farm_visits(self, client):
        manager = _h(client)
        before = _books(client, manager)
        r = client.post(f"{API}/visit-retail-sales", json={"lines": [{"finished_goods_stock_id": STOCK, "quantity": 2, "unit_price": 6.5}]},
                        headers=manager)
        assert r.status_code == 201, r.text
        visit_sale = r.json()["sale_id"]
        line = next(s for s in client.get(f"{API}/mouneh/sales", headers=manager).json() if s["sale_id"] == visit_sale)
        assert line["farm_shop"] is True
        assert _delta(before, _books(client, manager)) == {"revenue": 13, "mouneh": 0, "cash_in": 13, "owed": 0}, "counted once, as the visit's"
        assert client.post(f"{API}/mouneh/sales/{line['id']}/cancel", json={"reason": "x"}, headers=manager).status_code == 409


def _old_sale(db, *, quantity: float, price: float, days_ago: int, discount: float = 0.0, customer_id: str | None = None):
    """A Mouneh sale as the shop recorded it before this release: the line
    and the stock, and nothing in the books."""
    stock = db.get(mouneh_models.FinishedGoodsStock, STOCK)
    revenue = quantity * price - discount
    line = mouneh_models.MounehSaleLine(
        id=new_id(), farm_id=FARM, product_id=PRODUCT, batch_id=stock.batch_id, finished_goods_stock_id=stock.id, quantity=quantity,
        unit_price=price, discount=discount, customer_id=customer_id, channel="retail", cost_per_unit=stock.unit_cost, revenue=revenue,
        margin=revenue - quantity * stock.unit_cost, sold_at=datetime.now(timezone.utc) - timedelta(days=days_ago), sold_by="user-rami")
    db.add(line)
    stock.quantity_available -= quantity
    stock.quantity_sold += quantity
    return line


class TestHistoricalMounehSales:
    @pytest.fixture()
    def history(self, client, db_session):
        """Two shop sales from before this release, and a farm-shop jar
        whose visit purchase is in the books but which was never linked."""
        manager = _h(client)
        r = client.post(f"{API}/visit-retail-sales", json={"lines": [{"finished_goods_stock_id": STOCK, "quantity": 1, "unit_price": 6.5}]},
                        headers=manager)
        assert r.status_code == 201, r.text
        _session, factory = db_session
        with factory() as db:
            shop = db.scalar(select(mouneh_models.MounehSaleLine).where(mouneh_models.MounehSaleLine.sale_id == r.json()["sale_id"]))
            shop.sale_id = None  # as the farm shop recorded its jars before this release
            old = [_old_sale(db, quantity=2, price=6.5, days_ago=40), _old_sale(db, quantity=3, price=5, days_ago=12, discount=1)]
            db.commit()
            return {"lines": [o.id for o in old], "farm_shop": shop.id, "visit_sale": r.json()["sale_id"]}

    def test_the_dry_run_lists_what_is_missing_and_changes_nothing(self, client, history):
        manager = _h(client)
        before = _books(client, manager)
        r = client.get(f"{API}/finance/reconciliation/mouneh-sales", headers=manager)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["dry_run"] is True
        assert body["to_post"]["count"] == 2 and body["to_post"]["amount"] == 27, "13 + 14"
        assert {i["mouneh_sale_id"] for i in body["to_post"]["items"]} == set(history["lines"])
        assert [(i["mouneh_sale_id"], i["sale_id"]) for i in body["farm_shop"]["items"]] == [(history["farm_shop"], history["visit_sale"])]
        assert body["needs_review"] == []
        assert _delta(before, _books(client, manager)) == {"revenue": 0, "mouneh": 0, "cash_in": 0, "owed": 0}
        assert all(_mouneh_line(client, manager, i)["sale_id"] is None for i in history["lines"])

    def test_apply_posts_each_sale_once_on_its_own_day_and_running_it_again_changes_nothing(self, client, db_session, history):
        manager = _h(client)
        before = _books(client, manager)
        lines_before = {i: _mouneh_line(client, manager, i) for i in history["lines"]}

        r = client.post(f"{API}/finance/reconciliation/mouneh-sales", json={"payment_status": "paid"}, headers=manager)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["dry_run"] is False and body["to_post"]["count"] == 2 and len(body["posted"]) == 2
        assert _delta(before, _books(client, manager)) == {"revenue": 27, "mouneh": 27, "cash_in": 27, "owed": 0}
        for line_id, old in lines_before.items():
            now_line = _mouneh_line(client, manager, line_id)
            assert {k: now_line[k] for k in ("quantity", "unit_price", "discount", "revenue", "margin", "cost_per_unit", "sold_at")} == \
                   {k: old[k] for k in ("quantity", "unit_price", "discount", "revenue", "margin", "cost_per_unit", "sold_at")}, "never rewritten"
            sale = _canonical(client, manager, now_line)
            assert sale["amount"] == old["revenue"] and _when(sale["sold_at"]) == _when(old["sold_at"]), "on the day it was sold"
            assert sale["payment_status"] == "paid" and "reconciliation" in (sale["notes"] or "")
        assert _mouneh_line(client, manager, history["farm_shop"])["sale_id"] == history["visit_sale"], "linked, not posted again"

        again = client.post(f"{API}/finance/reconciliation/mouneh-sales", json={"payment_status": "paid"}, headers=manager).json()
        assert again["to_post"]["count"] == 0 and again["posted"] == [] and again["farm_shop"]["count"] == 0
        assert _delta(before, _books(client, manager))["revenue"] == 27

        _session, factory = db_session
        with factory() as db:
            posted = [a for a in db.scalars(select(models.AuditLog).where(models.AuditLog.action == "mouneh_sale_posted"))
                      if a.metadata_json.get("reconciliation")]
            assert sorted(a.metadata_json["mouneh_sale_id"] for a in posted) == sorted(history["lines"])
            assert db.scalar(select(models.AuditLog).where(models.AuditLog.action == "mouneh_sale_linked",
                                                           models.AuditLog.entity_id == history["farm_shop"])) is not None

    def test_history_can_be_posted_as_still_owed(self, client, history):
        manager = _h(client)
        before = _books(client, manager)
        r = client.post(f"{API}/finance/reconciliation/mouneh-sales", json={"payment_status": "pending"}, headers=manager)
        assert r.status_code == 200, r.text
        assert _delta(before, _books(client, manager)) == {"revenue": 27, "mouneh": 27, "cash_in": 0, "owed": 27}
        assert client.post(f"{API}/finance/reconciliation/mouneh-sales", json={"payment_status": "partial"}, headers=manager).status_code == 422

    def test_a_line_posted_meanwhile_is_not_posted_twice(self, client, db_session, history):
        """Two reconciliations at once: the second finds the line taken and
        leaves no second sale behind."""
        from app.services import mouneh_sales_service as service

        _session, factory = db_session
        first, second = factory(), factory()
        try:
            line_a = first.get(mouneh_models.MounehSaleLine, history["lines"][0])
            line_b = second.get(mouneh_models.MounehSaleLine, history["lines"][0])
            assert line_a.sale_id is None and line_b.sale_id is None
            assert service.post_line(first, line_a, "user-rami", payment_status="paid", reconciliation=True) is not None
            first.commit()
            assert service.post_line(second, line_b, "user-rami", payment_status="paid", reconciliation=True) is None
            second.commit()
        finally:
            first.close()
            second.close()
        with factory() as db:
            posted = db.scalars(select(models.Sale).where(models.Sale.product_type == "mouneh", models.Sale.notes.like("%reconciliation%"))).all()
            assert len(posted) == 1 and db.get(mouneh_models.MounehSaleLine, history["lines"][0]).sale_id == posted[0].id

    def test_the_demo_farm_has_nothing_missing(self, client):
        body = client.get(f"{API}/finance/reconciliation/mouneh-sales", headers=_h(client)).json()
        assert body["to_post"]["count"] == 0 and body["farm_shop"]["count"] == 0 and body["needs_review"] == []
