"""Platform masters and the scheduler: units of measure as references,
farm assets, notification routes, and the scheduled cycles with their
run log (FOUNDATION uom, ASSET-MAINTENANCE §2, MEDICINE-NOTIFICATION-RULES
§Notification behavior, FEED-PERFORMANCE-INTELLIGENCE §12).
"""
from __future__ import annotations

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.core import scheduler
from app.domain import models
from app.domain import platform_models as plm
from tests.conftest import auth_headers

API = "/api/v1"


def _h(client: TestClient) -> dict:
    return auth_headers(client)


def _vet(client: TestClient) -> dict:
    return auth_headers(client, "layla.vet@origami.farm", "farmos123")


def _worker(client: TestClient) -> dict:
    return auth_headers(client, "karim.worker@origami.farm", "farmos123")


class TestUnits:
    def test_units_are_a_table_the_pharmacy_references(self, client: TestClient):
        r = client.get(f"{API}/units-of-measure", headers=_h(client))
        assert r.status_code == 200, r.text
        units = {u["code"]: u for u in r.json()}
        assert {"kg", "g", "ml", "l", "dose", "sachet", "mg/ml", "%", "head"} <= set(units)
        assert units["g"]["base_unit_code"] == "kg" and units["g"]["factor_to_base"] == 0.001 and units["dose"]["base_unit_code"] is None
        # A medicine in an unknown unit is refused until the unit exists.
        body = {"name": "Vitamin B complex", "unit": "flask", "dosage_form": "injectable", "administration_routes": ["IM"]}
        r = client.post(f"{API}/pharmacy/medicines", json=body, headers=_h(client))
        assert r.status_code == 422 and "Unknown stock unit 'flask'" in r.json()["detail"]
        r = client.post(f"{API}/units-of-measure", json={"code": "flask", "name_en": "Flask", "dimension": "count"}, headers=_worker(client))
        assert r.status_code == 403, "units are configuration"
        r = client.post(f"{API}/units-of-measure", json={"code": "Flask", "name_en": "Flask", "dimension": "count"}, headers=_h(client))
        assert r.status_code == 201 and r.json()["code"] == "flask", r.text
        r = client.post(f"{API}/pharmacy/medicines", json=body, headers=_h(client))
        assert r.status_code == 201 and r.json()["unit"] == "flask", r.text
        # Conversions follow the dimension: a derived unit converts, a count unit never silently becomes another.
        r = client.post(f"{API}/units-of-measure", json={"code": "quintal", "name_en": "Quintal", "dimension": "mass", "base_unit_code": "kg", "factor_to_base": 100}, headers=_h(client))
        assert r.status_code == 201
        r = client.post(f"{API}/units-of-measure", json={"code": "carton", "name_en": "Carton", "dimension": "count", "base_unit_code": "dose", "factor_to_base": 12}, headers=_h(client))
        assert r.status_code == 201
        r = client.post(f"{API}/units-of-measure", json={"code": "weird", "name_en": "Weird", "dimension": "mass", "base_unit_code": "l", "factor_to_base": 1}, headers=_h(client))
        assert r.status_code == 422 and "same dimension" in r.json()["detail"]


class TestAssets:
    def test_assets_are_registered_and_named_by_mixes(self, client: TestClient):
        r = client.get(f"{API}/assets", headers=_h(client))
        assert r.status_code == 200, r.text
        mixer = next(a for a in r.json() if a["id"] == "asset-mixer-2")
        assert mixer["asset_type"] == "mixer" and mixer["code"] == "mixer-wagon-2" and mixer["status"] == "active"
        r = client.post(f"{API}/assets", json={"name": "Cooling tank 1", "asset_type": "cooling_tank", "manufacturer": "DeLaval"}, headers=_h(client))
        assert r.status_code == 201 and r.json()["code"] == "cooling-tank-1", r.text
        r = client.post(f"{API}/assets", json={"name": "Spaceship", "asset_type": "rocket"}, headers=_h(client))
        assert r.status_code == 422
        r = client.patch(f"{API}/assets/asset-mixer-2", json={"status": "out_of_service", "notes": "Gearbox"}, headers=_h(client))
        assert r.status_code == 200 and r.json()["status"] == "out_of_service"
        r = client.post(f"{API}/feed-batches", json={"formula_id": "formula-dairy-mix" if False else _dairy_formula(client), "target_quantity": 300, "mixer_asset_id": "asset-mixer-2"}, headers=_h(client))
        assert r.status_code == 422 and "out of service" in r.json()["detail"], "an asset out of service cannot be used for a mix"


def _dairy_formula(client: TestClient) -> str:
    return next(f for f in client.get(f"{API}/feed-formulas", headers=_h(client)).json() if f["code"] == "DAIRY-MIX-24L")["id"]


class TestNotificationRoutes:
    def test_routes_decide_recipients_and_default_to_managers(self, client: TestClient, db_session):
        db, _ = db_session
        r = client.get(f"{API}/notification-routes", headers=_h(client))
        assert r.status_code == 200, r.text
        routes = {x["route_code"]: x for x in r.json()}
        assert routes["pharmacy_stock"]["using_default"] and {u["role"] for u in routes["pharmacy_stock"]["effective_recipients"]} == {"manager", "owner"}
        assert {u["role"] for u in routes["emergency_veterinarian"]["effective_recipients"]} == {"veterinarian"}
        # The pharmacy bell is addressed per person: the owner sees their own copies.
        owner = auth_headers(client, "owner@origami.farm", "farmos123")
        bell = client.get(f"{API}/notifications", headers=owner).json()["notifications"]
        mine = [n for n in bell if n["source_type"] == "pharmacy_stock_alert"]
        assert mine and all(n["user_id"] == "user-owner" for n in mine)
        # Route the pharmacy to the worker only; the owner stops seeing stock alerts, the worker starts.
        r = client.put(f"{API}/notification-routes/pharmacy_stock", json={"entries": [{"user_id": "user-worker-1"}]}, headers=_h(client))
        assert r.status_code == 200 and not r.json()["using_default"] and [u["id"] for u in r.json()["effective_recipients"]] == ["user-worker-1"]
        bell = client.get(f"{API}/notifications", headers=owner).json()["notifications"]
        assert not [n for n in bell if n["source_type"] == "pharmacy_stock_alert" and n["notification_type"] == "pharmacy_below_minimum_stock"]
        bell = client.get(f"{API}/notifications", headers=_worker(client)).json()["notifications"]
        assert [n for n in bell if n["notification_type"] == "pharmacy_below_minimum_stock" and n["user_id"] == "user-worker-1"]
        assert client.put(f"{API}/notification-routes/pharmacy_stock", json={"entries": []}, headers=_worker(client)).status_code == 403
        assert client.put(f"{API}/notification-routes/nonsense", json={"entries": []}, headers=_h(client)).status_code == 422
        # Back to default.
        r = client.put(f"{API}/notification-routes/pharmacy_stock", json={"entries": []}, headers=_h(client))
        assert r.json()["using_default"]
        assert db.scalar(select(models.Event).where(models.Event.event_type == "notification_routes_changed")) is not None


class TestScheduler:
    def test_the_cycles_run_on_demand_and_are_logged(self, client: TestClient, db_session):
        db, _ = db_session
        r = client.get(f"{API}/scheduler/jobs", headers=_h(client))
        assert r.status_code == 200, r.text
        jobs = {j["job_code"]: j for j in r.json()}
        assert set(jobs) == {"feed_performance_cycle", "pharmacy_scan", "emergency_reassessment_check"}
        assert all(j["due"] and j["last_run_at"] is None for j in jobs.values()), "nothing has run yet on a fresh farm"
        assert jobs["feed_performance_cycle"]["cadence_minutes"] == 1440 and jobs["emergency_reassessment_check"]["cadence_minutes"] == 15
        assert client.post(f"{API}/scheduler/run", json={}, headers=_worker(client)).status_code == 403
        r = client.post(f"{API}/scheduler/run", json={"job_codes": ["nope"]}, headers=_h(client))
        assert r.status_code == 422
        r = client.post(f"{API}/scheduler/run", json={}, headers=_h(client))
        assert r.status_code == 200, r.text
        out = r.json()
        assert out["ran"] == 3 and all(x["status"] == "succeeded" for x in out["runs"]), out
        by_code = {x["job_code"]: x for x in out["runs"]}
        assert by_code["feed_performance_cycle"]["summary"]["monitors"] == 4 and by_code["pharmacy_scan"]["summary"]["medicines"] == 6
        assert by_code["emergency_reassessment_check"]["summary"]["awaiting_reassessment"] == 0
        jobs = {j["job_code"]: j for j in out["jobs"]}
        assert not jobs["pharmacy_scan"]["due"] and jobs["pharmacy_scan"]["last_status"] == "succeeded"
        # Not due → nothing runs unless forced; the log keeps every run.
        r = client.post(f"{API}/scheduler/run", json={"force": False}, headers=_h(client))
        assert r.json()["ran"] == 0
        r = client.get(f"{API}/scheduler/runs", headers=_h(client))
        assert len(r.json()) == 3 and all(x["finished_at"] for x in r.json())
        assert db.scalar(select(plm.ScheduledJobRun).where(plm.ScheduledJobRun.job_code == "pharmacy_scan")).trigger == "manual"

    def test_a_failing_job_is_logged_and_does_not_stop_the_others(self, db_session, monkeypatch):
        db, _ = db_session

        def boom(_db, _farm):
            raise RuntimeError("analytics exploded")

        monkeypatch.setitem(scheduler.JOBS, "pharmacy_scan", (scheduler.JOBS["pharmacy_scan"][0], boom))
        runs = scheduler.run_due(db, farm_id="farm-origami", force=True, trigger="scheduler")
        statuses = {r.job_code: r.status for r in runs}
        assert statuses == {"feed_performance_cycle": "succeeded", "pharmacy_scan": "failed", "emergency_reassessment_check": "succeeded"}
        failed = next(r for r in runs if r.job_code == "pharmacy_scan")
        assert "analytics exploded" in failed.error
        assert scheduler.is_due(db, "farm-origami", "pharmacy_scan"), "a failed run does not count as done"
        assert not scheduler.is_due(db, "farm-origami", "feed_performance_cycle")
