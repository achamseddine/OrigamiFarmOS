"""Ordering and receiving feed (master prompt Package 2; PROCUREMENT-SCHEMA
§4, §7, §8), through the API on the demo farm.

The chain: two suppliers quote barley at different prices → Karim asks to
buy 1,000 kg → the manager approves → an order to the cheaper supplier at
its quote → approved → delivered in two parts, 20 kg rejected as wet → each
delivery a barley lot with its supplier, price, day and quality, and a bill
for what was accepted → paid in parts → the order's match: ordered 1,000 kg
(USD 460.00), received 1,000, accepted 980, billed USD 450.80, paid, owed.
A mix made from the delivered barley traces back to the order, the receipt
and the supplier. Partial orders closed short, refusals, permissions, the
farm boundary and retries.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app.domain import feed_models as fm
from app.domain import models
from app.domain import procurement_models as prm
from tests.conftest import auth_headers

API = "/api/v1"
BARLEY = "fp-barley"
WORKER = "karim.worker@origami.farm"


def _h(client, email="rami@origami.farm", **extra):
    return {**auth_headers(client, email), **extra}


@pytest.fixture()
def suppliers(db_session):
    session, _ = db_session
    bekaa = models.Supplier(id="sup-bekaa", farm_id="farm-origami", name="Bekaa Grain Co.")
    zahle = models.Supplier(id="sup-zahle", farm_id="farm-origami", name="Zahle Feeds")
    session.add_all([bekaa, zahle])
    session.commit()
    return bekaa.id, zahle.id


def _barley_item(session) -> str:
    session.expire_all()
    return session.get(fm.FeedProduct, BARLEY).inventory_item_id


def _quote(client, supplier_id, price, currency="USD", email="rami@origami.farm"):
    return client.post(f"{API}/procurement/supplier-items", headers=_h(client, email),
                       json={"supplier_id": supplier_id, "feed_product_id": BARLEY, "unit_price": price, "currency": currency, "purchase_uom": "kg"})


def _approved_request(client, quantity=1000):
    r = client.post(f"{API}/procurement/requisitions", headers=_h(client, WORKER), json={
        "lines": [{"feed_product_id": BARLEY, "requested_quantity": quantity, "uom_code": "kg"}], "justification": "Barley for the next mixes", "submit": True})
    assert r.status_code == 201, r.text
    req = r.json()
    r = client.post(f"{API}/procurement/requisitions/{req['id']}/approve", headers=_h(client), json={"comments": "Go ahead"})
    assert r.status_code == 200, r.text
    return req


def _order(client, supplier_id, *, quantity=1000, unit_price=None, requisition_id=None, approve=True, currency="USD", rate=None, email="rami@origami.farm"):
    line = {"feed_product_id": BARLEY, "quantity": quantity, "unit": "kg"}
    if unit_price is not None:
        line["unit_price"] = unit_price
    body = {"supplier_id": supplier_id, "lines": [line], "requisition_id": requisition_id, "approve": approve, "currency": currency}
    if rate:
        body["exchange_rate"] = rate
    return client.post(f"{API}/procurement/purchase-orders", headers=_h(client, email), json=body)


def _receive(client, po, received, rejected=0, *, reason=None, quality="good", note=None, email=WORKER, key=None, payment=None):
    extra = {"Idempotency-Key": key} if key else {}
    body = {"lines": [{"purchase_order_line_id": po["lines"][0]["id"], "received_quantity": received, "rejected_quantity": rejected,
                       "rejection_reason": reason, "quality_grade": quality}], "delivery_note_no": note}
    if payment:
        body["payment"] = payment
    return client.post(f"{API}/procurement/purchase-orders/{po['id']}/receive", headers=_h(client, email, **extra), json=body)


def _match(client, po):
    r = client.get(f"{API}/procurement/purchase-orders/{po['id']}/match", headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()


class TestTheProcurementChain:
    def test_two_suppliers_one_order_two_deliveries_bills_payments_and_the_match(self, client, db_session, suppliers):
        session, _ = db_session
        bekaa, zahle = suppliers
        assert _quote(client, bekaa, 0.50).status_code == 201
        assert _quote(client, zahle, 0.46).status_code == 201
        quotes = client.get(f"{API}/procurement/supplier-items", params={"feed_product_id": BARLEY}, headers=_h(client)).json()
        assert [(q["supplier_name"], q["unit_price"]) for q in quotes] == [("Zahle Feeds", 0.46), ("Bekaa Grain Co.", 0.5)], "cheapest first"

        req = _approved_request(client)
        r = _order(client, zahle, requisition_id=req["id"])
        assert r.status_code == 201, r.text
        po = r.json()
        assert (po["status"], po["po_no"], po["lines"][0]["unit_price"], po["total_amount"]) == ("approved", "PO-000001", 0.46, 460.0)
        assert client.get(f"{API}/procurement/requisitions/{req['id']}", headers=_h(client)).json()["status"] == "ordered"
        assert session.scalar(select(func.count(prm.ProcurementApproval.id)).where(prm.ProcurementApproval.document_id == po["id"])) == 1

        # The first delivery: 600 kg, 20 kg wet and rejected.
        r = _receive(client, po, 600, 20, reason="wet bags", quality="fair", note="DN-1")
        assert r.status_code == 201, r.text
        first = r.json()
        assert first["order"]["status"] == "partially_received"
        assert first["order"]["lines"][0]["remaining_quantity"] == 400
        lot = session.get(fm.FeedLot, first["receipt"]["lines"][0]["feed_lot_id"])
        session.refresh(lot)
        assert (lot.supplier_id, lot.supplier_label, lot.unit_cost, lot.received_quantity, lot.accepted_quantity, lot.rejected_quantity, lot.quality_grade) == (
            zahle, "Zahle Feeds", 0.46, 600, 580, 20, "fair")
        assert lot.reference == "DN-1"

        # The rest: 400 kg.
        r = _receive(client, po, 400, note="DN-2")
        assert r.status_code == 201, r.text
        assert r.json()["order"]["status"] == "received"
        assert client.get(f"{API}/procurement/requisitions/{req['id']}", headers=_h(client)).json()["status"] == "received"

        m = _match(client, po)
        line = m["lines"][0]
        assert (line["ordered"], line["received"], line["accepted"], line["rejected"], line["outstanding"]) == (1000, 1000, 980, 20, 0)
        assert m["totals"] == {"ordered_value": 460.0, "accepted_value": 450.8, "billed": 450.8, "paid": 0.0, "owed": 450.8}
        assert m["state"] == "delivered_awaiting_payment" and m["problems"] == [] and m["rejections"] is True
        assert [x["receipt_no"] for x in m["receipts"]] == ["GR-000001", "GR-000002"]

        # Paid in parts, on the bills (v0.8.9).
        bills = [rl["expense_id"] for rec in m["receipts"] for rl in rec["lines"]]
        assert client.post(f"{API}/finance/expenses/{bills[0]}/payments", headers=_h(client), json={"amount": 266.8}).status_code == 201
        assert client.post(f"{API}/finance/expenses/{bills[1]}/payments", headers=_h(client), json={"amount": 100}).status_code == 201
        m = _match(client, po)
        assert (m["totals"]["paid"], m["totals"]["owed"]) == (366.8, 84.0)
        assert client.post(f"{API}/finance/expenses/{bills[1]}/payments", headers=_h(client), json={"amount": 84}).status_code == 201
        assert _match(client, po)["state"] == "complete"

    def test_a_mix_made_from_the_delivered_barley_traces_back_to_the_order_and_supplier(self, client, db_session, suppliers):
        session, _ = db_session
        _bekaa, zahle = suppliers
        po = _order(client, zahle, unit_price=0.46).json()
        lot_id = _receive(client, po, 500, note="DN-9").json()["receipt"]["lines"][0]["feed_lot_id"]
        lot_trace = client.get(f"{API}/feed-lots/{lot_id}/trace", headers=_h(client)).json()
        assert lot_trace["lot"]["origin"]["po_no"] == po["po_no"] and lot_trace["lot"]["origin"]["supplier_name"] == "Zahle Feeds"
        formula = next(f for f in client.get(f"{API}/feed-formulas", headers=_h(client)).json() if f["code"] == "DAIRY-MIX-24L")
        batch = client.post(f"{API}/feed-batches", headers=_h(client), json={"formula_id": formula["id"], "target_quantity": 500}).json()
        actuals = [{"feed_product_id": c["feed_product_id"], "actual_quantity": c["target_quantity"]} for c in batch["components"]]
        for a in actuals:
            if a["feed_product_id"] == BARLEY:
                a["lot_id"] = lot_id
        assert any(a["feed_product_id"] == BARLEY for a in actuals), "the dairy mix uses barley"
        done = client.post(f"{API}/feed-batches/{batch['id']}/complete", headers=_h(client), json={"actual_quantity": 500, "actuals": actuals})
        assert done.status_code == 200, done.text
        out = client.get(f"{API}/feed-lots/{done.json()['output_lot_id']}/trace", headers=_h(client)).json()
        barley = next(u for u in out["upstream_ingredient_lots"] if u["lot_id"] == lot_id)
        assert (barley["supplier_id"], barley["unit_cost"], barley["origin"]["po_no"], barley["origin"]["receipt_no"], barley["origin"]["delivery_note_no"]) == (
            zahle, 0.46, po["po_no"], "GR-000001", "DN-9")

    def test_an_order_in_lbp_keeps_its_lbp_bill_and_values_the_stock_in_dollars(self, client, db_session, suppliers):
        session, _ = db_session
        bekaa, _zahle = suppliers
        po = _order(client, bekaa, quantity=200, unit_price=45000, currency="LBP", rate=90000).json()
        assert po["total_amount"] == 9_000_000
        rec = _receive(client, po, 200).json()["receipt"]
        lot = session.get(fm.FeedLot, rec["lines"][0]["feed_lot_id"])
        assert lot.unit_cost == pytest.approx(0.5)
        bill = session.get(models.Expense, rec["lines"][0]["expense_id"])
        assert (bill.original_currency, bill.original_amount, bill.amount) == ("LBP", 9_000_000, pytest.approx(100.0))


class TestPartialOrdersAndRefusals:
    def test_an_order_closed_short_owes_only_what_came(self, client, suppliers):
        bekaa, _ = suppliers
        po = _order(client, bekaa, quantity=500, unit_price=0.5).json()
        assert _receive(client, po, 300).status_code == 201
        r = client.post(f"{API}/procurement/purchase-orders/{po['id']}/close", headers=_h(client), json={"reason": "Out of barley until spring"})
        assert r.status_code == 200, r.text
        m = _match(client, po)
        assert (m["state"], m["lines"][0]["outstanding"], m["totals"]["owed"]) == ("closed_short", 0, 150.0)
        assert _receive(client, po, 50).status_code == 409, "nothing more is received on a closed order"

    def test_more_than_ordered_less_than_nothing_and_a_draft_are_refused(self, client, suppliers):
        bekaa, _ = suppliers
        po = _order(client, bekaa, quantity=100, unit_price=0.5).json()
        r = _receive(client, po, 120)
        assert r.status_code == 422 and "more than the 100 kg ordered" in r.json()["detail"], r.text
        assert _receive(client, po, 105).status_code == 201, "a little over (a full bag) is accepted"
        r = _receive(client, po, 10, 12, reason="torn")
        assert r.status_code in (409, 422)
        draft = _order(client, bekaa, quantity=100, unit_price=0.5, approve=False).json()
        assert draft["status"] == "draft"
        r = _receive(client, draft, 50)
        assert r.status_code == 409 and "received once approved" in r.json()["detail"]
        rejected_no_reason = _order(client, bekaa, quantity=100, unit_price=0.5).json()
        r = _receive(client, rejected_no_reason, 100, 10)
        assert r.status_code == 422 and "say why" in r.json()["detail"].lower()

    def test_an_order_with_goods_received_is_closed_not_cancelled(self, client, suppliers):
        bekaa, _ = suppliers
        po = _order(client, bekaa, quantity=100, unit_price=0.5).json()
        _receive(client, po, 40)
        r = client.post(f"{API}/procurement/purchase-orders/{po['id']}/cancel", headers=_h(client), json={"reason": "changed my mind"})
        assert r.status_code == 409 and "close it instead" in r.json()["detail"]
        fresh = _order(client, bekaa, quantity=100, unit_price=0.5).json()
        r = client.post(f"{API}/procurement/purchase-orders/{fresh['id']}/cancel", headers=_h(client), json={"reason": "ordered twice"})
        assert r.status_code == 200 and r.json()["status"] == "cancelled"

    def test_an_lbp_quote_without_a_farm_rate_is_listed_last_not_an_error(self, client, db_session, suppliers):
        session, _ = db_session
        from app.domain import finance_models as fin

        session.query(fin.ExchangeRate).delete()
        session.commit()
        bekaa, zahle = suppliers
        _quote(client, bekaa, 0.5)
        _quote(client, zahle, 41000, currency="LBP")
        r = client.get(f"{API}/procurement/supplier-items", params={"feed_product_id": BARLEY}, headers=_h(client))
        assert r.status_code == 200, r.text
        assert [(q["supplier_name"], q["unit_price_usd"]) for q in r.json()] == [("Bekaa Grain Co.", 0.5), ("Zahle Feeds", None)]

    def test_no_price_no_order_and_a_quote_in_another_currency_is_not_assumed(self, client, suppliers):
        bekaa, zahle = suppliers
        r = _order(client, bekaa, quantity=100)
        assert r.status_code == 422 and "no USD price from Bekaa Grain Co." in r.json()["detail"]
        _quote(client, zahle, 41000, currency="LBP")
        r = _order(client, zahle, quantity=100)
        assert r.status_code == 422, "an LBP quote does not price a USD order"
        assert _order(client, zahle, quantity=100, currency="LBP", rate=89500).json()["lines"][0]["unit_price"] == 41000


class TestWhoAndWhichFarm:
    def test_a_worker_drafts_and_receives_but_does_not_place_orders_or_set_prices(self, client, suppliers):
        bekaa, _ = suppliers
        assert _quote(client, bekaa, 0.5, email=WORKER).status_code == 403
        draft = _order(client, bekaa, quantity=100, unit_price=0.5, approve=False, email=WORKER)
        assert draft.status_code == 201, draft.text
        r = client.post(f"{API}/procurement/purchase-orders/{draft.json()['id']}/approve", headers=_h(client, WORKER))
        assert r.status_code == 403
        assert _order(client, bekaa, quantity=100, unit_price=0.5, approve=True, email=WORKER).status_code == 403
        placed = client.post(f"{API}/procurement/purchase-orders/{draft.json()['id']}/approve", headers=_h(client))
        assert placed.status_code == 200
        assert _receive(client, placed.json(), 100, email=WORKER).status_code == 201, "receiving against an approved order is the staff's"
        r = client.post(f"{API}/procurement/purchase-orders/{draft.json()['id']}/close", headers=_h(client, WORKER), json={"reason": "x"})
        assert r.status_code == 403

    def test_another_farm_sees_none_of_it(self, client, db_session, suppliers):
        session, _ = db_session
        bekaa, _ = suppliers
        po = _order(client, bekaa, quantity=100, unit_price=0.5).json()
        from app.core.security import hash_password

        session.add(models.Farm(id="farm-other", name="Other", country="Lebanon", region="North", timezone="Asia/Beirut", default_currency="USD"))
        session.add(models.User(id="user-other", farm_id="farm-other", name="Other Manager", email="m@other.farm", password_hash=hash_password("farmos123"),
                                role="manager", language="en"))
        session.commit()
        other = _h(client, "m@other.farm")
        assert client.get(f"{API}/procurement/purchase-orders/{po['id']}", headers=other).status_code == 404
        assert client.get(f"{API}/procurement/purchase-orders", headers=other).json() == []
        r = client.post(f"{API}/procurement/purchase-orders/{po['id']}/receive", headers=other,
                        json={"lines": [{"purchase_order_line_id": po["lines"][0]["id"], "received_quantity": 10}]})
        assert r.status_code == 404
        assert client.post(f"{API}/procurement/purchase-orders", headers=other, json={"supplier_id": bekaa, "lines": [
            {"feed_product_id": BARLEY, "quantity": 1, "unit_price": 1}]}).status_code == 404

    def test_a_retried_delivery_is_received_once(self, client, db_session, suppliers):
        session, _ = db_session
        bekaa, _ = suppliers
        po = _order(client, bekaa, quantity=100, unit_price=0.5).json()
        first = _receive(client, po, 60, key="delivery-once")
        again = _receive(client, po, 60, key="delivery-once")
        assert (first.status_code, again.status_code) == (201, 201)
        assert first.json()["receipt"]["id"] == again.json()["receipt"]["id"]
        assert session.scalar(select(func.count(prm.GoodsReceipt.id)).where(prm.GoodsReceipt.purchase_order_id == po["id"])) == 1
