"""The farm's milking routine (v0.8.1).

Two milkings a day, morning and afternoon. After each: the calves get their
milk and the collector takes the rest at the agreed price; he pays once a
week for all of it.

* The manager sets the collector, his price (USD or LBP) and calls the
  second milking "afternoon".
* Whoever milks hands the milking over: litres to the calves, litres to the
  collector — buyer and price come from the settings, the sale is to be paid.
* The weekly payment settles every collection at once; a difference with
  what they came to (a deduction, a bonus) is kept as its own revenue row.
"""
from __future__ import annotations

from datetime import date, timedelta

from sqlalchemy import select

from app.core.duplicates import PREFIX
from app.domain import models
from tests.conftest import auth_headers

API = "/api/v1"
FARM = "farm-origami"
BELLA = "cow-744"
WORKER = "karim.worker@origami.farm"


def _h(client, email="rami@origami.farm"):
    return auth_headers(client, email)


def _routine(client, headers, **body):
    payload = {"collector_name": "Abu Ali (collector)", "collector_price": 0.5, "collector_currency": "USD", "second_milking": "afternoon"}
    payload.update(body)
    return client.put(f"{API}/production/milk-routine", json=payload, headers=headers)


def _milk(client, headers, liters, session="morning"):
    r = client.post(f"{API}/production/milk", json={"animal_id": BELLA, "session": session, "liters": liters, "destination": "stored",
                                                         "confirm_duplicate": True}, headers=headers)
    assert r.status_code == 201, r.text


def _handover(client, headers, **body):
    payload = {"session": "morning", "calves_l": 4, "collected_l": 8}
    payload.update(body)
    return client.post(f"{API}/production/milk-handovers", json=payload, headers=headers)


def test_the_manager_sets_the_collector_and_calls_the_second_milking_afternoon(client):
    manager = _h(client)
    r = _routine(client, manager)
    assert r.status_code == 200, r.text
    assert r.json() == {"second_milking": "afternoon", "collector_name": "Abu Ali (collector)", "collector_price": 0.5, "collector_currency": "USD"}
    assert client.get(f"{API}/production/milk-routine", headers=manager).json()["second_milking"] == "afternoon"
    assert _routine(client, manager, collector_price=0).status_code == 422
    assert _routine(client, manager, second_milking="night").status_code == 422
    assert _routine(client, _h(client, WORKER)).status_code == 403, "the price is the manager's"


def test_a_milking_handed_over_calves_then_the_collector(client, db_session):
    session, _ = db_session
    manager = _h(client)
    _routine(client, manager)
    _milk(client, manager, 12)
    tank = client.get(f"{API}/production/milk-tank", headers=manager).json()["balance_l"]
    worker = _h(client, WORKER)  # records milk; does not sell or set prices
    r = _handover(client, worker)
    assert r.status_code == 201, r.text
    sale = r.json()["sale"]
    assert (sale["liters"], sale["price_per_liter"], sale["amount"], sale["buyer_name"], sale["payment_status"]) == (8, 0.5, 4.0, "Abu Ali (collector)", "pending")
    assert client.get(f"{API}/production/milk-tank", headers=manager).json()["balance_l"] == round(tank - 12, 3)
    milking = next(m for m in client.get(f"{API}/production/milk-handovers", headers=manager).json()["milkings"]
                   if m["day"] == date.today().isoformat() and m["session"] == "morning")
    assert (milking["calves_l"], milking["collected_l"], milking["handed_over"], milking["paid"]) == (4, 8, True, False)
    assert milking["milked_l"] >= 12
    # The calves' milk is on the milk report.
    report = client.get(f"{API}/reports/milk", headers=manager).json()
    assert report["kpis"]["calves_l"] >= 4 and report["second_milking"] == "afternoon"
    session.expire_all()
    audit = session.scalars(select(models.AuditLog).where(models.AuditLog.action == "milk_to_calves")).all()
    assert audit, "the calves' milk is in the audit history"


def test_the_same_milking_twice_is_asked(client):
    manager = _h(client)
    _routine(client, manager)
    _milk(client, manager, 20)
    assert _handover(client, manager).status_code == 201
    again = _handover(client, manager)
    assert again.status_code == 409 and again.json()["detail"].startswith(PREFIX)
    assert _handover(client, manager, confirm_duplicate=True).status_code == 201


def test_a_handover_needs_the_collector_set_and_milk_in_the_tank(client):
    manager = _h(client)
    no_collector = _handover(client, manager)
    assert no_collector.status_code == 422 and "collector" in no_collector.json()["detail"]
    assert _handover(client, manager, collected_l=0, calves_l=3).status_code == 201, "calves only: no collector needed"
    _routine(client, manager)
    tank = client.get(f"{API}/production/milk-tank", headers=manager).json()["balance_l"]
    worker = _h(client, WORKER)
    too_much = _handover(client, worker, collected_l=tank + 50, session="evening")
    assert too_much.status_code == 422
    assert _handover(client, worker, collected_l=tank + 50, session="evening", allow_negative=True).status_code == 403
    assert _handover(client, manager, collected_l=tank + 50, session="evening", allow_negative=True).status_code == 201
    assert _handover(client, manager, calves_l=0, collected_l=0).status_code == 422
    assert _handover(client, manager, day=(date.today() + timedelta(days=1)).isoformat()).status_code == 422
    assert _handover(client, manager, session="night").status_code == 422


def test_a_collector_paid_in_lbp_uses_the_rate(client):
    manager = _h(client)
    _routine(client, manager, collector_price=44750, collector_currency="LBP")
    _milk(client, manager, 10)
    assert _handover(client, manager).status_code == 422, "no rate set yet"
    client.post(f"{API}/finance/exchange-rates", json={"currency": "LBP", "rate_per_usd": 89500}, headers=manager)
    sale = _handover(client, manager).json()["sale"]
    assert sale["price_per_liter"] == 0.5 and sale["amount"] == 4.0
    revenue = next(s for s in client.get(f"{API}/finance/sales", headers=manager).json() if s["buyer_name"] == "Abu Ali (collector)")
    assert (revenue["original_amount"], revenue["original_currency"], revenue["exchange_rate"]) == (358000, "LBP", 89500)


def test_the_weekly_payment_settles_every_collection_and_keeps_the_difference(client, db_session):
    session, _ = db_session
    manager = _h(client)
    _routine(client, manager)
    _milk(client, manager, 60)
    ids = []
    for i, s in enumerate(("morning", "evening")):
        for back in range(2):
            r = _handover(client, manager, session=s, day=(date.today() - timedelta(days=back)).isoformat(), calves_l=2, collected_l=10)
            assert r.status_code == 201, r.text
    owed = client.get(f"{API}/finance/owed", headers=manager).json()["receivables"]
    collector = [i for i in owed["items"] if i["buyer_name"] == "Abu Ali (collector)"]
    assert len(collector) == 4 and sum(i["amount"] for i in collector) == 20.0
    ids = [i["id"] for i in collector]
    paid = client.post(f"{API}/finance/payments", json={"sale_ids": ids, "amount_received": 19}, headers=manager)
    assert paid.status_code == 201, paid.text
    p = paid.json()
    assert (p["sales_count"], p["amount_due"], p["amount_received"], p["difference"]) == (4, 20.0, 19.0, -1.0)
    owed = client.get(f"{API}/finance/owed", headers=manager).json()["receivables"]
    assert not [i for i in owed["items"] if i["buyer_name"] == "Abu Ali (collector)"], "the week is settled"
    milkings = client.get(f"{API}/production/milk-handovers", headers=manager).json()["milkings"]
    assert all(m["paid"] for m in milkings if m["collected_l"])
    sales = client.get(f"{API}/finance/sales", headers=manager).json()
    diff = next(s for s in sales if s["product_label"] == "Payment difference")
    assert (diff["amount"], diff["payment_status"], diff["payment_id"]) == (-1.0, "paid", p["id"])
    assert all(s["payment_id"] == p["id"] for s in sales if s["id"] in ids)
    assert client.get(f"{API}/finance/payments", headers=manager).json()[0]["id"] == p["id"]
    again = client.post(f"{API}/finance/payments", json={"sale_ids": ids[:1], "amount_received": 5}, headers=manager)
    assert again.status_code == 409, "already paid"


def test_one_payment_is_from_one_buyer(client):
    manager = _h(client)
    a = client.post(f"{API}/finance/sales", json={"product_type": "eggs", "quantity": 1, "unit_price": 6, "buyer_name": "A", "payment_status": "pending"},
                    headers=manager).json()
    b = client.post(f"{API}/finance/sales", json={"product_type": "eggs", "quantity": 2, "unit_price": 6, "buyer_name": "B", "payment_status": "pending"},
                    headers=manager).json()
    assert client.post(f"{API}/finance/payments", json={"sale_ids": [a["id"], b["id"]], "amount_received": 18}, headers=manager).status_code == 422
    assert client.post(f"{API}/finance/payments", json={"sale_ids": [], "amount_received": 1}, headers=manager).status_code == 422
    ok = client.post(f"{API}/finance/payments", json={"sale_ids": [a["id"]], "amount_received": 6}, headers=manager).json()
    assert ok["difference"] == 0
    assert client.post(f"{API}/finance/payments", json={"sale_ids": [b["id"]], "amount_received": 12}, headers=_h(client, WORKER)).status_code == 403
