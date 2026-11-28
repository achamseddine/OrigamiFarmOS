"""Purchases in the farm's books (audit I-9, I-14).

A delivery is three separate facts:

* stock — what was accepted, valued at its price (500 kg delivered, 20 kg
  rejected: 480 kg at USD 0.50 = USD 240, never USD 250);
* the supplier's bill — what the farm owes for what it accepted, one bill
  per delivery (`expenses` linked to the lot), an asset bought, not a cost:
  feed is a cost when it is fed, medicine when it is received;
* cash — only what was actually paid, on the day it was paid: nothing for
  a delivery on credit, USD 100 when USD 100 is paid, the rest still owed.

Payments can be in parts, in USD or LBP at the day's rate, reversed when
recorded by mistake; a return to the supplier credits the bill; deliveries
recorded before this release are reconciled once by the manager (a dry run,
then the decisions applied), never paid on their behalf.
"""
from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from app.core.security import hash_password
from app.domain import feed_models as fm
from app.domain import finance_models as fin
from app.domain import models
from app.repositories.base import new_id
from tests.conftest import auth_headers

API = "/api/v1"
FARM = "farm-origami"
MANAGER = "rami@origami.farm"
WORKER = "karim.worker@origami.farm"
OTHER_MANAGER = "buyer@other.farm"
SUPPLIER = "Bekaa Grain Co."
NACL = "med-nacl"


def _h(client, email=MANAGER):
    return auth_headers(client, email)


def _corn(client, headers, name="Corn grain") -> str:
    r = client.post(f"{API}/feed-products", json={"name": name, "unit": "kg", "source_type": "purchased", "is_ingredient": True,
                                                  "ration_type": "raw_material", "category": "grain"}, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()["id"]


def _receive(client, headers, product_id, **body):
    payload = {"feed_product_id": product_id, "quantity": 500, "rejected_quantity": 20, "unit_cost": 0.5,
               "supplier_label": SUPPLIER, "payment": "credit", "invoice_reference": "INV-1001"}
    payload.update(body)
    return client.post(f"{API}/feed-lots/receive", json=payload, headers=headers)


def _pay(client, headers, bill_id, amount, **body):
    return client.post(f"{API}/finance/expenses/{bill_id}/payments", json={"amount": amount, **body}, headers=headers)


def _bill(client, headers, bill_id) -> dict:
    return next(e for e in client.get(f"{API}/finance/expenses", headers=headers).json() if e["id"] == bill_id)


def _books(client, headers) -> dict:
    """Profit and loss (last 12 months) and what the farm owes."""
    pl = client.get(f"{API}/finance/profit-loss", headers=headers).json()["totals"]
    owed = client.get(f"{API}/finance/owed", headers=headers).json()["payables"]
    return {"costs": pl["costs"], "cash_out": pl["cash_out"], "payable": owed["total"]}


def _delta(before: dict, after: dict) -> dict:
    return {k: round(after[k] - before[k], 2) for k in before}


def _lot(client, headers, lot_id) -> dict:
    return next(l for l in client.get(f"{API}/feed-lots", headers=headers).json() if l["id"] == lot_id)


@pytest.fixture()
def other_farm(db_session):
    session, _ = db_session
    session.add(models.Farm(id="farm-other", name="Other Farm", country="X", region="Y", timezone="UTC", default_currency="USD"))
    session.flush()
    session.add(models.User(id="user-other-buyer", farm_id="farm-other", name="Other", email=OTHER_MANAGER,
                            password_hash=hash_password("farmos123"), role="manager", language="en"))
    session.commit()
    return "farm-other"


class TestAcceptedStockAndTheSuppliersBill:
    def test_I9_I14_500_kg_with_20_rejected_on_credit_then_100_paid(self, client):
        manager = _h(client)
        corn = _corn(client, manager)
        before = _books(client, manager)

        r = _receive(client, manager, corn)
        assert r.status_code == 201, r.text
        lot = r.json()
        assert (lot["received_quantity"], lot["rejected_quantity"], lot["accepted_quantity"], lot["quantity_on_hand"]) == (500, 20, 480, 480)
        assert lot["accepted_value"] == 240, "480 kg × 0.50 — the 20 kg rejected are not stock"
        bill = lot["bill"]
        assert (bill["amount"], bill["balance_due"], bill["amount_paid"], bill["payment_status"]) == (240, 240, 0, "pending")
        assert _delta(before, _books(client, manager)) == {"costs": 0, "cash_out": 0, "payable": 240}, "bought on credit: owed, not paid"
        listed = _bill(client, manager, bill["id"])
        assert (listed["supplier_name"], listed["category"], listed["stock_purchase"], listed["reference"]) == (SUPPLIER, "feed", True, "INV-1001")

        paid = _pay(client, manager, bill["id"], 100)
        assert paid.status_code == 201, paid.text
        assert (paid.json()["amount"], paid.json()["kind"]) == (100, "payment")
        assert _delta(before, _books(client, manager)) == {"costs": 0, "cash_out": 100, "payable": 140}
        assert (_bill(client, manager, bill["id"])["balance_due"], _bill(client, manager, bill["id"])["payment_status"]) == (140, "partial")
        again = _lot(client, manager, lot["id"])
        assert (again["accepted_quantity"], again["quantity_on_hand"], again["accepted_value"]) == (480, 480, 240), "paying moves no stock"

        assert _pay(client, manager, bill["id"], 150).status_code == 422, "more than is owed"
        assert _pay(client, manager, bill["id"], 140).status_code == 201
        assert _delta(before, _books(client, manager)) == {"costs": 0, "cash_out": 240, "payable": 0}
        assert _bill(client, manager, bill["id"])["payment_status"] == "paid"

    def test_stock_report_values_the_accepted_quantity(self, client):
        manager = _h(client)
        corn = _corn(client, manager)
        _receive(client, manager, corn)
        row = next(r for r in client.get(f"{API}/reports/stock", headers=manager).json()["feed"] if r["name"] == "Corn grain")
        assert (row["on_hand"], row["value"]) == (480, 240)

    def test_paid_on_delivery_and_part_paid_at_delivery(self, client):
        manager = _h(client)
        corn = _corn(client, manager)
        before = _books(client, manager)
        cash = _receive(client, manager, corn, payment="paid", invoice_reference="INV-2001").json()["bill"]
        assert (cash["payment_status"], cash["balance_due"]) == ("paid", 0)
        assert _delta(before, _books(client, manager)) == {"costs": 0, "cash_out": 240, "payable": 0}
        part = _receive(client, manager, corn, payment="partial", paid_amount=60, invoice_reference="INV-2002", supplier_label="Zahle Mills").json()["bill"]
        assert (part["payment_status"], part["amount_paid"], part["balance_due"]) == ("partial", 60, 180)
        assert _delta(before, _books(client, manager)) == {"costs": 0, "cash_out": 300, "payable": 180}
        assert _receive(client, manager, corn, payment="partial", invoice_reference="INV-2003").status_code == 422, "how much was paid?"
        assert _receive(client, manager, corn, payment="credit", unit_cost=None, invoice_reference="INV-2004").status_code == 422, "no price, no bill"

    def test_feed_is_a_cost_when_fed_never_when_bought(self, client):
        manager = _h(client)
        corn = _corn(client, manager)
        def feed_lines():
            lines = client.get(f"{API}/finance/profit-loss", headers=manager).json()["cost_lines"]
            return {line["line"]: line["amount"] for line in lines if line["line"] in ("expense:feed", "feed_fed")}

        before, lines = _books(client, manager), feed_lines()
        _receive(client, manager, corn, payment="paid", invoice_reference="INV-3001")
        assert _delta(before, _books(client, manager))["costs"] == 0
        assert feed_lines() == lines, "the bill is stock, not a second feed cost"

    def test_a_retried_delivery_or_payment_is_recorded_once_and_a_repeat_is_asked(self, client):
        manager = _h(client)
        corn = _corn(client, manager)
        key = {**manager, "Idempotency-Key": str(uuid.uuid4())}
        first = _receive(client, key, corn)
        again = _receive(client, key, corn)
        assert first.status_code == again.status_code == 201 and again.json()["id"] == first.json()["id"]
        bill = first.json()["bill"]["id"]
        bills = [e for e in client.get(f"{API}/finance/expenses", headers=manager).json() if e.get("lot_id") == first.json()["id"]]
        assert [b["id"] for b in bills] == [bill], "one delivery, one bill"

        pay_key = {**manager, "Idempotency-Key": str(uuid.uuid4())}
        one = _pay(client, pay_key, bill, 100)
        two = _pay(client, pay_key, bill, 100)
        assert one.status_code == two.status_code == 201 and one.json()["id"] == two.json()["id"]
        assert _bill(client, manager, bill)["balance_due"] == 140
        typed_twice = _pay(client, manager, bill, 100)
        assert typed_twice.status_code == 409 and typed_twice.json()["detail"].startswith("Possible duplicate")
        assert _pay(client, manager, bill, 100, confirm_duplicate=True).status_code == 201
        assert _bill(client, manager, bill)["balance_due"] == 40

    def test_lbp_bill_paid_later_at_the_days_rate(self, client):
        manager = _h(client)
        corn = _corn(client, manager)
        ten_days = (date.today() - timedelta(days=10)).isoformat()
        assert client.post(f"{API}/finance/exchange-rates", json={"currency": "LBP", "rate_per_usd": 89500, "effective_date": ten_days},
                           headers=manager).status_code == 201
        received = (datetime.now(timezone.utc) - timedelta(days=5)).replace(microsecond=0).isoformat()
        lot = _receive(client, manager, corn, unit_cost=44750, currency="LBP", received_at=received).json()
        assert lot["unit_cost"] == 0.5, "the stock is valued in dollars at the delivery's rate"
        bill = lot["bill"]
        assert (bill["amount"], bill["original_amount"], bill["original_currency"], bill["exchange_rate"]) == (240, 21480000, "LBP", 89500)

        assert client.post(f"{API}/finance/exchange-rates", json={"currency": "LBP", "rate_per_usd": 90000}, headers=manager).status_code == 201
        before = _books(client, manager)
        paid = _pay(client, manager, bill["id"], 9000000, currency="LBP")
        assert paid.status_code == 201, paid.text
        assert (paid.json()["amount"], paid.json()["original_amount"], paid.json()["exchange_rate"]) == (100, 9000000, 90000)
        after = _books(client, manager)
        assert round(after["cash_out"] - before["cash_out"], 2) == 100, "the dollars that left, at today's rate"
        bill_now = _bill(client, manager, bill["id"])
        assert bill_now["balance_original"] == 12480000, "LBP still owed"
        assert bill_now["balance_due"] == pytest.approx(139.44, abs=0.01), "in dollars at the bill's rate"

    def test_two_suppliers_sell_the_same_corn_at_different_prices(self, client):
        manager = _h(client)
        corn = _corn(client, manager)
        a = _receive(client, manager, corn, quantity=300, rejected_quantity=0, unit_cost=0.5, invoice_reference="A-1").json()
        b = _receive(client, manager, corn, quantity=200, rejected_quantity=0, unit_cost=0.55, supplier_label="Zahle Mills",
                     invoice_reference="Z-1").json()
        assert (a["bill"]["amount"], b["bill"]["amount"]) == (150, 110)
        assert (a["unit_cost"], b["unit_cost"], a["supplier_label"], b["supplier_label"]) == (0.5, 0.55, SUPPLIER, "Zahle Mills")
        by_supplier = {s["supplier_name"]: s["amount"] for s in client.get(f"{API}/finance/owed", headers=manager).json()["payables"]["by_supplier"]}
        assert by_supplier[SUPPLIER] >= 150 and by_supplier["Zahle Mills"] == 110

    def test_a_delivery_rejected_in_full_owes_nothing(self, client):
        manager = _h(client)
        corn = _corn(client, manager)
        before = _books(client, manager)
        lot = _receive(client, manager, corn, rejected_quantity=500, invoice_reference="INV-REJ").json()
        assert (lot["accepted_quantity"], lot["bill"]) == (0, None)
        assert _delta(before, _books(client, manager)) == {"costs": 0, "cash_out": 0, "payable": 0}


class TestReturnsRefundsAndCorrections:
    def test_a_return_to_the_supplier_credits_the_bill(self, client):
        manager = _h(client)
        corn = _corn(client, manager)
        lot = _receive(client, manager, corn).json()
        r = client.post(f"{API}/feed-lots/{lot['id']}/return", json={"quantity": 80, "explanation": "Mouldy sacks found on opening"},
                        headers=manager)
        assert r.status_code == 200, r.text
        assert _lot(client, manager, lot["id"])["quantity_on_hand"] == 400
        bill = _bill(client, manager, lot["bill"]["id"])
        assert (bill["credited"], bill["balance_due"]) == (40, 200), "80 kg × 0.50 credited"
        assert client.post(f"{API}/feed-lots/{lot['id']}/return", json={"quantity": 500, "explanation": "all"},
                           headers=manager).status_code == 422, "not more than is left"

    def test_a_return_after_paying_is_refunded_by_the_supplier(self, client):
        manager = _h(client)
        corn = _corn(client, manager)
        lot = _receive(client, manager, corn, payment="paid", invoice_reference="INV-RF").json()
        before = _books(client, manager)
        client.post(f"{API}/feed-lots/{lot['id']}/return", json={"quantity": 80, "explanation": "Wrong grade"}, headers=manager)
        assert _bill(client, manager, lot["bill"]["id"])["balance_due"] == -40, "the supplier owes 40 back"
        refund = _pay(client, manager, lot["bill"]["id"], 40, kind="refund")
        assert refund.status_code == 201, refund.text
        assert _delta(before, _books(client, manager)) == {"costs": 0, "cash_out": -40, "payable": 0}
        assert _pay(client, manager, lot["bill"]["id"], 1, kind="refund").status_code == 422, "nothing more to refund"

    def test_a_payment_recorded_by_mistake_is_reversed(self, client, db_session):
        manager = _h(client)
        corn = _corn(client, manager)
        bill = _receive(client, manager, corn).json()["bill"]
        before = _books(client, manager)
        pay = _pay(client, manager, bill["id"], 100).json()
        assert client.post(f"{API}/finance/supplier-payments/{pay['id']}/reverse", json={"reason": " "}, headers=manager).status_code == 422
        r = client.post(f"{API}/finance/supplier-payments/{pay['id']}/reverse", json={"reason": "Typed on the wrong bill"}, headers=manager)
        assert r.status_code == 200, r.text
        assert _delta(before, _books(client, manager)) == {"costs": 0, "cash_out": 0, "payable": 0}
        assert _bill(client, manager, bill["id"])["balance_due"] == 240
        assert client.post(f"{API}/finance/supplier-payments/{pay['id']}/reverse", json={"reason": "again"}, headers=manager).status_code == 409
        _session, factory = db_session
        with factory() as db:
            rows = db.scalars(select(fin.SupplierPayment).where(fin.SupplierPayment.expense_id == bill["id"])).all()
            assert sorted(p.amount for p in rows) == [-100, 100], "the payment stays on file, undone by a negative row"
            assert db.scalar(select(models.AuditLog).where(models.AuditLog.action == "supplier_payment_reversed")) is not None

    def test_a_bill_with_payments_is_not_cancelled_until_they_are_reversed(self, client):
        manager = _h(client)
        corn = _corn(client, manager)
        bill = _receive(client, manager, corn).json()["bill"]
        _pay(client, manager, bill["id"], 50)
        assert client.post(f"{API}/finance/expenses/{bill['id']}/cancel", json={"reason": "duplicate"}, headers=manager).status_code == 409

    def test_mark_paid_settles_the_rest_once(self, client):
        manager = _h(client)
        corn = _corn(client, manager)
        bill = _receive(client, manager, corn).json()["bill"]
        before = _books(client, manager)
        _pay(client, manager, bill["id"], 100)
        assert client.post(f"{API}/finance/expenses/{bill['id']}/paid", json={}, headers=manager).status_code == 200
        assert _delta(before, _books(client, manager)) == {"costs": 0, "cash_out": 240, "payable": -240}


class TestMedicinePurchases:
    def test_medicine_on_credit_is_a_cost_of_what_was_accepted_and_cash_when_paid(self, client):
        manager = _h(client)
        item = NACL
        before = _books(client, manager)
        r = client.post(f"{API}/pharmacy/lots/receive", json={"inventory_item_id": item, "quantity": 10, "rejected_quantity": 2, "unit_cost": 3,
                                                              "supplier_label": "Vet Supplies SARL", "payment": "credit",
                                                              "invoice_reference": "VS-77", "expiry_date": "2027-12-31T00:00:00Z", "lot_code": "NACL-VS77"},
                        headers=manager)
        assert r.status_code == 201, r.text
        bill = r.json()["bill"]
        assert (bill["amount"], bill["balance_due"]) == (24, 24), "8 accepted × 3"
        assert _delta(before, _books(client, manager)) == {"costs": 24, "cash_out": 0, "payable": 24}, "a cost when received, once"
        _pay(client, manager, bill["id"], 24)
        assert _delta(before, _books(client, manager)) == {"costs": 24, "cash_out": 24, "payable": 0}


class TestWhoAndWhichFarm:
    def test_only_finance_pays_and_only_this_farm(self, client, other_farm):
        manager = _h(client)
        corn = _corn(client, manager)
        bill = _receive(client, manager, corn).json()["bill"]
        assert _pay(client, _h(client, WORKER), bill["id"], 10).status_code == 403
        assert _pay(client, _h(client, OTHER_MANAGER), bill["id"], 10).status_code == 404
        assert client.get(f"{API}/finance/reconciliation/purchases", headers=_h(client, WORKER)).status_code == 403


def _legacy_lot(db, product_id, *, quantity=500.0, rejected=20.0, unit_cost=0.5, days_ago=20, supplier="Old Grain Co.") -> fm.FeedLot:
    """A delivery as the farm recorded it before this release: the lot and
    its stock, no bill."""
    from app.services import feed_inventory_service as inv

    product = db.get(fm.FeedProduct, product_id)
    return inv.receive(db, product, quantity=quantity, rejected_quantity=rejected, unit_cost=unit_cost, supplier_label=supplier,
                       received_at=datetime.now(timezone.utc) - timedelta(days=days_ago), user_id="user-rami")


class TestDeliveriesFromBeforeThisRelease:
    @pytest.fixture()
    def history(self, client, db_session):
        manager = _h(client)
        corn = _corn(client, manager)
        expense = client.post(f"{API}/finance/expenses", json={"category": "feed", "description": "Corn, 480 kg", "amount": 240,
                                                               "supplier_name": "Old Grain Co.", "payment_status": "paid",
                                                               "incurred_at": (datetime.now(timezone.utc) - timedelta(days=19)).isoformat()},
                              headers=manager).json()
        _session, factory = db_session
        with factory() as db:
            matched = _legacy_lot(db, corn)
            alone = _legacy_lot(db, corn, quantity=100, rejected=0, unit_cost=0.6, days_ago=40, supplier="Unknown seller")
            db.commit()
            return {"matched": matched.id, "alone": alone.id, "expense": expense["id"]}

    def test_the_dry_run_proposes_and_writes_nothing(self, client, history):
        manager = _h(client)
        before = _books(client, manager)
        body = client.get(f"{API}/finance/reconciliation/purchases", headers=manager).json()
        items = {i["lot_id"]: i for i in body["items"]}
        assert items[history["matched"]]["proposal"] == "link" and items[history["matched"]]["expense_id"] == history["expense"]
        assert items[history["matched"]]["accepted_value"] == 240
        assert items[history["alone"]]["proposal"] == "decide", "no payment on record: the manager decides, nothing is invented"
        assert body["dry_run"] is True
        assert _books(client, manager) == before

    def test_applying_the_decisions_counts_each_once_and_running_again_finds_nothing(self, client, history):
        manager = _h(client)
        before = _books(client, manager)
        r = client.post(f"{API}/finance/reconciliation/purchases", json={"decisions": [
            {"lot_id": history["matched"], "action": "link", "expense_id": history["expense"]},
            {"lot_id": history["alone"], "action": "on_credit"},
        ]}, headers=manager)
        assert r.status_code == 200, r.text
        after = _books(client, manager)
        assert round(after["costs"] - before["costs"], 2) == -240, "the linked feed expense is stock, no longer a second cost"
        assert round(after["cash_out"] - before["cash_out"], 2) == 0, "its payment is counted once, as before"
        assert round(after["payable"] - before["payable"], 2) == 60, "100 kg × 0.60 now owed, as decided"
        linked = _bill(client, manager, history["expense"])
        assert (linked["amount"], linked["lot_id"], linked["stock_purchase"]) == (240, history["matched"], True), "the amount is never rewritten"
        again = client.get(f"{API}/finance/reconciliation/purchases", headers=manager).json()
        assert all(i["lot_id"] not in (history["matched"], history["alone"]) for i in again["items"])
        assert client.post(f"{API}/finance/reconciliation/purchases", json={"decisions": [
            {"lot_id": history["alone"], "action": "on_credit"}]}, headers=manager).json()["applied"] == []

    def test_the_demo_farm_has_no_unbilled_delivery(self, client):
        body = client.get(f"{API}/finance/reconciliation/purchases", headers=_h(client)).json()
        assert body["items"] == []
