"""What the animals are fed, the stock as counted, and what feeding costs (v0.8.3).

* The animals are fed three things — concentrate, corn silage, hay & straw.
  Grain, meals, minerals and premix are raw materials: they reach the
  animals only through a mix, and the server refuses them on a feeding.
* A feed made on an older form that only says "feedable" is typed from its
  name and category; a grain stays a raw material however it was marked.
* The manager counts the stock on inspection: the count becomes the stock;
  the difference is posted as count corrections, never typed over the
  records; the same count sent again changes nothing.
* A feed's price per kg is used wherever a lot has no cost of its own, so
  every feeding has a cost: what was given times what it cost.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.domain import models
from tests.conftest import auth_headers

API = "/api/v1"
BELLA = "cow-744"
BARLEY, STRAW, SILAGE, MIX = "fp-barley", "fp-wheat-straw", "fp-corn-silage", "fp-dairy-mix"
WORKER = "karim.worker@origami.farm"


def _h(client, email="rami@origami.farm"):
    return auth_headers(client, email)


def _product(client, pid):
    return client.get(f"{API}/feed-products/{pid}", headers=_h(client)).json()


def _feed(client, product_id, qty, animal=BELLA):
    return client.post(f"{API}/feeding-events", headers=_h(client), json={
        "subject_type": "animal", "subject_id": animal, "event_type": "offered", "allow_negative": True,
        "components": [{"feed_product_id": product_id, "quantity_offered": qty}]})


def test_only_concentrate_silage_and_hay_straw_are_fed(client):
    types = {p["id"]: (p["ration_type"], p["is_feedable"]) for p in client.get(f"{API}/feed-products", headers=_h(client)).json()}
    assert types[MIX] == ("concentrate", True)
    assert types[SILAGE] == ("silage", True)
    assert types[STRAW] == ("hay_straw", True)
    assert types[BARLEY] == (None, False), "barley is a raw material"
    assert types["fp-minerals"] == (None, False)
    r = _feed(client, BARLEY, 2)
    assert r.status_code == 422
    assert "Record the mix it goes into" in r.json()["detail"]


def test_an_older_form_that_says_feedable_does_not_make_grain_a_feed(client):
    h = _h(client)
    # What the purchase form sent before v0.8.3 for "grain".
    grain = client.post(f"{API}/feed-products", json={"name": "Corn grain", "category": "concentrate", "is_ingredient": True,
                                                      "is_feedable": True}, headers=h)
    assert grain.status_code == 201, grain.text
    assert (grain.json()["ration_type"], grain.json()["is_feedable"]) == (None, False)
    hay = client.post(f"{API}/feed-products", json={"name": "Vetch hay", "category": "forage", "is_feedable": True}, headers=h).json()
    assert (hay["ration_type"], hay["is_feedable"]) == ("hay_straw", True)
    bought = client.post(f"{API}/feed-products", json={"name": "Fattening pellets", "category": "complete_feed", "is_ingredient": False,
                                                       "is_feedable": True}, headers=h).json()
    assert bought["ration_type"] == "concentrate"
    # Named outright.
    typed = client.post(f"{API}/feed-products", json={"name": "Sorghum silage", "ration_type": "silage"}, headers=h).json()
    assert (typed["ration_type"], typed["is_feedable"]) == ("silage", True)
    raw = client.post(f"{API}/feed-products", json={"name": "Soybean meal", "ration_type": "raw_material"}, headers=h).json()
    assert (raw["ration_type"], raw["is_feedable"], raw["is_ingredient"]) == (None, False, True)
    assert client.post(f"{API}/feed-products", json={"name": "X", "ration_type": "pasture"}, headers=h).status_code == 422


def test_the_manager_changes_what_a_feed_is(client):
    h = _h(client)
    grain = client.post(f"{API}/feed-products", json={"name": "Corn grain", "ration_type": "raw_material"}, headers=h).json()
    r = client.patch(f"{API}/feed-products/{grain['id']}", json={"is_feedable": True}, headers=h)
    assert r.status_code == 422 and "raw material" in r.json()["detail"]
    r = client.patch(f"{API}/feed-products/{grain['id']}", json={"ration_type": "concentrate"}, headers=h)
    assert (r.json()["ration_type"], r.json()["is_feedable"]) == ("concentrate", True)
    r = client.patch(f"{API}/feed-products/{grain['id']}", json={"ration_type": "raw_material"}, headers=h)
    assert (r.json()["ration_type"], r.json()["is_feedable"]) == (None, False)
    # A feed in a ration in force stays a feed until the ration changes.
    r = client.patch(f"{API}/feed-products/fp-alfalfa", json={"ration_type": "raw_material"}, headers=h)
    assert r.status_code == 409 and "program" in r.json()["detail"]


def test_the_count_becomes_the_stock_and_the_records_keep_why(client, db_session):
    session, _ = db_session
    h = _h(client)
    before = _product(client, STRAW)["availability"]["on_hand"]
    r = client.post(f"{API}/feed-inventory/counts", json={"feed_product_id": STRAW, "counted_quantity": before - 140,
                                                           "notes": "Two bales spoiled by rain"}, headers=h)
    assert r.status_code == 201, r.text
    out = r.json()
    assert (out["before"], out["counted"], out["delta"]) == (before, before - 140, -140)
    assert _product(client, STRAW)["availability"]["on_hand"] == before - 140
    item_id = _product(client, STRAW)["inventory_item_id"]
    corrections = session.scalars(select(models.InventoryTransaction).where(models.InventoryTransaction.item_id == item_id,
                                                                           models.InventoryTransaction.reason == "count_correction")).all()
    assert sum(t.quantity for t in corrections if t.direction == "out") == 140
    assert session.scalar(select(models.InventoryItem.current_qty).where(models.InventoryItem.id == item_id)) == before - 140
    audit = session.scalars(select(models.AuditLog).where(models.AuditLog.action == "feed_stock_counted")).all()
    assert len(audit) == 1 and "Two bales" not in audit[0].summary
    event = session.scalars(select(models.Event).where(models.Event.event_type == "feed_stock_counted")).one()
    assert event.payload_json["notes"] == "Two bales spoiled by rain"
    # The same count again: nothing to correct (a retry from the offline queue).
    again = client.post(f"{API}/feed-inventory/counts", json={"feed_product_id": STRAW, "counted_quantity": before - 140}, headers=h).json()
    assert again["delta"] == 0 and again["lots"] == []
    # More than the records say: it is added.
    more = client.post(f"{API}/feed-inventory/counts", json={"feed_product_id": STRAW, "counted_quantity": before + 60}, headers=h).json()
    assert more["delta"] == 200
    assert _product(client, STRAW)["availability"]["on_hand"] == before + 60


def test_a_count_in_tonnes_and_what_is_refused(client):
    h = _h(client)
    r = client.post(f"{API}/feed-inventory/counts", json={"feed_product_id": STRAW, "counted_quantity": 1.5, "unit": "t"}, headers=h)
    assert r.status_code == 201 and r.json()["counted"] == 1500
    assert client.post(f"{API}/feed-inventory/counts", json={"feed_product_id": STRAW, "counted_quantity": -1}, headers=h).status_code == 422
    future = (datetime.now(timezone.utc) + timedelta(days=2)).isoformat()
    assert client.post(f"{API}/feed-inventory/counts", json={"feed_product_id": STRAW, "counted_quantity": 10, "counted_at": future},
                       headers=h).status_code == 422
    assert client.post(f"{API}/feed-inventory/counts", json={"feed_product_id": "nope", "counted_quantity": 10}, headers=h).status_code == 404


def test_the_count_is_the_managers(client, db_session):
    session, _ = db_session
    for row in session.scalars(select(models.UserModulePermission).where(models.UserModulePermission.user_id == "user-worker-1")):
        if row.module_code in ("feed_nutrition", "inventory"):
            row.can_approve = False
    session.commit()
    r = client.post(f"{API}/feed-inventory/counts", json={"feed_product_id": STRAW, "counted_quantity": 10}, headers=_h(client, WORKER))
    assert r.status_code == 403


def test_a_price_per_kg_gives_every_feeding_its_cost(client):
    h = _h(client)
    hay = client.post(f"{API}/feed-products", json={"name": "Hay bales", "ration_type": "hay_straw"}, headers=h).json()
    assert hay["current_unit_cost"] is None
    # Found at the inspection, never bought here: no cost of its own.
    client.post(f"{API}/feed-inventory/counts", json={"feed_product_id": hay["id"], "counted_quantity": 500}, headers=h)
    r = client.patch(f"{API}/feed-products/{hay['id']}", json={"default_unit_cost": 0.2}, headers=h)
    assert r.status_code == 200 and r.json()["current_unit_cost"] == 0.2
    assert client.patch(f"{API}/feed-products/{hay['id']}", json={"default_unit_cost": -1}, headers=h).status_code == 422
    fed = _feed(client, hay["id"], 10)
    assert fed.status_code == 201, fed.text
    assert fed.json()["total_cost"] == 2.0, "10 kg at $0.20"
    costs = client.get(f"{API}/feed-costs", params={"days": 30}, headers=h).json()
    bella = next(s for s in costs["by_subject"] if s["subject_id"] == BELLA)
    assert bella["cost"] >= 2.0
    assert any(p["feed_product_id"] == hay["id"] and p["cost"] == 2.0 for p in costs["by_product"])


def test_a_bought_lot_keeps_its_own_cost(client):
    h = _h(client)
    straw = _product(client, STRAW)
    assert straw["current_unit_cost"] == 0.12, "the first lot's cost"
    client.patch(f"{API}/feed-products/{STRAW}", json={"default_unit_cost": 0.5}, headers=h)
    assert _product(client, STRAW)["current_unit_cost"] == 0.12, "the price is only for feed without a cost of its own"


def test_the_feed_report_says_what_each_animal_cost_and_what_had_no_price(client):
    h = _h(client)
    hay = client.post(f"{API}/feed-products", json={"name": "Hay bales", "ration_type": "hay_straw"}, headers=h).json()
    client.post(f"{API}/feed-inventory/counts", json={"feed_product_id": hay["id"], "counted_quantity": 100}, headers=h)
    before = client.get(f"{API}/reports/feed", headers=h).json()
    _feed(client, hay["id"], 5)  # no price yet
    after = client.get(f"{API}/reports/feed", headers=h).json()
    assert after["kpis"]["unpriced_kg"] == before["kpis"]["unpriced_kg"] + 5
    client.patch(f"{API}/feed-products/{hay['id']}", json={"default_unit_cost": 0.3}, headers=h)
    _feed(client, hay["id"], 10)
    report = client.get(f"{API}/reports/feed", headers=h).json()
    bella = next(r for r in report["by_subject"] if r["subject_id"] == BELLA)
    was = next((r for r in before["by_subject"] if r["subject_id"] == BELLA), {"cost": 0, "feedings": 0})
    assert round(bella["cost"] - was["cost"], 2) == 3.0 and bella["feedings"] == was["feedings"] + 2
    assert bella["name"] == "Bella" and bella["cost_per_day"] == round(bella["cost"] / report["days"], 2)
    assert report["kpis"]["feed_cost_per_day"] == round(report["kpis"]["feed_cost"] / report["days"], 2)
    assert report["cost_by_day"][-1]["cost"] >= 3.0
