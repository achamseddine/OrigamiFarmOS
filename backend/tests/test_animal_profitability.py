"""Each dairy cow's profitability (master prompt Package 3), on a small
synthetic farm built record by record so every figure can be checked by hand.

Rosa and Daisy are in the milking herd. Over the last week, from the
canonical records:

  milk       Rosa 3 days × (10 L AM + 8 L PM) = 54 L saleable, and 6 L PM
             withheld; Daisy 3 × (7 + 5) = 36 L
  sales      90 L sold for USD 72 → USD 0.80 a litre
  feed       two herd feedings, 2 heads, USD 10 each (USD 5 a head each);
             Rosa fed USD 6 more on her own; Daisy 5 kg with no price
  vet        a USD 12 vet visit for Rosa
  overheads  USD 30 dairy labour, shared by days in milk (3 and 3); USD 10
             electricity for the whole farm: unallocated

So Rosa: value 54 × 0.80 = 43.20, costs 16 + 12 + 15 = 43, margin 0.20;
Daisy: value 28.80, costs 10 + 15 = 25, margin 3.80 — with her unpriced
feed labelled, not counted as free.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from app.core.security import hash_password
from app.domain import feed_models as fm
from app.domain import livestock_models as lm
from app.domain import milk_models as mm
from app.domain import models
from app.repositories.base import new_id
from tests.conftest import auth_headers

API = "/api/v1"
FARM = "farm-p3"
TZ = ZoneInfo("Asia/Beirut")
FEED = "fp-dairy-concentrate"  # a feed product row the components can name


def _local(days_ago: int, hour: int) -> datetime:
    d = datetime.now(TZ).date() - timedelta(days=days_ago)
    return datetime(d.year, d.month, d.day, hour, tzinfo=TZ).astimezone(timezone.utc)


@pytest.fixture()
def farm(db_session):
    session, _ = db_session
    session.add(models.Farm(id=FARM, name="Profit Test Farm", country="Lebanon", region="Bekaa", timezone="Asia/Beirut", default_currency="USD"))
    # The farm first: PostgreSQL checks each row's farm as it is inserted.
    session.flush()
    session.add_all([
        models.User(id="p3-manager", farm_id=FARM, name="P3 Manager", email="manager@p3.farm", password_hash=hash_password("farmos123"), role="manager", language="en"),
        models.User(id="p3-worker", farm_id=FARM, name="P3 Worker", email="worker@p3.farm", password_hash=hash_password("farmos123"), role="worker", language="en"),
    ])
    for aid, tag, name in (("p3-rosa", "P31", "Rosa"), ("p3-daisy", "P32", "Daisy")):
        session.add(models.Animal(id=aid, farm_id=FARM, tag=tag, name=name, species="cow", breed="Holstein", sex="F", lactating=True))
    session.add(models.Flock(id="p3-herd", farm_id=FARM, name="Milking herd", species="cow", count=2))
    session.flush()
    for aid in ("p3-rosa", "p3-daisy"):
        session.add(lm.AnimalGroupMembership(id=new_id(), farm_id=FARM, animal_group_id="p3-herd", animal_id=aid, valid_from=_local(30, 6)))

    def milk(aid, days_ago, session_code, liters, destination="stored", release="saleable"):
        session.add(models.MilkRecord(id=new_id(), animal_id=aid, session=session_code, liters=liters, destination=destination,
                                      recorded_at=_local(days_ago, 6 if session_code == "morning" else 17), withdrawal_check="clear",
                                      release_status=release))

    for day in (1, 2, 3):
        milk("p3-rosa", day, "morning", 10)
        milk("p3-rosa", day, "evening", 8)
        milk("p3-daisy", day, "morning", 7)
        milk("p3-daisy", day, "evening", 5)
    milk("p3-rosa", 2, "midday", 6, destination="withheld", release="not_for_sale")
    milk("p3-rosa", 18, "morning", 9)  # an older week with no sales at all
    session.add(mm.MilkSale(id=new_id(), farm_id=FARM, sold_at=_local(1, 19), liters=90, price_per_liter=0.8, amount=72.0, currency="USD",
                            buyer_name="Dairy Co-op", payment_status="paid", status="recorded"))

    def feeding(subject_type, subject_id, days_ago, cost, *, heads=None, kg=10.0):
        e = fm.FeedingEvent(id=new_id(), farm_id=FARM, subject_type=subject_type, subject_id=subject_id, occurred_at=_local(days_ago, 7),
                            event_type="offered", head_count=heads, status="recorded")
        session.add(e)
        session.flush()
        session.add(fm.FeedingEventComponent(id=new_id(), event_id=e.id, feed_product_id=FEED, quantity_offered=kg, unit="kg", cost=cost))

    feeding("group", "p3-herd", 1, 10.0, heads=2)
    feeding("group", "p3-herd", 2, 10.0, heads=2)
    feeding("animal", "p3-rosa", 2, 6.0)
    feeding("animal", "p3-daisy", 3, None, kg=5.0)

    def expense(category, amount, *, activity=None, linked=None):
        session.add(models.Expense(id=new_id(), farm_id=FARM, category=category, description=f"{category} test", amount=amount, currency="USD",
                                   incurred_at=_local(2, 12), payment_status="paid", status="recorded", activity=activity,
                                   linked_entity_type="animal" if linked else None, linked_entity_id=linked))

    expense("veterinary", 12.0, linked="p3-rosa")
    expense("labor", 30.0, activity="dairy")
    expense("utilities", 10.0, activity="general")
    session.commit()
    return session


def _report(client, email="manager@p3.farm", **params):
    return client.get(f"{API}/reports/profitability", headers=auth_headers(client, email), params=params)


def _week(client, **params):
    today = datetime.now(TZ).date()
    r = _report(client, start=(today - timedelta(days=6)).isoformat(), end=today.isoformat(), **params)
    assert r.status_code == 200, r.text
    return r.json()


class TestEachCowsProfitability:
    def test_milk_value_costs_and_margin_cow_by_cow(self, client: TestClient, farm):
        out = _week(client)
        by = {a["name"]: a for a in out["animals"]}
        rosa, daisy = by["Rosa"], by["Daisy"]
        assert out["milk_price"] == {"price_per_liter": 0.8, "basis": "period_average", "liters_sold": 90.0, "revenue": 72.0}
        assert (rosa["am_l"], rosa["pm_l"], rosa["total_l"], rosa["saleable_l"], rosa["days_in_milk"]) == (30.0, 30.0, 60.0, 54.0, 3)
        assert (daisy["am_l"], daisy["pm_l"], daisy["total_l"], daisy["saleable_l"]) == (21.0, 15.0, 36.0, 36.0)
        assert (rosa["milk_value"], rosa["sales_revenue"]) == (43.2, 43.2)
        assert (daisy["milk_value"], daisy["sales_revenue"]) == (28.8, 28.8)
        assert (rosa["feed_cost"], rosa["feed_cost_own"], rosa["feed_cost_group"]) == (16.0, 6.0, 10.0)
        assert rosa["feed_cost_per_liter"] == pytest.approx(16 / 60, abs=1e-3)
        assert (rosa["vet_expenses"], rosa["labour_cost"], rosa["power_cost"]) == (12.0, 15.0, 0.0)
        assert (rosa["known_costs"], rosa["margin"]) == (43.0, 0.2)
        assert (daisy["feed_cost"], daisy["labour_cost"], daisy["known_costs"], daisy["margin"]) == (10.0, 15.0, 25.0, 3.8)
        assert [a["name"] for a in out["animals"]] == ["Daisy", "Rosa"], "best margin first"

    def test_unknown_costs_are_labelled_never_counted_as_free(self, client, farm):
        out = _week(client)
        by = {a["name"]: a for a in out["animals"]}
        assert by["Daisy"]["feed_unpriced_kg"] == 5.0 and "feed_without_price" in by["Daisy"]["unknown"]
        assert by["Rosa"]["unknown"] == []
        assert out["unallocated"] == {"labour": 0.0, "power": 10.0}, "the farm's electricity is not any cow's"
        # A week with milk but no sale, and none before it: no price, no margin.
        today = datetime.now(TZ).date()
        r = _report(client, start=(today - timedelta(days=20)).isoformat(), end=(today - timedelta(days=15)).isoformat())
        old = r.json()
        rosa = old["animals"][0]
        assert (old["milk_price"]["basis"], rosa["milk_value"], rosa["margin"], rosa["sales_revenue"]) == ("unavailable", None, None, None)
        assert "milk_price" in rosa["unknown"] and old["totals"]["margin"] is None

    def test_the_cows_add_up_to_the_canonical_records(self, client, farm):
        out = _week(client)
        rec = out["reconciliation"]
        assert rec["milk_l"] == {"canonical": 96.0, "attributed": 96.0}
        assert rec["own_feed_cost"] == {"canonical": 6.0, "attributed": 6.0}
        assert rec["group_feed_cost"] == {"canonical": 20.0, "attributed_to_these_animals": 20.0, "to_other_heads": 0.0}
        assert rec["dairy_overheads"]["labour"] == 30.0
        t = out["totals"]
        assert (t["total_l"], t["milk_value"], t["sales_revenue"], t["feed_cost"], t["known_costs"], t["margin"]) == (96.0, 72.0, 72.0, 26.0, 68.0, 4.0)
        assert out["rules"]["group_feed"].startswith("A group feeding's cost")

    def test_a_trend_week_by_week(self, client, farm):
        rosa = next(a for a in _week(client)["animals"] if a["name"] == "Rosa")
        assert sum(w["liters"] for w in rosa["trend"]) == 60.0
        assert all(w["margin"] is not None for w in rosa["trend"])


class TestScopesAndWho:
    def test_one_cow_or_one_group(self, client, farm):
        assert [a["name"] for a in _week(client, animal_id="p3-rosa")["animals"]] == ["Rosa"]
        assert sorted(a["name"] for a in _week(client, group_id="p3-herd")["animals"]) == ["Daisy", "Rosa"]

    def test_money_needs_reports_or_finance_and_stays_on_its_farm(self, client, farm):
        assert _report(client, email="worker@p3.farm").status_code == 403
        assert _report(client, animal_id="cow-744").status_code == 404, "the demo farm's Bella is not this farm's"
        demo = client.get(f"{API}/reports/profitability", headers=auth_headers(client), params={"animal_id": "p3-rosa"})
        assert demo.status_code == 404
