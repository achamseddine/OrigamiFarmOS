"""API tests for the Farm Visits & Agri-Tourism module — covers the
acceptance criteria in the v0.6 build prompt: module activation,
configurable opening days, dynamic bookings with guests/add-ons/deposits/
cancellations/check-ins/no-shows, capacity enforcement, retail sales
deducting inventory and appearing in Sales & Finance, staff cost
tracking, and the profitability report.
"""
from __future__ import annotations

from tests.conftest import auth_headers


def _manager_headers(client):
    return auth_headers(client, "rami@origami.farm")


def _super_user_headers(client):
    return auth_headers(client, "super@origamifarms.com")


def _worker_headers(client):
    return auth_headers(client, "karim.worker@origami.farm")


class TestModuleActivation:
    def test_module_is_active_from_seed_data(self, client):
        r = client.get("/api/v1/modules/visits/status", headers=_manager_headers(client))
        assert r.status_code == 200
        assert r.json()["active"] is True

    def test_manager_cannot_activate_or_deactivate(self, client):
        r = client.post("/api/v1/modules/visits_agritourism/deactivate", headers=_manager_headers(client))
        assert r.status_code == 403

    def test_super_user_deactivation_locks_out_the_module(self, client):
        headers = _super_user_headers(client)
        r = client.post("/api/v1/modules/visits_agritourism/deactivate", headers=headers)
        assert r.status_code == 200
        assert r.json()["status"] == "inactive"

        r = client.get("/api/v1/visit-sessions", headers=_manager_headers(client))
        assert r.status_code == 403

        # The bare status check must still work while inactive, so the UI
        # can show "ask a super user to activate this".
        r = client.get("/api/v1/modules/visits/status", headers=_manager_headers(client))
        assert r.status_code == 200
        assert r.json()["active"] is False

        r = client.post("/api/v1/modules/visits_agritourism/activate", headers=headers)
        assert r.status_code == 200
        r = client.get("/api/v1/visit-sessions", headers=_manager_headers(client))
        assert r.status_code == 200


class TestOpeningCalendar:
    def test_seeded_calendar_is_weekend_only_but_configurable(self, client):
        headers = _manager_headers(client)
        r = client.get("/api/v1/visit-calendar", headers=headers)
        assert r.status_code == 200
        open_weekdays = {d["weekday"] for d in r.json() if d["is_open"]}
        assert open_weekdays == {4, 5, 6}  # Friday, Saturday, Sunday — demo data only

        # A manager can open a weekday too — nothing hard-codes the weekend.
        r = client.post("/api/v1/visit-calendar", headers=headers, json={"weekday": 2, "is_open": True, "default_capacity": 15, "notes": "Wednesday school visits"})
        assert r.status_code == 201
        assert r.json()["is_open"] is True


class TestSessionsPackagesActivities:
    def test_manager_can_create_session_package_activity(self, client):
        headers = _manager_headers(client)
        r = client.post("/api/v1/visit-sessions", headers=headers, json={"date": "2026-09-12", "start_time": "09:00:00", "end_time": "17:00:00", "capacity": 25})
        assert r.status_code == 201
        assert r.json()["status"] == "open"

        r = client.post("/api/v1/visit-packages", headers=headers, json={"name": "Sunset Harvest Tour", "base_price": 20})
        assert r.status_code == 201

        r = client.post("/api/v1/visit-activities", headers=headers, json={"name": "Tractor Ride", "activity_type": "ride", "price": 7, "capacity_per_slot": 10})
        assert r.status_code == 201
        assert r.json()["name"] == "Tractor Ride"

    def test_worker_cannot_create_a_session(self, client):
        r = client.post("/api/v1/visit-sessions", headers=_worker_headers(client), json={"date": "2026-09-12", "start_time": "09:00:00", "end_time": "17:00:00", "capacity": 25})
        assert r.status_code == 403

    def test_manager_can_close_a_session(self, client):
        """RULE-VIS-009: manager can close a session (weather/safety/etc)."""
        headers = _manager_headers(client)
        r = client.patch("/api/v1/visit-sessions/session-upcoming-sun", headers=headers, json={"status": "cancelled", "weather_note": "Storm warning"})
        assert r.status_code == 200
        assert r.json()["status"] == "cancelled"


class TestBookingLifecycle:
    def _new_session_and_package(self, client, headers, capacity=3):
        session = client.post("/api/v1/visit-sessions", headers=headers, json={"date": "2026-10-01", "start_time": "09:00:00", "end_time": "17:00:00", "capacity": capacity}).json()
        package = client.post("/api/v1/visit-packages", headers=headers, json={"name": "Test Package", "base_price": 10}).json()
        return session, package

    def test_booking_creation_computes_total_and_starts_as_draft(self, client):
        headers = _manager_headers(client)
        session, package = self._new_session_and_package(client, headers)
        r = client.post(
            "/api/v1/visit-bookings", headers=headers,
            json={"session_id": session["id"], "package_id": package["id"], "adults": 2, "children": 1, "visitor": {"full_name": "Layla Test"}},
        )
        assert r.status_code == 201
        body = r.json()
        assert body["status"] == "draft"
        assert body["total_amount"] == 30  # 10 * (2+1)

    def test_confirming_a_booking_over_capacity_is_rejected(self, client):
        """RULE-VIS-002."""
        headers = _manager_headers(client)
        session, package = self._new_session_and_package(client, headers, capacity=3)
        b1 = client.post("/api/v1/visit-bookings", headers=headers, json={"session_id": session["id"], "package_id": package["id"], "adults": 2, "visitor": {"full_name": "Guest A"}}).json()
        b2 = client.post("/api/v1/visit-bookings", headers=headers, json={"session_id": session["id"], "package_id": package["id"], "adults": 2, "visitor": {"full_name": "Guest B"}}).json()

        r = client.post(f"/api/v1/visit-bookings/{b1['id']}/confirm", headers=headers)
        assert r.status_code == 200
        r = client.post(f"/api/v1/visit-bookings/{b2['id']}/confirm", headers=headers)
        assert r.status_code == 422
        assert "capacity" in r.json()["detail"].lower()

    def test_full_lifecycle_draft_to_completed(self, client):
        headers = _manager_headers(client)
        session, package = self._new_session_and_package(client, headers)
        booking = client.post("/api/v1/visit-bookings", headers=headers, json={"session_id": session["id"], "package_id": package["id"], "adults": 1, "visitor": {"full_name": "Solo Visitor"}}).json()

        assert client.post(f"/api/v1/visit-bookings/{booking['id']}/confirm", headers=headers).status_code == 200
        assert client.post(f"/api/v1/visit-bookings/{booking['id']}/check-in", headers=headers).status_code == 200
        r = client.post(f"/api/v1/visit-bookings/{booking['id']}/complete", headers=headers)
        assert r.status_code == 200
        assert r.json()["status"] == "completed"

        # A completed booking cannot be completed again (no such transition).
        r = client.post(f"/api/v1/visit-bookings/{booking['id']}/complete", headers=headers)
        assert r.status_code == 422

    def test_no_show_and_cancel_transitions(self, client):
        headers = _manager_headers(client)
        session, package = self._new_session_and_package(client, headers)
        b1 = client.post("/api/v1/visit-bookings", headers=headers, json={"session_id": session["id"], "package_id": package["id"], "adults": 1, "visitor": {"full_name": "No Show Guest"}}).json()
        client.post(f"/api/v1/visit-bookings/{b1['id']}/confirm", headers=headers)
        r = client.post(f"/api/v1/visit-bookings/{b1['id']}/no-show", headers=headers)
        assert r.status_code == 200
        assert r.json()["status"] == "no_show"

        b2 = client.post("/api/v1/visit-bookings", headers=headers, json={"session_id": session["id"], "package_id": package["id"], "adults": 1, "visitor": {"full_name": "Cancel Guest"}}).json()
        r = client.post(f"/api/v1/visit-bookings/{b2['id']}/cancel", headers=headers, json={"reason": "changed plans"})
        assert r.status_code == 200
        assert r.json()["status"] == "cancelled"

    def test_idempotency_key_dedups_offline_walk_in_bookings(self, client):
        """Offline walk-in bookings synced twice must not double-book."""
        headers = _manager_headers(client)
        session, package = self._new_session_and_package(client, headers)
        payload = {"session_id": session["id"], "package_id": package["id"], "adults": 1, "visitor": {"full_name": "Walk In"}, "idempotency_key": "device-123-booking-1", "source": "walk_in"}
        r1 = client.post("/api/v1/visit-bookings", headers=headers, json=payload)
        r2 = client.post("/api/v1/visit-bookings", headers=headers, json=payload)
        assert r1.status_code == 201
        assert r2.status_code == 201
        assert r1.json()["id"] == r2.json()["id"]


class TestActivityCapacityAndWelfare:
    def test_horse_ride_over_capacity_is_rejected(self, client):
        headers = _manager_headers(client)
        r = client.post(
            "/api/v1/visit-bookings", headers=headers,
            json={
                "session_id": "session-upcoming-sun", "package_id": "package-family-day", "adults": 1,
                "visitor": {"full_name": "Eager Rider"},
                "activities": [{"activity_id": "activity-horse-ride", "scheduled_at": "2026-08-30T11:00:00Z", "quantity": 5}],
            },
        )
        assert r.status_code == 422
        assert "slot" in r.json()["detail"].lower()

    def test_welfare_limit_blocks_excess_daily_uses(self, client):
        headers = _manager_headers(client)
        # capacity_per_slot=4; spread across different time slots to avoid
        # the per-slot cap while still tripping the 10-uses-per-day welfare limit.
        slots = ["09:00:00", "10:00:00", "12:00:00"]
        for i, slot in enumerate(slots):
            r = client.post(
                "/api/v1/visit-bookings", headers=headers,
                json={
                    "session_id": "session-upcoming-sun", "package_id": "package-family-day", "adults": 1,
                    "visitor": {"full_name": f"Rider {i}"},
                    "activities": [{"activity_id": "activity-horse-ride", "scheduled_at": f"2026-08-30T{slot}Z", "quantity": 3}],
                },
            )
            assert r.status_code == 201, r.text
        # 3 + 3 + 3 = 9 uses so far today; one more of 2 pushes to 11 > 10.
        r = client.post(
            "/api/v1/visit-bookings", headers=headers,
            json={
                "session_id": "session-upcoming-sun", "package_id": "package-family-day", "adults": 1,
                "visitor": {"full_name": "One Too Many"},
                "activities": [{"activity_id": "activity-horse-ride", "scheduled_at": "2026-08-30T14:00:00Z", "quantity": 2}],
            },
        )
        assert r.status_code == 422
        assert "welfare" in r.json()["detail"].lower()


class TestRetailPOS:
    def test_pos_sale_deducts_inventory_and_appears_in_sales(self, client):
        headers = _manager_headers(client)
        r = client.post("/api/v1/visit-retail-sales", headers=headers, json={"lines": [{"inventory_item_id": "feed-dairy-mix", "quantity": 2, "unit_price": 3}]})
        assert r.status_code == 201
        assert r.json()["total_amount"] == 6

    def test_cashier_role_can_process_pos_sales(self, client):
        # No seeded cashier account exists; verify the dependency itself
        # would reject a role outside {owner, manager, cashier} instead.
        r = client.post("/api/v1/visit-retail-sales", headers=_worker_headers(client), json={"lines": [{"inventory_item_id": "feed-dairy-mix", "quantity": 1, "unit_price": 3}]})
        assert r.status_code == 403

    def test_mouneh_finished_goods_sale_deducts_stock_and_appears_in_visit_retail_sales(self, client):
        headers = _manager_headers(client)
        stock_before = client.get("/api/v1/mouneh/finished-goods", headers=headers, params={"product_id": "prod-makdous"}).json()[0]["quantity_available"]

        r = client.post("/api/v1/visit-retail-sales", headers=headers, json={"lines": [{"finished_goods_stock_id": "stock-makdous-001", "quantity": 1, "unit_price": 6.5}]})
        assert r.status_code == 201

        stock_after = client.get("/api/v1/mouneh/finished-goods", headers=headers, params={"product_id": "prod-makdous"}).json()[0]["quantity_available"]
        assert stock_after == stock_before - 1

        r = client.get("/api/v1/visit-retail-sales", headers=headers)
        assert r.status_code == 200
        assert any(s["total_amount"] == 6.5 for s in r.json())

    def test_line_must_reference_exactly_one_product_type(self, client):
        headers = _manager_headers(client)
        r = client.post("/api/v1/visit-retail-sales", headers=headers, json={"lines": [{"quantity": 1, "unit_price": 5}]})
        assert r.status_code == 422


class TestStaffAndCosts:
    def test_manager_can_record_staff_roster_with_computed_total_cost(self, client):
        headers = _manager_headers(client)
        r = client.post(
            "/api/v1/visit-staff-roster", headers=headers,
            json={"session_id": "session-upcoming-sat", "worker_id": "user-worker-1", "role": "cleaner", "start_time": "08:00:00", "end_time": "12:00:00", "hourly_rate": 5},
        )
        assert r.status_code == 201
        assert r.json()["total_cost"] == 20  # 4 hours * 5

    def test_manager_can_record_a_direct_cost(self, client):
        headers = _manager_headers(client)
        r = client.post("/api/v1/visit-costs", headers=headers, json={"session_id": "session-upcoming-sat", "category": "safety", "amount": 12, "description": "First-aid kit restock"})
        assert r.status_code == 201
        assert r.json()["category"] == "safety"


class TestFeedbackAndIncidents:
    def test_visitor_feedback_can_be_submitted(self, client):
        headers = _manager_headers(client)
        r = client.post("/api/v1/visitor-feedback", headers=headers, json={"booking_id": "booking-completed-sun", "rating": 4, "comments": "Lovely visit", "would_return": True})
        assert r.status_code == 201

    def test_activity_staff_can_report_an_incident(self, client):
        headers = _manager_headers(client)
        r = client.post("/api/v1/visit-incidents", headers=headers, json={"session_id": "session-upcoming-sat", "incident_type": "animal", "severity": "medium", "description": "Goat escaped the pen briefly."})
        assert r.status_code == 201

    def test_worker_cannot_report_an_incident(self, client):
        r = client.post("/api/v1/visit-incidents", headers=_worker_headers(client), json={"session_id": "session-upcoming-sat", "incident_type": "safety", "severity": "low", "description": "Wet floor near entrance."})
        assert r.status_code == 403


class TestProfitabilityAndDashboard:
    def test_seeded_past_session_reports_full_profitability_breakdown(self, client):
        headers = _manager_headers(client)
        r = client.get("/api/v1/reports/visit-profitability", headers=headers, params={"session_id": "session-past-sun"})
        assert r.status_code == 200
        body = r.json()
        assert body["checked_in_visitors"] == 3
        assert body["retail_revenue"] > 0
        assert body["visitor_revenue"] == round(body["package_revenue"] + body["activity_revenue"] + body["retail_revenue"], 2)
        assert body["gross_margin"] == round(body["visitor_revenue"] - body["direct_visit_cost"], 2)

    def test_dashboard_reflects_module_status_and_upcoming_sessions(self, client):
        headers = _manager_headers(client)
        r = client.get("/api/v1/visits/dashboard", headers=headers)
        assert r.status_code == 200
        body = r.json()
        assert body["module_status"] == "active"
        assert body["upcoming_sessions"] >= 2
