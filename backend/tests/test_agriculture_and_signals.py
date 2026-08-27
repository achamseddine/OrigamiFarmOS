"""Fields, crops, plantings, daily harvest, notifications and priorities
(tech spec §3/§5/§14–§17).
"""
from __future__ import annotations

from fastapi.testclient import TestClient

from app.core import permissions as perms
from tests.conftest import auth_headers

MANAGER = ("rami@origami.farm", "farmos123")
WORKER = ("karim.worker@origami.farm", "farmos123")


def _headers(client: TestClient, who=MANAGER) -> dict:
    return auth_headers(client, who[0], who[1])


def _make_field(client: TestClient, name: str = "Field 9", **extra) -> dict:
    r = client.post(
        "/api/v1/fields",
        json={"name": name, "area_value": 4200, "area_unit": "m2", **extra},
        headers=_headers(client),
    )
    assert r.status_code == 201, r.text
    return r.json()


def _make_crop(client: TestClient, name: str = "Tomato", **extra) -> dict:
    r = client.post("/api/v1/crops", json={"name": name, **extra}, headers=_headers(client))
    assert r.status_code == 201, r.text
    return r.json()


class TestFields:
    def test_manager_can_create_a_field(self, client: TestClient):
        field = _make_field(client, "Field 3", soil_type="clay loam", irrigation_method="drip")
        assert field["name"] == "Field 3"
        assert field["area_value"] == 4200
        assert field["soil_type"] == "clay loam"

    def test_new_field_appears_in_the_list(self, client: TestClient):
        _make_field(client, "Field 12")
        listed = client.get(
            "/api/v1/production/fields", params={"farm_id": "farm-origami"}, headers=_headers(client)
        ).json()
        assert "Field 12" in {f["name"] for f in listed}

    def test_field_can_be_edited(self, client: TestClient):
        field = _make_field(client, "Field 4")
        r = client.patch(
            f"/api/v1/fields/{field['id']}", json={"irrigation_method": "sprinkler"}, headers=_headers(client)
        )
        assert r.status_code == 200
        assert r.json()["irrigation_method"] == "sprinkler"

    def test_animal_worker_cannot_create_a_field(self, client: TestClient):
        r = client.post("/api/v1/fields", json={"name": "Sneaky"}, headers=_headers(client, WORKER))
        assert r.status_code == 403

    def test_zero_area_is_rejected(self, client: TestClient):
        r = client.post("/api/v1/fields", json={"name": "Bad", "area_value": 0}, headers=_headers(client))
        assert r.status_code == 422


class TestCropTypes:
    def test_crop_types_are_farm_data_not_a_fixed_list(self, client: TestClient):
        """Tech spec §16 — a farm can add whatever it actually grows."""
        created = _make_crop(client, "Freekeh Wheat", category="grain", default_cycle_days=210)
        listed = client.get("/api/v1/crops", headers=_headers(client)).json()
        assert created["id"] in {c["id"] for c in listed}

    def test_duplicate_crop_name_is_rejected(self, client: TestClient):
        _make_crop(client, "Test Squash")
        r = client.post("/api/v1/crops", json={"name": "Test Squash"}, headers=_headers(client))
        assert r.status_code == 409

    def test_archiving_a_crop_hides_it_without_deleting_it(self, client: TestClient):
        crop = _make_crop(client, "Okra")
        assert client.delete(f"/api/v1/crops/{crop['id']}", headers=_headers(client)).status_code == 204
        assert crop["id"] not in {c["id"] for c in client.get("/api/v1/crops", headers=_headers(client)).json()}
        with_inactive = client.get(
            "/api/v1/crops", params={"include_inactive": True}, headers=_headers(client)
        ).json()
        assert crop["id"] in {c["id"] for c in with_inactive}

    def test_readding_an_archived_crop_reactivates_it(self, client: TestClient):
        crop = _make_crop(client, "Test Thyme")
        client.delete(f"/api/v1/crops/{crop['id']}", headers=_headers(client))
        r = client.post("/api/v1/crops", json={"name": "Test Thyme"}, headers=_headers(client))
        assert r.status_code == 201
        assert r.json()["id"] == crop["id"]


class TestPlantings:
    def test_planting_updates_the_field_summary(self, client: TestClient):
        field = _make_field(client, "Field 7")
        crop = _make_crop(client, "Cucumber")
        r = client.post(
            "/api/v1/crop-plantings",
            json={
                "field_id": field["id"],
                "crop_id": crop["id"],
                "variety": "Beit Alpha",
                "planted_date": "2026-08-01T06:00:00Z",
                "expected_yield_kg": 280,
            },
            headers=_headers(client),
        )
        assert r.status_code == 201, r.text
        fields = client.get(
            "/api/v1/production/fields", params={"farm_id": "farm-origami"}, headers=_headers(client)
        ).json()
        updated = next(f for f in fields if f["id"] == field["id"])
        assert updated["crop_type"] == "Cucumber"
        assert updated["est_yield_kg"] == 280

    def test_expected_harvest_is_derived_from_the_crop_cycle(self, client: TestClient):
        field = _make_field(client, "Field 8")
        crop = _make_crop(client, "Radish", default_cycle_days=30)
        r = client.post(
            "/api/v1/crop-plantings",
            json={"field_id": field["id"], "crop_id": crop["id"], "planted_date": "2026-08-01T00:00:00Z"},
            headers=_headers(client),
        )
        assert r.status_code == 201
        assert r.json()["expected_harvest_date"].startswith("2026-08-31")


class TestDailyHarvest:
    def test_harvest_moves_sellable_produce_into_real_stock(self, client: TestClient):
        """Tech spec §17 — the numbers on the Produce screen must be stock
        that exists, not an estimate someone typed."""
        field = _make_field(client, "Field 2")
        crop = _make_crop(client, "Test Peppers")
        r = client.post(
            "/api/v1/harvest",
            json={
                "field_id": field["id"],
                "crop_id": crop["id"],
                "total_quantity": 185,
                "sellable_quantity": 168,
                "waste_quantity": 17,
            },
            headers=_headers(client),
        )
        assert r.status_code == 201, r.text
        body = r.json()
        assert body["sellable_quantity"] == 168
        assert body["inventory_qty_after"] == 168

        items = client.get(
            "/api/v1/feed/items", params={"farm_id": "farm-origami"}, headers=_headers(client)
        ).json()
        tomato = next(i for i in items if i["name"] == "Test Peppers")
        assert tomato["current_qty"] == 168

    def test_sellable_defaults_to_total_minus_waste(self, client: TestClient):
        field = _make_field(client, "Field 5")
        r = client.post(
            "/api/v1/harvest",
            json={"field_id": field["id"], "product_name": "Eggplant", "total_quantity": 100, "waste_quantity": 12},
            headers=_headers(client),
        )
        assert r.status_code == 201
        assert r.json()["sellable_quantity"] == 88

    def test_two_harvests_of_the_same_crop_accumulate(self, client: TestClient):
        field = _make_field(client, "Field 6")
        for qty in (40, 60):
            client.post(
                "/api/v1/harvest",
                json={"field_id": field["id"], "product_name": "Peppers", "total_quantity": qty},
                headers=_headers(client),
            )
        items = client.get(
            "/api/v1/feed/items", params={"farm_id": "farm-origami"}, headers=_headers(client)
        ).json()
        assert next(i for i in items if i["name"] == "Peppers")["current_qty"] == 100

    def test_waste_over_total_is_rejected(self, client: TestClient):
        field = _make_field(client, "Field 10")
        r = client.post(
            "/api/v1/harvest",
            json={"field_id": field["id"], "product_name": "Beans", "total_quantity": 10, "waste_quantity": 25},
            headers=_headers(client),
        )
        assert r.status_code == 422

    def test_harvest_needs_to_know_what_was_picked(self, client: TestClient):
        field = _make_field(client, "Field 11")
        r = client.post(
            "/api/v1/harvest", json={"field_id": field["id"], "total_quantity": 10}, headers=_headers(client)
        )
        assert r.status_code == 422

    def test_harvest_is_audited_with_the_split(self, client: TestClient):
        field = _make_field(client, "Field 13")
        created = client.post(
            "/api/v1/harvest",
            json={"field_id": field["id"], "product_name": "Melon", "total_quantity": 50, "waste_quantity": 5},
            headers=_headers(client),
        ).json()
        audit = client.get(
            "/api/v1/audit",
            params={"entity_type": "harvest_record", "entity_id": created["id"]},
            headers=_headers(client),
        ).json()
        assert audit[0]["metadata_json"]["sellable"] == 45
        assert "Melon" in audit[0]["summary"]


class TestNotifications:
    def test_bell_reports_unread_alerts_derived_from_farm_state(self, client: TestClient):
        r = client.get("/api/v1/notifications", headers=_headers(client))
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["unread_count"] == body["total"]
        assert body["total"] > 0, "the seeded farm has open recommendations and low stock"

    def test_every_notification_points_at_a_record_to_open(self, client: TestClient):
        body = client.get("/api/v1/notifications", headers=_headers(client)).json()
        for item in body["notifications"]:
            assert item["entity_type"], item
            assert item["entity_id"], item

    def test_marking_one_read_lowers_the_unread_count(self, client: TestClient):
        body = client.get("/api/v1/notifications", headers=_headers(client)).json()
        first = body["notifications"][0]
        assert client.post(f"/api/v1/notifications/{first['id']}/read", headers=_headers(client)).status_code == 200
        after = client.get("/api/v1/notifications", headers=_headers(client)).json()
        assert after["unread_count"] == body["unread_count"] - 1

    def test_read_state_survives_the_next_refresh(self, client: TestClient):
        body = client.get("/api/v1/notifications", headers=_headers(client)).json()
        first = body["notifications"][0]
        client.post(f"/api/v1/notifications/{first['id']}/read", headers=_headers(client))
        refreshed = client.get("/api/v1/notifications", headers=_headers(client)).json()
        same = next(n for n in refreshed["notifications"] if n["id"] == first["id"])
        assert same["read_at"] is not None

    def test_mark_all_read_clears_the_badge(self, client: TestClient):
        client.post("/api/v1/notifications/read-all", headers=_headers(client))
        assert client.get("/api/v1/notifications", headers=_headers(client)).json()["unread_count"] == 0

    def test_unread_filter_returns_only_unread(self, client: TestClient):
        client.post("/api/v1/notifications/read-all", headers=_headers(client))
        body = client.get(
            "/api/v1/notifications", params={"unread_only": True}, headers=_headers(client)
        ).json()
        assert body["notifications"] == []

    def test_an_employee_only_sees_their_own_modules(self, client: TestClient):
        """An Animals-only worker must not be shown the farm's finance alerts."""
        worker = client.get("/api/v1/notifications", headers=_headers(client, WORKER)).json()
        modules = {n["module_code"] for n in worker["notifications"]}
        assert perms.FINANCE not in modules
        manager = client.get("/api/v1/notifications", headers=_headers(client)).json()
        assert manager["total"] >= worker["total"]


class TestPriorities:
    def test_priorities_include_both_alerts_and_tasks(self, client: TestClient):
        body = client.get("/api/v1/priorities", headers=_headers(client)).json()
        kinds = {p["kind"] for p in body["priorities"]}
        assert "alert" in kinds
        assert "task" in kinds

    def test_every_priority_card_can_navigate_somewhere(self, client: TestClient):
        body = client.get("/api/v1/priorities", headers=_headers(client)).json()
        assert body["total"] > 0
        for item in body["priorities"]:
            assert item["entity_type"] and item["entity_id"]

    def test_counts_describe_everything_visible_not_the_filtered_page(self, client: TestClient):
        unfiltered = client.get("/api/v1/priorities", headers=_headers(client)).json()
        filtered = client.get(
            "/api/v1/priorities", params={"kind": "task"}, headers=_headers(client)
        ).json()
        assert filtered["total"] < unfiltered["total"]
        assert filtered["counts_by_priority"] == unfiltered["counts_by_priority"]

    def test_filtering_by_module_and_priority(self, client: TestClient):
        body = client.get(
            "/api/v1/priorities", params={"module": perms.ANIMAL_HEALTH}, headers=_headers(client)
        ).json()
        assert all(p["module_code"] == perms.ANIMAL_HEALTH for p in body["priorities"])

        high = client.get("/api/v1/priorities", params={"priority": "high"}, headers=_headers(client)).json()
        assert all(p["priority"] == "high" for p in high["priorities"])

    def test_assignment_filter_separates_mine_from_the_team(self, client: TestClient):
        mine = client.get(
            "/api/v1/priorities", params={"assignment": "unassigned"}, headers=_headers(client)
        ).json()
        assert all(p["assigned_to"] is None for p in mine["priorities"])

    def test_an_employee_sees_a_narrower_feed_than_the_manager(self, client: TestClient):
        manager = client.get("/api/v1/priorities", headers=_headers(client)).json()
        worker = client.get("/api/v1/priorities", headers=_headers(client, WORKER)).json()
        assert worker["total"] < manager["total"]
        assert perms.FINANCE not in {p["module_code"] for p in worker["priorities"]}
