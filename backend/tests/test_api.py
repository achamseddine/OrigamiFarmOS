from __future__ import annotations

from tests.conftest import auth_headers


class TestAuth:
    def test_login_succeeds_with_seeded_demo_user(self, client):
        r = client.post("/api/v1/auth/login", json={"email": "rami@origami.farm", "password": "farmos123"})
        assert r.status_code == 200
        body = r.json()
        assert body["user"]["role"] == "manager"
        assert body["access_token"]

    def test_login_fails_with_wrong_password(self, client):
        r = client.post("/api/v1/auth/login", json={"email": "rami@origami.farm", "password": "wrong"})
        assert r.status_code == 401

    def test_protected_endpoint_requires_token(self, client):
        r = client.get("/api/v1/animals", params={"farm_id": "farm-origami"})
        assert r.status_code == 401


class TestBootstrapAndAnimals:
    def test_bootstrap_returns_full_local_cache_payload(self, client):
        headers = auth_headers(client)
        r = client.get("/api/v1/farms/farm-origami/bootstrap", headers=headers)
        assert r.status_code == 200
        body = r.json()
        assert body["farm"]["id"] == "farm-origami"
        assert len(body["animals"]) == 12
        assert len(body["inventory_items"]) == 7

    def test_list_animals_filters_by_species(self, client):
        headers = auth_headers(client)
        r = client.get("/api/v1/animals", params={"farm_id": "farm-origami", "species": "goat"}, headers=headers)
        assert r.status_code == 200
        animals = r.json()
        assert len(animals) == 4
        assert all(a["species"] == "goat" for a in animals)

    def test_get_animal_digital_twin_includes_history(self, client):
        headers = auth_headers(client)
        r = client.get("/api/v1/animals/cow-744", headers=headers)
        assert r.status_code == 200
        body = r.json()
        assert body["name"] == "Bella"
        assert len(body["recent_observations"]) >= 1
        assert len(body["recent_events"]) == 0  # observations/treatments in seed data don't write events directly

    def test_get_unknown_animal_returns_404(self, client):
        headers = auth_headers(client)
        r = client.get("/api/v1/animals/does-not-exist", headers=headers)
        assert r.status_code == 404


class TestObservations:
    def test_worker_can_record_an_observation(self, client):
        headers = auth_headers(client, "karim.worker@origami.farm")
        r = client.post(
            "/api/v1/observations",
            headers=headers,
            json={
                "farm_id": "farm-origami",
                "entity_type": "animal",
                "entity_id": "cow-214",
                "observation_type": "limping",
                "quality": "human_observed",
                "severity": "mild",
                "observer_id": "user-worker-1",
            },
        )
        assert r.status_code == 201
        assert r.json()["observation_type"] == "limping"

    def test_observation_schema_has_no_diagnosis_field(self, client):
        headers = auth_headers(client)
        r = client.post(
            "/api/v1/observations",
            headers=headers,
            json={
                "farm_id": "farm-origami",
                "entity_type": "animal",
                "entity_id": "cow-214",
                "observation_type": "limping",
                "diagnosis": "arthritis",  # not a real field — must be silently ignored, not stored
                "observer_id": "user-worker-1",
            },
        )
        assert r.status_code == 201
        assert "diagnosis" not in r.json()

    def test_unknown_entity_type_is_rejected(self, client):
        headers = auth_headers(client)
        r = client.post(
            "/api/v1/observations",
            headers=headers,
            json={
                "farm_id": "farm-origami",
                "entity_type": "spaceship",
                "entity_id": "cow-214",
                "observation_type": "limping",
                "observer_id": "user-worker-1",
            },
        )
        assert r.status_code == 422


class TestMilkValidation:
    def test_normal_milk_entry_succeeds(self, client):
        headers = auth_headers(client)
        r = client.post("/api/v1/production/milk", headers=headers, json={"animal_id": "cow-214", "session": "morning", "liters": 18.5, "destination": "stored"})
        assert r.status_code == 201
        assert r.json()["under_withdrawal_warning"] is False

    def test_negative_liters_rejected_by_schema(self, client):
        headers = auth_headers(client)
        r = client.post("/api/v1/production/milk", headers=headers, json={"animal_id": "cow-214", "session": "morning", "liters": -3, "destination": "stored"})
        assert r.status_code == 422

    def test_selling_milk_from_withdrawn_animal_is_blocked(self, client):
        headers = auth_headers(client)
        r = client.post("/api/v1/production/milk", headers=headers, json={"animal_id": "goat-willow", "session": "morning", "liters": 5, "destination": "sold"})
        assert r.status_code == 422
        assert "withdrawal" in r.json()["detail"].lower()

    def test_storing_milk_from_withdrawn_animal_is_allowed(self, client):
        headers = auth_headers(client)
        r = client.post("/api/v1/production/milk", headers=headers, json={"animal_id": "goat-willow", "session": "morning", "liters": 5, "destination": "stored"})
        assert r.status_code == 201
        assert r.json()["under_withdrawal_warning"] is True


class TestEggValidation:
    def test_valid_allocation_succeeds(self, client):
        headers = auth_headers(client)
        r = client.post(
            "/api/v1/production/eggs",
            headers=headers,
            json={"flock_id": "flock-layer", "total_eggs": 100, "sellable_eggs": 80, "broken_eggs": 10, "consumed": 5, "hatched": 3, "wasted": 2},
        )
        assert r.status_code == 201

    def test_allocation_exceeding_total_is_rejected(self, client):
        headers = auth_headers(client)
        r = client.post(
            "/api/v1/production/eggs",
            headers=headers,
            json={"flock_id": "flock-layer", "total_eggs": 100, "sellable_eggs": 90, "broken_eggs": 20, "consumed": 0, "hatched": 0, "wasted": 0},
        )
        assert r.status_code == 422


class TestFeedValidation:
    def test_normal_distribution_succeeds(self, client):
        headers = auth_headers(client)
        r = client.post("/api/v1/feed/transactions", headers=headers, json={"item_id": "feed-dairy-mix", "direction": "out", "quantity": 100, "reason": "daily_feeding"})
        assert r.status_code == 201
        assert r.json()["current_qty"] == 3150

    def test_negative_stock_without_override_is_rejected(self, client):
        headers = auth_headers(client)
        r = client.post("/api/v1/feed/transactions", headers=headers, json={"item_id": "feed-medicine", "direction": "out", "quantity": 999, "reason": "test"})
        assert r.status_code == 422

    def test_negative_stock_with_override_succeeds(self, client):
        headers = auth_headers(client)
        r = client.post(
            "/api/v1/feed/transactions",
            headers=headers,
            json={"item_id": "feed-medicine", "direction": "out", "quantity": 999, "reason": "test", "allow_negative": True},
        )
        assert r.status_code == 201


class TestTreatmentRbac:
    def test_manager_can_record_treatment(self, client):
        headers = auth_headers(client, "rami@origami.farm")
        r = client.post(
            "/api/v1/health/treatments",
            headers=headers,
            json={"entity_type": "animal", "entity_id": "cow-214", "medication": "Antibiotic", "dose": "10ml", "route": "IM", "responsible_user_id": "user-vet-1"},
        )
        assert r.status_code == 201

    def test_veterinarian_can_record_treatment(self, client):
        headers = auth_headers(client, "layla.vet@origami.farm")
        r = client.post(
            "/api/v1/health/treatments",
            headers=headers,
            json={"entity_type": "animal", "entity_id": "cow-214", "medication": "Antibiotic", "dose": "10ml", "route": "IM", "responsible_user_id": "user-vet-1"},
        )
        assert r.status_code == 201

    def test_worker_cannot_record_treatment(self, client):
        headers = auth_headers(client, "karim.worker@origami.farm")
        r = client.post(
            "/api/v1/health/treatments",
            headers=headers,
            json={"entity_type": "animal", "entity_id": "cow-214", "medication": "Antibiotic", "dose": "10ml", "route": "IM", "responsible_user_id": "user-vet-1"},
        )
        assert r.status_code == 403

    def test_accountant_cannot_record_treatment(self, client):
        headers = auth_headers(client, "nadine.acct@origami.farm")
        r = client.post(
            "/api/v1/health/treatments",
            headers=headers,
            json={"entity_type": "animal", "entity_id": "cow-214", "medication": "Antibiotic", "dose": "10ml", "route": "IM", "responsible_user_id": "user-vet-1"},
        )
        assert r.status_code == 403

    def test_treatment_with_withdrawal_updates_the_animal(self, client):
        headers = auth_headers(client, "layla.vet@origami.farm")
        r = client.post(
            "/api/v1/health/treatments",
            headers=headers,
            json={
                "entity_type": "animal",
                "entity_id": "cow-214",
                "medication": "Antibiotic",
                "dose": "10ml",
                "route": "IM",
                "responsible_user_id": "user-vet-1",
                "withdrawal_until": "2099-01-01T00:00:00Z",
            },
        )
        assert r.status_code == 201
        animal = client.get("/api/v1/animals", params={"farm_id": "farm-origami", "search": "214"}, headers=headers).json()[0]
        assert animal["withdrawal_reason"] == "Medication"


class TestTasks:
    def test_create_and_update_task(self, client):
        headers = auth_headers(client)
        r = client.post("/api/v1/tasks", headers=headers, json={"farm_id": "farm-origami", "title": "Check fence", "priority": "low"})
        assert r.status_code == 201
        task_id = r.json()["id"]

        r2 = client.patch(f"/api/v1/tasks/{task_id}", headers=headers, json={"status": "done"})
        assert r2.status_code == 200
        assert r2.json()["status"] == "done"

    def test_update_unknown_task_returns_404(self, client):
        headers = auth_headers(client)
        r = client.patch("/api/v1/tasks/does-not-exist", headers=headers, json={"status": "done"})
        assert r.status_code == 404


class TestRecommendations:
    def test_list_recommendations_refreshes_and_returns_evidence(self, client):
        headers = auth_headers(client)
        r = client.get("/api/v1/recommendations", params={"farm_id": "farm-origami"}, headers=headers)
        assert r.status_code == 200
        recs = r.json()
        assert len(recs) >= 6
        health_rec = next(r for r in recs if r["rule_id"] == "RULE-HEALTH-RISK")
        assert health_rec["priority"] == "high"
        assert len(health_rec["evidence"]) >= 3

    def test_decision_lifecycle_accept(self, client):
        headers = auth_headers(client)
        recs = client.get("/api/v1/recommendations", params={"farm_id": "farm-origami"}, headers=headers).json()
        rec_id = recs[0]["id"]
        r = client.patch(f"/api/v1/recommendations/{rec_id}/decision", headers=headers, json={"decision": "accepted", "decided_by": "user-rami"})
        assert r.status_code == 200
        assert r.json()["status"] == "accepted"

    def test_invalid_decision_value_is_rejected(self, client):
        headers = auth_headers(client)
        recs = client.get("/api/v1/recommendations", params={"farm_id": "farm-origami"}, headers=headers).json()
        rec_id = recs[0]["id"]
        r = client.patch(f"/api/v1/recommendations/{rec_id}/decision", headers=headers, json={"decision": "maybe", "decided_by": "user-rami"})
        assert r.status_code == 422

    def test_accepted_recommendation_survives_a_refresh(self, client):
        headers = auth_headers(client)
        recs = client.get("/api/v1/recommendations", params={"farm_id": "farm-origami"}, headers=headers).json()
        rec_id = next(r["id"] for r in recs if r["rule_id"] == "RULE-HEALTH-RISK")
        client.patch(f"/api/v1/recommendations/{rec_id}/decision", headers=headers, json={"decision": "accepted", "decided_by": "user-rami"})

        recs_after = client.get("/api/v1/recommendations", params={"farm_id": "farm-origami"}, headers=headers).json()
        assert any(r["id"] == rec_id and r["status"] == "accepted" for r in recs_after)


class TestReports:
    def test_morning_briefing_has_kpis_and_priorities(self, client):
        headers = auth_headers(client)
        r = client.get("/api/v1/morning-briefing", params={"farm_id": "farm-origami"}, headers=headers)
        assert r.status_code == 200
        body = r.json()
        assert body["kpis"]["animals"] == 12
        assert len(body["priorities"]) > 0

    def test_daily_summary_matches_seeded_totals(self, client):
        headers = auth_headers(client)
        r = client.get("/api/v1/reports/daily-summary", params={"farm_id": "farm-origami"}, headers=headers)
        assert r.status_code == 200
        body = r.json()
        assert body["revenue_today"] == 12845.0
        assert body["expenses_today"] == 4230.0
        assert body["gross_margin"] == 8615.0


class TestSync:
    def test_push_is_idempotent_on_replay(self, client):
        headers = auth_headers(client)
        item = {
            "idempotency_key": "batch-1-item-1",
            "operation": "create",
            "entity_type": "task",
            "entity_id": "task-1",
            "payload": {"status": "done"},
            "client_created_at": "2026-05-13T09:00:00Z",
        }
        payload = {"farm_id": "farm-origami", "device_id": "tablet-01", "items": [item]}

        r1 = client.post("/api/v1/sync/push", headers=headers, json=payload)
        assert r1.status_code == 200
        assert r1.json()["results"][0]["status"] == "accepted"

        r2 = client.post("/api/v1/sync/push", headers=headers, json=payload)
        assert r2.json()["results"][0]["status"] == "duplicate"

    def test_pull_returns_events_after_cursor(self, client):
        headers = auth_headers(client)
        client.post(
            "/api/v1/observations",
            headers=headers,
            json={"farm_id": "farm-origami", "entity_type": "animal", "entity_id": "cow-214", "observation_type": "limping", "observer_id": "user-worker-1"},
        )
        r = client.get("/api/v1/sync/pull", params={"farm_id": "farm-origami"}, headers=headers)
        assert r.status_code == 200
        body = r.json()
        assert any(e["event_type"] == "observation_recorded" for e in body["events"])
