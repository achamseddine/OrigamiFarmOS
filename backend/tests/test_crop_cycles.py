"""A greenhouse crop cycle from planting to its margin (master prompt
Package 7; CROPS-SCHEMA §4–§8), through the API on the demo farm.

The acceptance scenario: create a greenhouse, plant tomatoes, record the
inputs (2 packets of seed at USD 5, 20 kg of fertiliser at USD 1.50) and
the labour (6 h for USD 30, 2 h for USD 10), irrigate (12 m³, USD 8 of
pumping), harvest 500 kg with 20 kg lost to split fruit — 480 kg into
stock — sell 400 kg at USD 1.20, and read the actual margin:

    revenue 480.00 − (inputs 40 + labour 40 + irrigation 8 = 88) = 392.00

Every input left stock by its own ledger movement; nothing is kept on the
side. Refusals, reversals, unknown costs, permissions, the farm boundary.
"""
from __future__ import annotations

import pytest
from sqlalchemy import select

from app.domain import crop_models as cm
from app.domain import models
from app.repositories.base import new_id
from tests.conftest import auth_headers

API = "/api/v1"
WORKER = "karim.worker@origami.farm"


def _h(client, email="rami@origami.farm", **extra):
    return {**auth_headers(client, email), **extra}


@pytest.fixture()
def greenhouse(client, db_session):
    session, _ = db_session
    r = client.post(f"{API}/fields", headers=_h(client), json={"name": "Greenhouse 3", "unit_type": "greenhouse", "area_value": 400, "area_unit": "m2"})
    assert r.status_code == 201, r.text
    field = r.json()
    crop = client.post(f"{API}/crops", headers=_h(client), json={"name": "Cherry tomato", "category": "vegetable", "default_cycle_days": 90}).json()
    r = client.post(f"{API}/crop-plantings", headers=_h(client), json={"field_id": field["id"], "crop_id": crop["id"], "variety": "Sakura",
                                                                       "planted_area": 380, "production_purpose": "sale"})
    assert r.status_code == 201, r.text
    cycle = r.json()
    seeds = models.InventoryItem(id=new_id(), farm_id="farm-origami", name="Tomato seed Sakura", category="seeds", unit="packet", current_qty=5, unit_cost=5.0)
    fert = models.InventoryItem(id=new_id(), farm_id="farm-origami", name="NPK 20-20-20", category="fertilizer", unit="kg", current_qty=50, unit_cost=1.5)
    session.add_all([seeds, fert])
    session.commit()
    return {"field": field, "crop": crop, "cycle": cycle, "seeds": seeds.id, "fert": fert.id}


def _work(client, cycle_id, op_type, inputs=(), hours=None, cost=None, email="rami@origami.farm"):
    return client.post(f"{API}/crop-plantings/{cycle_id}/operations", headers=_h(client, email), json={
        "operation_type": op_type, "labour_hours": hours, "labour_cost": cost,
        "inputs": [{"inventory_item_id": i, "quantity": q} for i, q in inputs]})


def _harvest(client, g, total=500, waste=20, reason="split fruit"):
    return client.post(f"{API}/harvest", headers=_h(client), json={
        "field_id": g["field"]["id"], "planting_id": g["cycle"]["id"], "total_quantity": total, "waste_quantity": waste, "loss_reason": reason,
        "unit": "kg", "confirm_duplicate": True})


def _margin(client, cycle_id):
    r = client.get(f"{API}/crop-plantings/{cycle_id}/margin", headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()


class TestTheAcceptanceScenario:
    def test_a_greenhouse_crop_from_planting_to_its_actual_margin(self, client, db_session, greenhouse):
        session, _ = db_session
        g = greenhouse
        cid = g["cycle"]["id"]
        assert g["field"]["unit_type"] == "greenhouse"
        assert g["cycle"]["cycle_code"].startswith("CHER-") and g["cycle"]["production_purpose"] == "sale"

        r = _work(client, cid, "plant", [(g["seeds"], 2)], hours=6, cost=30)
        assert r.status_code == 201, r.text
        assert r.json()["inputs"][0]["cost"] == 10.0
        assert _work(client, cid, "fertilize", [(g["fert"], 20)], hours=2, cost=10).status_code == 201
        r = client.post(f"{API}/crop-plantings/{cid}/irrigation", headers=_h(client), json={
            "started_at": "2026-11-20T05:00:00Z", "ended_at": "2026-11-20T06:30:00Z", "water_quantity": 12, "unit": "m3", "source_code": "well",
            "energy_cost": 8})
        assert r.status_code == 201, r.text

        # The inputs left stock by their own movements.
        session.expire_all()
        assert session.get(models.InventoryItem, g["fert"]).current_qty == 30
        assert session.get(models.InventoryItem, g["seeds"]).current_qty == 3
        outs = session.scalars(select(models.InventoryTransaction).where(models.InventoryTransaction.reason == "crop_input")).all()
        assert sorted(t.quantity for t in outs) == [2, 20] and all(t.linked_entity_type == "field_operation" for t in outs)

        r = _harvest(client, g)
        assert r.status_code == 201, r.text
        produce = session.scalar(select(models.InventoryItem).where(models.InventoryItem.name == "Cherry tomato", models.InventoryItem.category == "produce"))
        assert produce is not None and produce.current_qty == 480

        r = client.post(f"{API}/crop-plantings/{cid}/sales", headers=_h(client), json={"quantity": 400, "unit_price": 1.2, "buyer_name": "Zahle market"})
        assert r.status_code == 201, r.text
        assert r.json()["amount"] == 480.0
        session.expire_all()
        assert session.get(models.InventoryItem, produce.id).current_qty == 80

        m = _margin(client, cid)
        assert m["harvest"] == {"harvested": 500, "lost": 20, "sellable": 480, "sold": 400, "unit": "kg", "harvests": 1, "loss_reasons": ["split fruit"]}
        assert m["revenue"] == 480.0
        assert m["costs"] == {"inputs": 40.0, "labour": 40.0, "irrigation_energy": 8.0, "other_expenses": 0.0, "total_known": 88.0}
        assert (m["margin"], m["cost_per_unit_harvested"], m["labour_hours"], m["water_m3"]) == (392.0, 0.176, 8.0, 12.0)
        assert m["unknown"] == []
        # The sale is the farm's: in Sales & Finance, crops.
        sales = client.get(f"{API}/finance/sales", headers=_h(client), params={"days": 30}).json()
        assert any(s["id"] == r.json()["sale_id"] and s["activity"] == "crops" for s in sales)

    def test_closing_the_cycle_keeps_it_and_takes_no_more_work(self, client, greenhouse):
        g = greenhouse
        cid = g["cycle"]["id"]
        _harvest(client, g, total=100, waste=0, reason=None)
        r = client.post(f"{API}/crop-plantings/{cid}/close", headers=_h(client), json={"notes": "Last pick"})
        assert r.status_code == 200 and r.json()["status"] == "closed" and r.json()["closed_at"]
        assert _work(client, cid, "spray").status_code == 409
        assert _harvest(client, g, total=10, waste=0).status_code == 409
        assert client.post(f"{API}/crop-plantings/{cid}/close", headers=_h(client)).status_code == 409


class TestRefusalsAndCorrections:
    def test_more_than_in_stock_is_refused_and_nothing_moves(self, client, db_session, greenhouse):
        session, _ = db_session
        g = greenhouse
        r = _work(client, g["cycle"]["id"], "fertilize", [(g["fert"], 60)])
        assert r.status_code == 422 and "Not enough NPK 20-20-20" in r.json()["detail"], r.text
        session.expire_all()
        assert session.get(models.InventoryItem, g["fert"]).current_qty == 50
        assert session.scalar(select(cm.FieldOperation.id).where(cm.FieldOperation.crop_planting_id == g["cycle"]["id"])) is None
        r = client.post(f"{API}/crop-plantings/{g['cycle']['id']}/sales", headers=_h(client), json={"quantity": 10, "unit_price": 1})
        assert r.status_code == 422 and "Record the harvest first" in r.json()["detail"]

    def test_feed_medicine_or_produce_are_not_crop_inputs(self, client, db_session, greenhouse):
        session, _ = db_session
        for category in ("feed", "medicine", "produce"):
            item = models.InventoryItem(id=new_id(), farm_id="farm-origami", name=f"Some {category}", category=category, unit="kg", current_qty=10, unit_cost=1)
            session.add(item)
            session.commit()
            r = _work(client, greenhouse["cycle"]["id"], "fertilize", [(item.id, 1)])
            assert r.status_code == 422 and "a crop uses seeds" in r.json()["detail"], category

    def test_the_inputs_offered_are_the_crop_s_not_feed_or_medicine(self, client, db_session, greenhouse):
        names = {i["name"] for i in client.get(f"{API}/crop-inputs", headers=_h(client)).json()}
        assert {"Tomato seed Sakura", "NPK 20-20-20"} <= names
        session, _ = db_session
        from app.domain import feed_models as fm

        barley_item = session.get(fm.FeedProduct, "fp-barley").inventory_item_id
        barley = session.get(models.InventoryItem, barley_item)
        assert barley.name not in names, "a feed product is the feed ledger's, not a crop input"
        r = _work(client, greenhouse["cycle"]["id"], "fertilize", [(barley_item, 1)])
        assert r.status_code == 422

    def test_work_recorded_by_mistake_is_reversed_and_its_inputs_return(self, client, db_session, greenhouse):
        session, _ = db_session
        g = greenhouse
        op = _work(client, g["cycle"]["id"], "fertilize", [(g["fert"], 20)], hours=1, cost=5).json()
        r = client.post(f"{API}/crop-plantings/{g['cycle']['id']}/operations/{op['id']}/reverse", headers=_h(client), json={"reason": "wrong greenhouse"})
        assert r.status_code == 200 and r.json()["status"] == "reversed", r.text
        session.expire_all()
        assert session.get(models.InventoryItem, g["fert"]).current_qty == 50
        assert _margin(client, g["cycle"]["id"])["costs"]["total_known"] == 0
        again = client.post(f"{API}/crop-plantings/{g['cycle']['id']}/operations/{op['id']}/reverse", headers=_h(client), json={"reason": "twice"})
        assert again.status_code == 409

    def test_unknown_costs_are_named_not_counted_as_free(self, client, db_session, greenhouse):
        session, _ = db_session
        g = greenhouse
        bare = models.InventoryItem(id=new_id(), farm_id="farm-origami", name="Copper spray", category="other", unit="L", current_qty=10, unit_cost=None)
        session.add(bare)
        session.commit()
        _work(client, g["cycle"]["id"], "spray", [(bare.id, 2)], hours=3, cost=None)
        client.post(f"{API}/crop-plantings/{g['cycle']['id']}/irrigation", headers=_h(client), json={"started_at": "2026-11-21T05:00:00Z", "water_quantity": 5000, "unit": "L"})
        m = _margin(client, g["cycle"]["id"])
        assert set(m["unknown"]) == {"inputs_without_cost", "labour_not_priced", "irrigation_energy_not_known"}
        assert m["unpriced_inputs"] == ["Copper spray"] and m["water_m3"] == 5.0


    def test_work_queued_on_a_tablet_keeps_its_own_date(self, client, greenhouse):
        """A tablet records work and water offline and replays them later: they
        keep the time they were done, a clock a few minutes ahead of the
        server's is accepted, and a date in the future is refused."""
        from datetime import datetime, timedelta, timezone

        cid = greenhouse["cycle"]["id"]
        done = (datetime.now(timezone.utc) - timedelta(days=2)).replace(microsecond=0)
        r = client.post(f"{API}/crop-plantings/{cid}/operations", headers=_h(client), json={"operation_type": "weed", "completed_at": done.isoformat()})
        assert r.status_code == 201, r.text
        assert datetime.fromisoformat(r.json()["completed_at"]) == done
        ahead = (datetime.now(timezone.utc) + timedelta(minutes=2)).isoformat()
        assert client.post(f"{API}/crop-plantings/{cid}/operations", headers=_h(client), json={"operation_type": "weed", "completed_at": ahead}).status_code == 201
        assert client.post(f"{API}/crop-plantings/{cid}/irrigation", headers=_h(client), json={"started_at": ahead, "water_quantity": 3}).status_code == 201
        later = (datetime.now(timezone.utc) + timedelta(hours=3)).isoformat()
        assert client.post(f"{API}/crop-plantings/{cid}/operations", headers=_h(client), json={"operation_type": "weed", "completed_at": later}).status_code == 422
        assert client.post(f"{API}/crop-plantings/{cid}/irrigation", headers=_h(client), json={"started_at": later}).status_code == 422


class TestWhoAndWhichFarm:
    def test_the_margin_is_money_and_another_farm_sees_nothing(self, client, db_session, greenhouse):
        session, _ = db_session
        from app.core.security import hash_password

        session.add(models.Farm(id="farm-other", name="Other", country="Lebanon", region="North", timezone="Asia/Beirut", default_currency="USD"))
        session.add(models.User(id="user-other", farm_id="farm-other", name="Other Manager", email="m@other.farm", password_hash=hash_password("farmos123"),
                                role="manager", language="en"))
        session.commit()
        cid = greenhouse["cycle"]["id"]
        other = _h(client, "m@other.farm")
        assert client.get(f"{API}/crop-plantings/{cid}/margin", headers=other).status_code == 404
        assert _work(client, cid, "weed", email="m@other.farm").status_code == 404
        # Karim (animals) neither works the greenhouse nor reads its money.
        assert _work(client, cid, "weed", email=WORKER).status_code == 403
        assert client.get(f"{API}/crop-plantings/{cid}/margin", headers=_h(client, WORKER)).status_code == 403

    def test_a_bad_growing_unit_or_purpose_is_refused(self, client):
        assert client.post(f"{API}/fields", headers=_h(client), json={"name": "Roof", "unit_type": "rooftop"}).status_code == 422
