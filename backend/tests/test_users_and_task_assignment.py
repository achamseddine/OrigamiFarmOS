from __future__ import annotations

from fastapi.testclient import TestClient

from tests.conftest import auth_headers

FARM_ID = "farm-origami"


class TestUsersRoster:
    def test_manager_can_list_farm_users(self, client: TestClient):
        r = client.get("/api/v1/users", headers=auth_headers(client))
        assert r.status_code == 200, r.text
        emails = {u["email"] for u in r.json()}
        assert "rami@origami.farm" in emails
        assert "karim.worker@origami.farm" in emails
        # department is present on every row (nullable) even for demo accounts that predate it.
        assert all("department" in u for u in r.json())

    def test_worker_can_also_list_the_roster(self, client: TestClient):
        r = client.get("/api/v1/users", headers=auth_headers(client, "karim.worker@origami.farm", "farmos123"))
        assert r.status_code == 200, r.text
        assert len(r.json()) >= 5


class TestAuthMe:
    def test_me_returns_current_profile(self, client: TestClient):
        r = client.get("/api/v1/auth/me", headers=auth_headers(client))
        assert r.status_code == 200, r.text
        assert r.json()["email"] == "rami@origami.farm"
        assert r.json()["role"] == "manager"

    def test_me_requires_a_token(self, client: TestClient):
        r = client.get("/api/v1/auth/me")
        assert r.status_code == 401


class TestTaskAssignmentRbac:
    def test_worker_can_create_a_task_for_themself(self, client: TestClient):
        headers = auth_headers(client, "karim.worker@origami.farm", "farmos123")
        me = client.get("/api/v1/auth/me", headers=headers).json()
        r = client.post("/api/v1/tasks", json={"farm_id": FARM_ID, "title": "Check the fence", "assigned_to": me["id"]}, headers=headers)
        assert r.status_code == 201, r.text

    def test_worker_cannot_assign_a_task_to_someone_else(self, client: TestClient):
        headers = auth_headers(client, "karim.worker@origami.farm", "farmos123")
        other = client.get("/api/v1/users", headers=headers).json()[0]["id"]
        r = client.post("/api/v1/tasks", json={"farm_id": FARM_ID, "title": "Do my job for me", "assigned_to": other}, headers=headers)
        assert r.status_code == 403

    def test_manager_can_assign_a_task_to_a_worker(self, client: TestClient):
        headers = auth_headers(client)
        worker = next(u for u in client.get("/api/v1/users", headers=headers).json() if u["email"] == "karim.worker@origami.farm")
        r = client.post("/api/v1/tasks", json={"farm_id": FARM_ID, "title": "Feed the goats", "assigned_to": worker["id"]}, headers=headers)
        assert r.status_code == 201, r.text
        assert r.json()["assigned_to"] == worker["id"]

    def test_worker_cannot_reassign_someone_elses_task_to_themself(self, client: TestClient):
        manager_headers = auth_headers(client)
        worker_headers = auth_headers(client, "karim.worker@origami.farm", "farmos123")
        owner = client.get("/api/v1/auth/me", headers=auth_headers(client, "owner@origami.farm", "farmos123")).json()
        worker = client.get("/api/v1/auth/me", headers=worker_headers).json()

        task = client.post("/api/v1/tasks", json={"farm_id": FARM_ID, "title": "Owner's task", "assigned_to": owner["id"]}, headers=manager_headers).json()
        r = client.patch(f"/api/v1/tasks/{task['id']}", json={"status": "completed"}, headers=worker_headers)
        assert r.status_code == 403

        r2 = client.patch(f"/api/v1/tasks/{task['id']}", json={"assigned_to": worker["id"]}, headers=worker_headers)
        assert r2.status_code == 403

    def test_assignee_can_update_their_own_task(self, client: TestClient):
        manager_headers = auth_headers(client)
        worker_headers = auth_headers(client, "karim.worker@origami.farm", "farmos123")
        worker = client.get("/api/v1/auth/me", headers=worker_headers).json()

        task = client.post("/api/v1/tasks", json={"farm_id": FARM_ID, "title": "Clean the barn", "assigned_to": worker["id"]}, headers=manager_headers).json()
        r = client.patch(f"/api/v1/tasks/{task['id']}", json={"status": "completed"}, headers=worker_headers)
        assert r.status_code == 200
        assert r.json()["status"] == "completed"

    def test_list_tasks_can_filter_by_assignee(self, client: TestClient):
        headers = auth_headers(client)
        worker = next(u for u in client.get("/api/v1/users", headers=headers).json() if u["email"] == "karim.worker@origami.farm")
        client.post("/api/v1/tasks", json={"farm_id": FARM_ID, "title": "Move the herd", "assigned_to": worker["id"]}, headers=headers)
        r = client.get("/api/v1/tasks", params={"farm_id": FARM_ID, "assigned_to": worker["id"]}, headers=headers)
        assert r.status_code == 200
        assert all(t["assigned_to"] == worker["id"] for t in r.json())
        assert len(r.json()) >= 1

    def test_manager_can_delete_a_task(self, client: TestClient):
        headers = auth_headers(client)
        task = client.post("/api/v1/tasks", json={"farm_id": FARM_ID, "title": "Temporary task"}, headers=headers).json()
        r = client.delete(f"/api/v1/tasks/{task['id']}", headers=headers)
        assert r.status_code == 204

    def test_worker_cannot_delete_a_task(self, client: TestClient):
        manager_headers = auth_headers(client)
        worker_headers = auth_headers(client, "karim.worker@origami.farm", "farmos123")
        task = client.post("/api/v1/tasks", json={"farm_id": FARM_ID, "title": "Another task"}, headers=manager_headers).json()
        r = client.delete(f"/api/v1/tasks/{task['id']}", headers=worker_headers)
        assert r.status_code == 403


class TestNewReadEndpoints:
    def test_list_milk_eggs_harvest_treatments_observations(self, client: TestClient):
        headers = auth_headers(client)
        for path in ("/api/v1/production/milk", "/api/v1/production/eggs", "/api/v1/production/harvest", "/api/v1/health/treatments", "/api/v1/observations"):
            r = client.get(path, params={"farm_id": FARM_ID}, headers=headers)
            assert r.status_code == 200, f"{path}: {r.text}"
            assert isinstance(r.json(), list)

    def test_list_sales_expenses_customers_suppliers(self, client: TestClient):
        headers = auth_headers(client)
        for path in ("/api/v1/sales", "/api/v1/expenses", "/api/v1/customers", "/api/v1/suppliers"):
            r = client.get(path, params={"farm_id": FARM_ID}, headers=headers)
            assert r.status_code == 200, f"{path}: {r.text}"
            assert isinstance(r.json(), list)
