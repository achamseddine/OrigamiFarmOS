"""Selling milk from the tank, and the farm's period reports (v0.7.9).

* The tank is worked out from the records: stored milk − sold + adjustments.
* A milk sale writes the farm's revenue (Sales & Finance sees it); paid or
  pending; cancelled with a reason, reversed — never deleted.
* Selling more than the tank holds needs the manager; a count puts the
  tank right. An employee without Sales / Finance does not sell.
* Reports for a period — milk, feed, herd, finance — from the canonical
  records, money only for those who may see it.
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


def _tank(client, headers) -> float:
    return client.get(f"{API}/production/milk-tank", headers=headers).json()["balance_l"]


def _sell(client, headers, **body):
    return client.post(f"{API}/production/milk-sales", json={"liters": 100, "price_per_liter": 0.6, "buyer_name": "Bekaa Dairy", **body}, headers=headers)


# ------------------------------------------------------------- the tank
def test_the_tank_is_stored_milk_less_what_was_sold(client):
    manager = _h(client)
    tank = client.get(f"{API}/production/milk-tank", headers=manager).json()
    assert tank["balance_l"] == round(tank["stored_l"] - tank["sold_l"] + tank["adjusted_l"], 3)
    before = tank["balance_l"]
    assert client.post(f"{API}/production/milk", json={"animal_id": BELLA, "session": "midday", "liters": 12}, headers=manager).status_code == 201
    assert _tank(client, manager) == before + 12, "stored milk goes into the tank"
    sold = _sell(client, manager, liters=40)
    assert sold.status_code == 201, sold.text
    assert _tank(client, manager) == before + 12 - 40


# --------------------------------------------------------------- a sale
def test_a_milk_sale_is_revenue_in_sales_and_finance(client, db_session):
    session, _ = db_session
    manager = _h(client)
    sale = _sell(client, manager, liters=150, price_per_liter=0.55, payment_status="paid").json()
    assert (sale["amount"], sale["buyer_name"], sale["payment_status"]) == (82.5, "Bekaa Dairy", "paid")
    revenue = [s for s in client.get(f"{API}/sales", params={"farm_id": FARM}, headers=manager).json() if s["product_type"] == "milk"]
    assert any(s["amount"] == 82.5 and s["quantity"] == 150 and s["unit"] == "L" for s in revenue)
    summary = client.get(f"{API}/reports/daily-summary", params={"farm_id": FARM}, headers=manager).json()
    assert summary["revenue_today"] >= 82.5
    assert any(b["product_type"] == "milk" for b in summary["sales_breakdown"])
    session.expire_all()
    buyers = session.scalars(select(models.Customer).where(models.Customer.farm_id == FARM, models.Customer.name == "Bekaa Dairy")).all()
    assert len(buyers) == 1, "the buyer is added to the farm's customers"
    again = _sell(client, manager, liters=10, buyer_name="bekaa dairy")
    assert again.json()["customer_id"] == buyers[0].id, "found again by name, whatever the case"
    audit = session.scalars(select(models.AuditLog).where(models.AuditLog.entity_type == "milk_sale", models.AuditLog.entity_id == sale["id"])).all()
    assert [a.action for a in audit] == ["milk_sold"], "every sale is in the audit history"


def test_to_be_paid_then_paid(client, db_session):
    session, _ = db_session
    manager = _h(client)
    sale = _sell(client, manager, payment_status="pending").json()
    summary = client.get(f"{API}/reports/daily-summary", params={"farm_id": FARM}, headers=manager).json()
    assert summary["pending_payments"] >= 60
    paid = client.post(f"{API}/production/milk-sales/{sale['id']}/paid", headers=manager)
    assert paid.json()["payment_status"] == "paid" and paid.json()["paid_at"]
    session.expire_all()
    milk_revenue = session.scalars(select(models.Sale).where(models.Sale.farm_id == FARM, models.Sale.product_type == "milk")).all()
    assert all(s.payment_status == "paid" for s in milk_revenue if s.amount == 60)


def test_a_cancelled_sale_stays_on_file_reversed(client):
    manager = _h(client)
    before = _tank(client, manager)
    sale = _sell(client, manager, liters=30).json()
    assert client.post(f"{API}/production/milk-sales/{sale['id']}/cancel", json={"reason": ""}, headers=manager).status_code == 422
    cancelled = client.post(f"{API}/production/milk-sales/{sale['id']}/cancel", json={"reason": "Typed 30 for 3"}, headers=manager)
    assert cancelled.json()["status"] == "cancelled"
    assert _tank(client, manager) == before, "the milk is back in the tank"
    milk = [s for s in client.get(f"{API}/sales", params={"farm_id": FARM}, headers=manager).json() if s["product_type"] == "milk"]
    assert sorted(s["amount"] for s in milk if abs(s["amount"]) == 18) == [-18, 18], "reversed, both kept"
    report = client.get(f"{API}/reports/milk", headers=manager).json()
    assert all(s["liters"] != 30 for s in report["sales"]), "a cancelled sale is not sold milk"
    assert client.post(f"{API}/production/milk-sales/{sale['id']}/cancel", json={"reason": "again"}, headers=manager).status_code == 409


def test_more_than_the_tank_holds_needs_the_manager(client):
    manager = _h(client)
    tank = _tank(client, manager)
    over = _sell(client, manager, liters=tank + 500)
    assert over.status_code == 422 and "tank" in over.json()["detail"], over.text
    anyway = _sell(client, manager, liters=tank + 500, allow_negative=True)
    assert anyway.status_code == 201, anyway.text
    assert _tank(client, manager) < 0, "the records are behind: a count puts them right"
    counted = client.post(f"{API}/production/milk-tank/adjustments", json={"reason": "count", "counted_level": 120}, headers=manager)
    assert counted.status_code == 201, counted.text
    assert _tank(client, manager) == 120
    spoiled = client.post(f"{API}/production/milk-tank/adjustments", json={"reason": "spoiled", "liters": 20, "notes": "Power cut"}, headers=manager)
    assert spoiled.json()["liters"] == -20
    assert _tank(client, manager) == 100


def test_the_same_collection_twice_is_asked(client):
    manager = _h(client)
    assert _sell(client, manager, liters=77).status_code == 201
    again = _sell(client, manager, liters=77)
    assert again.status_code == 409 and again.json()["detail"].startswith(PREFIX), again.text
    assert _sell(client, manager, liters=77, confirm_duplicate=True).status_code == 201


def test_an_employee_without_sales_does_not_sell_or_adjust(client):
    worker = _h(client, WORKER)
    assert client.get(f"{API}/production/milk-tank", headers=worker).status_code == 200, "they see the tank"
    refused = _sell(client, worker)
    assert refused.status_code == 403 and "Selling milk" in refused.json()["detail"], refused.text
    assert client.post(f"{API}/production/milk-tank/adjustments", json={"reason": "spoiled", "liters": 5}, headers=worker).status_code == 403


def test_a_sale_cannot_be_dated_in_the_future_or_be_empty(client):
    manager = _h(client)
    tomorrow = (date.today() + timedelta(days=2)).isoformat() + "T08:00:00Z"
    assert _sell(client, manager, sold_at=tomorrow).status_code == 422
    assert _sell(client, manager, liters=0).status_code == 422
    assert _sell(client, manager, price_per_liter=-1).status_code == 422


# ------------------------------------------------------------- reports
def test_the_milk_report_reads_the_records(client):
    manager = _h(client)
    _sell(client, manager, liters=50, price_per_liter=0.5, payment_status="pending")
    report = client.get(f"{API}/reports/milk", headers=manager).json()
    assert report["days"] == 30 and len(report["by_day"]) == 30
    assert report["kpis"]["total_l"] == round(sum(d["total"] for d in report["by_day"]), 1)
    assert any(a["animal_id"] == BELLA for a in report["by_animal"])
    assert report["kpis"]["sold_l"] >= 50 and report["kpis"]["revenue"] >= 25 and report["kpis"]["pending_amount"] >= 25
    assert report["sales"] and report["by_buyer"][0]["buyer"]


def test_a_report_for_a_chosen_period(client):
    manager = _h(client)
    end = date.today()
    start = end - timedelta(days=6)
    report = client.get(f"{API}/reports/milk", params={"start": start.isoformat(), "end": end.isoformat()}, headers=manager).json()
    assert (report["start"], report["end"], report["days"]) == (start.isoformat(), end.isoformat(), 7)
    assert client.get(f"{API}/reports/milk", params={"start": end.isoformat(), "end": start.isoformat()}, headers=manager).status_code == 422
    assert client.get(f"{API}/reports/milk", params={"start": (end - timedelta(days=400)).isoformat()}, headers=manager).status_code == 422
    assert client.get(f"{API}/reports/weather", headers=manager).status_code == 404


def test_feed_herd_and_finance_reports(client):
    manager = _h(client)
    feed = client.get(f"{API}/reports/feed", headers=manager).json()
    assert feed["kpis"]["feedings"] > 0 and feed["used"] and feed["stock"]
    assert feed["kpis"]["feed_used_kg"] == round(sum(u["quantity"] for u in feed["used"] if u["unit"] == "kg"), 1)
    herd = client.get(f"{API}/reports/herd", headers=manager).json()
    assert herd["kpis"]["on_farm"] == sum(s["on_farm"] for s in herd["by_species"]) > 0
    _sell(client, manager, liters=10, price_per_liter=1.0)
    finance = client.get(f"{API}/reports/finance", headers=manager).json()
    assert any(r["product_type"] == "milk" for r in finance["revenue_by_type"])
    assert finance["kpis"]["margin"] == round(finance["kpis"]["revenue"] - finance["kpis"]["expenses"], 2)


def test_who_reads_which_report(client):
    worker = _h(client, WORKER)
    milk = client.get(f"{API}/reports/milk", headers=worker)
    assert milk.status_code == 200
    assert "sales" not in milk.json() and "revenue" not in milk.json()["kpis"], "no money without Sales or Finance"
    assert client.get(f"{API}/reports/feed", headers=worker).status_code == 200
    assert client.get(f"{API}/reports/finance", headers=worker).status_code == 403
