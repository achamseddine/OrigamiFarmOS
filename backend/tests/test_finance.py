"""Origami's financials (v0.8.0) and the Sales and Stock reports.

* Any sale (eggs, produce, animals…) and any expense or bill, in USD or in
  LBP at the rate the manager set (or the rate given); the LBP amount and
  the rate stay on the record, every total is in USD.
* Mark paid; cancel with a reason — a sale is undone by a negative row,
  an expense is kept out of the totals; nothing is deleted.
* Who owes what: customers' unpaid sales, the farm's unpaid bills.
* Profit and loss per month and activity: sales, expenses, feed fed,
  medicine received; cash in and out.
* Reports: everything sold in a period; everything in stock now.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

from sqlalchemy import select

from app.core.duplicates import PREFIX
from app.domain import models
from tests.conftest import auth_headers

API = "/api/v1"
FARM = "farm-origami"
WORKER = "karim.worker@origami.farm"


def _h(client, email="rami@origami.farm"):
    return auth_headers(client, email)


def _rate(client, headers, rate=89500.0, **body):
    return client.post(f"{API}/finance/exchange-rates", json={"currency": "LBP", "rate_per_usd": rate, **body}, headers=headers)


def _sell(client, headers, **body):
    payload = {"product_type": "eggs", "product_label": "Eggs (tray of 30)", "quantity": 10, "unit": "tray", "unit_price": 6,
               "buyer_name": "Abu Karim shop", "payment_status": "paid"}
    payload.update(body)
    return client.post(f"{API}/finance/sales", json=payload, headers=headers)


def _spend(client, headers, **body):
    payload = {"category": "fuel", "description": "Diesel for the tractor", "amount": 120, "supplier_name": "Bekaa Fuel", "payment_status": "paid"}
    payload.update(body)
    return client.post(f"{API}/finance/expenses", json=payload, headers=headers)


# --------------------------------------------------------------- the rate
def test_the_manager_sets_the_lbp_rate_and_it_has_a_history(client):
    manager = _h(client)
    assert client.get(f"{API}/finance/exchange-rates", headers=manager).json()["current"]["LBP"] is None
    first = _rate(client, manager, 89000, effective_date=(date.today() - timedelta(days=10)).isoformat())
    assert first.status_code == 201, first.text
    assert _rate(client, manager, 89500).status_code == 201
    rates = client.get(f"{API}/finance/exchange-rates", headers=manager).json()
    assert rates["base"] == "USD"
    assert rates["current"]["LBP"]["rate_per_usd"] == 89500
    assert [r["rate_per_usd"] for r in rates["history"]][:2] == [89500, 89000], "the earlier rate stays for its days"
    assert _rate(client, manager, 0).status_code == 422
    assert _rate(client, manager, 90000, effective_date=(date.today() + timedelta(days=2)).isoformat()).status_code == 422
    assert _rate(client, _h(client, WORKER), 90000).status_code == 403


# --------------------------------------------------------------- a sale
def test_any_sale_in_usd_is_revenue_with_its_buyer(client, db_session):
    session, _ = db_session
    manager = _h(client)
    sale = _sell(client, manager).json()
    assert (sale["amount"], sale["currency"], sale["unit_price"], sale["buyer_name"]) == (60, "USD", 6, "Abu Karim shop")
    assert (sale["status"], sale["payment_status"], sale["activity"]) == ("recorded", "paid", "poultry")
    listed = client.get(f"{API}/finance/sales", headers=manager).json()
    assert listed[0]["id"] == sale["id"]
    summary = client.get(f"{API}/reports/daily-summary", params={"farm_id": FARM}, headers=manager).json()
    assert any(b["product_type"] == "eggs" for b in summary["sales_breakdown"])
    session.expire_all()
    audit = session.scalars(select(models.AuditLog).where(models.AuditLog.entity_type == "sale", models.AuditLog.entity_id == sale["id"])).all()
    assert [a.action for a in audit] == ["sale_recorded"]


def test_a_sale_in_lbp_uses_the_days_rate_or_the_rate_given(client):
    manager = _h(client)
    no_rate = _sell(client, manager, currency="LBP", unit_price=537000, quantity=1, product_label="Tray")
    assert no_rate.status_code == 422 and "exchange rate" in no_rate.json()["detail"]
    _rate(client, manager, 89500)
    sale = _sell(client, manager, currency="LBP", unit_price=537000, quantity=1, product_label="Tray").json()
    assert (sale["original_amount"], sale["original_currency"], sale["exchange_rate"]) == (537000, "LBP", 89500)
    assert sale["amount"] == 6.0, "537,000 LBP at 89,500 = 6 USD"
    own = _sell(client, manager, currency="LBP", total=900000, quantity=None, unit_price=None, product_label="Old hen", exchange_rate=90000,
                product_type="animals").json()
    assert (own["amount"], own["exchange_rate"], own["activity"]) == (10.0, 90000, "livestock")


def test_milk_and_mouneh_are_sold_where_their_stock_is(client):
    manager = _h(client)
    assert _sell(client, manager, product_type="milk").status_code == 422
    assert _sell(client, manager, product_type="mouneh").status_code == 422
    assert _sell(client, manager, product_type="cars").status_code == 422
    assert _sell(client, manager, quantity=None, unit_price=None).status_code == 422, "no price, no total"
    assert _sell(client, manager, sold_at=(datetime.now(timezone.utc) + timedelta(days=2)).isoformat()).status_code == 422


def test_to_be_paid_then_paid_then_owed_no_more(client):
    manager = _h(client)
    sale = _sell(client, manager, payment_status="pending", buyer_name="Hotel Massabki").json()
    owed = client.get(f"{API}/finance/owed", headers=manager).json()["receivables"]
    assert any(i["id"] == sale["id"] and i["days_outstanding"] == 0 for i in owed["items"])
    assert any(b["buyer_name"] == "Hotel Massabki" and b["amount"] >= 60 for b in owed["by_buyer"])
    paid = client.post(f"{API}/finance/sales/{sale['id']}/paid", json={}, headers=manager).json()
    assert paid["payment_status"] == "paid" and paid["paid_at"]
    owed = client.get(f"{API}/finance/owed", headers=manager).json()["receivables"]
    assert all(i["id"] != sale["id"] for i in owed["items"])


def test_a_cancelled_sale_stays_on_file_and_is_reversed(client):
    manager = _h(client)
    sale = _sell(client, manager, payment_status="pending").json()
    assert client.post(f"{API}/finance/sales/{sale['id']}/cancel", json={"reason": ""}, headers=manager).status_code == 422
    cancelled = client.post(f"{API}/finance/sales/{sale['id']}/cancel", json={"reason": "typed twice"}, headers=manager).json()
    assert (cancelled["status"], cancelled["cancel_reason"]) == ("cancelled", "typed twice")
    rows = client.get(f"{API}/finance/sales", headers=manager).json()
    reversal = next(r for r in rows if r["reversal_of_id"] == sale["id"])
    assert (reversal["status"], reversal["amount"]) == ("reversal", -60)
    assert client.post(f"{API}/finance/sales/{sale['id']}/cancel", json={"reason": "again"}, headers=manager).status_code == 409
    assert client.post(f"{API}/finance/sales/{sale['id']}/paid", json={}, headers=manager).status_code == 409
    owed = client.get(f"{API}/finance/owed", headers=manager).json()["receivables"]
    assert all(i["id"] != sale["id"] for i in owed["items"]), "a cancelled sale is owed by nobody"


def test_cancelling_a_milk_sale_from_finance_puts_the_milk_back(client):
    manager = _h(client)
    tank = client.get(f"{API}/production/milk-tank", headers=manager).json()["balance_l"]
    milk = client.post(f"{API}/production/milk-sales", json={"liters": 30, "price_per_liter": 0.5, "buyer_name": "Dairy"}, headers=manager).json()
    revenue = next(r for r in client.get(f"{API}/finance/sales", headers=manager).json() if r["product_type"] == "milk" and r["quantity"] == 30)
    assert revenue["buyer_name"] == "Dairy" and revenue["unit_price"] == 0.5
    assert client.post(f"{API}/finance/sales/{revenue['id']}/cancel", json={"reason": "wrong day"}, headers=manager).status_code == 200
    assert client.get(f"{API}/production/milk-tank", headers=manager).json()["balance_l"] == tank
    assert next(s for s in client.get(f"{API}/production/milk-sales", headers=manager).json() if s["id"] == milk["id"])["status"] == "cancelled"


def test_the_same_sale_twice_is_asked(client):
    manager = _h(client)
    assert _sell(client, manager).status_code == 201
    again = _sell(client, manager)
    assert again.status_code == 409 and again.json()["detail"].startswith(PREFIX)
    assert _sell(client, manager, confirm_duplicate=True).status_code == 201


# ------------------------------------------------------------ expenses
def test_an_expense_in_lbp_and_a_bill_to_pay(client, db_session):
    session, _ = db_session
    manager = _h(client)
    _rate(client, manager, 89500)
    paid = _spend(client, manager, currency="LBP", amount=8950000).json()
    assert (paid["amount"], paid["original_amount"], paid["supplier_name"], paid["payment_status"]) == (100, 8950000, "Bekaa Fuel", "paid")
    due = (date.today() - timedelta(days=3)).isoformat() + "T00:00:00Z"
    bill = _spend(client, manager, category="veterinary", description="Dr. Haddad visit", amount=150, supplier_name="Dr. Haddad",
                  payment_status="pending", due_date=due, incurred_at=(datetime.now(timezone.utc) - timedelta(days=10)).isoformat()).json()
    assert bill["activity"] == "livestock" and bill["due_date"]
    payables = client.get(f"{API}/finance/owed", headers=manager).json()["payables"]
    item = next(i for i in payables["items"] if i["id"] == bill["id"])
    assert item["overdue_days"] >= 3 and payables["overdue"] >= 150
    assert client.post(f"{API}/finance/expenses/{bill['id']}/paid", json={}, headers=manager).json()["payment_status"] == "paid"
    assert all(i["id"] != bill["id"] for i in client.get(f"{API}/finance/owed", headers=manager).json()["payables"]["items"])
    session.expire_all()
    assert session.scalar(select(models.Supplier).where(models.Supplier.farm_id == FARM, models.Supplier.name == "Bekaa Fuel")) is not None


def test_a_cancelled_expense_is_out_of_the_totals(client):
    manager = _h(client)
    before = client.get(f"{API}/reports/daily-summary", params={"farm_id": FARM}, headers=manager).json()["expenses_today"]
    e = _spend(client, manager, amount=77, category="repairs").json()
    assert client.get(f"{API}/reports/daily-summary", params={"farm_id": FARM}, headers=manager).json()["expenses_today"] == before + 77
    assert client.post(f"{API}/finance/expenses/{e['id']}/cancel", json={"reason": "not ours"}, headers=manager).json()["status"] == "cancelled"
    assert client.get(f"{API}/reports/daily-summary", params={"farm_id": FARM}, headers=manager).json()["expenses_today"] == before
    assert client.post(f"{API}/finance/expenses/{e['id']}/paid", json={}, headers=manager).status_code == 409
    assert _spend(client, manager, category="gambling").status_code == 422
    assert _spend(client, manager, amount=0).status_code == 422


def test_an_employee_without_finance_records_no_money(client):
    worker = _h(client, WORKER)
    assert _sell(client, worker).status_code == 403
    assert _spend(client, worker).status_code == 403
    assert client.get(f"{API}/finance/owed", headers=worker).status_code == 403
    assert client.get(f"{API}/finance/profit-loss", headers=worker).status_code == 403


# ------------------------------------------------------- profit and loss
def test_profit_and_loss_per_month_and_activity(client):
    manager = _h(client)
    _sell(client, manager, quantity=20, unit_price=6)  # 120 eggs revenue
    _spend(client, manager, amount=50, category="fuel")
    pl = client.get(f"{API}/finance/profit-loss", headers=manager).json()
    assert pl["currency"] == "USD" and len(pl["months"]) in (12, 13)
    this = pl["months"][-1]
    assert this["revenue_by_activity"]["poultry"] >= 120
    assert this["cost_lines"]["expense:fuel"] >= 50
    assert this["profit"] == round(this["revenue"] - this["costs"], 2)
    assert pl["totals"]["profit"] == round(pl["totals"]["revenue"] - pl["totals"]["costs"], 2)
    assert any(a["activity"] == "poultry" for a in pl["by_activity"])
    assert this["cash_in"] >= 120 and this["cash_out"] >= 50
    one = client.get(f"{API}/finance/profit-loss", params={"start": date.today().replace(day=1).isoformat(), "end": date.today().isoformat()},
                     headers=manager).json()
    assert len(one["months"]) == 1
    assert client.get(f"{API}/finance/profit-loss", params={"start": "2020-01-01", "end": date.today().isoformat()}, headers=manager).status_code == 422


# -------------------------------------------------------------- reports
def test_the_sales_report_shows_what_was_sold(client):
    manager = _h(client)
    _sell(client, manager, payment_status="pending", buyer_name="Chtaura market")
    report = client.get(f"{API}/reports/sales", headers=manager).json()
    assert report["kind"] == "sales" and report["kpis"]["sales"] >= 1
    eggs = next(p for p in report["by_product"] if p["product"] == "Eggs (tray of 30)")
    assert eggs["quantity"] >= 10 and eggs["average_price"] == 6
    assert any(b["buyer"] == "Chtaura market" and b["unpaid"] >= 60 for b in report["by_buyer"])
    assert any(u["buyer"] == "Chtaura market" for u in report["unpaid"])
    assert report["kpis"]["revenue"] == round(sum(s["amount"] for s in report["sales"]), 2)


def test_the_stock_report_shows_what_is_in_stock(client):
    manager = _h(client)
    report = client.get(f"{API}/reports/stock", headers=manager).json()
    assert report["kind"] == "stock" and report["as_of"]
    assert report["feed"] and all("on_hand" in f and "value" in f for f in report["feed"])
    assert report["medicine"], "the demo farm's pharmacy"
    assert report["mouneh_goods"], "the demo farm's makdous"
    assert report["milk"]["in_tank_l"] == client.get(f"{API}/production/milk-tank", headers=manager).json()["balance_l"]
    assert report["kpis"]["value"] is not None and report["kpis"]["lines"] > 0


def test_who_reads_the_sales_and_stock_reports(client, db_session):
    session, _ = db_session
    # Karim keeps only milk recording (and his baseline): no money, no stock areas.
    for row in session.scalars(select(models.UserModulePermission).where(models.UserModulePermission.user_id == "user-worker-1")):
        if row.module_code in ("inventory", "feed_nutrition", "animal_health", "mouneh_inventory", "mouneh_production"):
            session.delete(row)
    session.commit()
    worker = _h(client, WORKER)
    assert client.get(f"{API}/reports/sales", headers=worker).status_code == 403
    stock = client.get(f"{API}/reports/stock", headers=worker)
    assert stock.status_code == 200, "milk in the tank is his area"
    body = stock.json()
    assert body["sections"] == ["milk"]
    assert body["feed"] == [] and body["medicine"] == [] and body["mouneh_goods"] == []
    assert body["kpis"]["value"] is None, "no money without Sales, Finance or Reports"
    assert set(client.get(f"{API}/reports/stock", headers=_h(client)).json()["sections"]) >= {"feed", "medicine", "milk"}
