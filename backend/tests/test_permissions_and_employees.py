"""Employees, granular module permissions, and the operational writes they
gate (tech spec §7–§17).
"""
from __future__ import annotations

from fastapi.testclient import TestClient

from app.core import permissions as perms
from tests.conftest import auth_headers

FARM_ID = "farm-origami"

MANAGER = ("rami@origami.farm", "farmos123")
WORKER = ("karim.worker@origami.farm", "farmos123")
ACCOUNTANT = ("nadine.acct@origami.farm", "farmos123")


def _headers(client: TestClient, who=MANAGER) -> dict:
    return auth_headers(client, who[0], who[1])


def _create_employee(client: TestClient, *, email: str, name: str = "New Hire", **extra) -> dict:
    payload = {"name": name, "email": email, "password": "farmos12345", "role": "worker", **extra}
    r = client.post("/api/v1/employees", json=payload, headers=_headers(client))
    assert r.status_code == 201, r.text
    return r.json()


class TestModuleCatalog:
    def test_catalog_lists_every_module(self, client: TestClient):
        r = client.get("/api/v1/modules/catalog", headers=_headers(client))
        assert r.status_code == 200
        codes = {m["code"] for m in r.json()}
        assert codes == set(perms.MODULE_CODES)

    def test_licensed_modules_report_their_licence_state(self, client: TestClient):
        r = client.get("/api/v1/modules/catalog", headers=_headers(client))
        by_code = {m["code"]: m for m in r.json()}
        assert by_code[perms.MOUNEH_PRODUCTION]["license_code"] == "mouneh"
        assert by_code[perms.ANIMALS]["license_code"] is None
        # A module with no licence gate is always "active".
        assert by_code[perms.ANIMALS]["licensed_active"] is True


class TestMyAccess:
    def test_manager_holds_every_module_with_every_action(self, client: TestClient):
        r = client.get("/api/v1/me/access", headers=_headers(client))
        assert r.status_code == 200
        body = r.json()
        assert body["full_access"] is True
        assert set(body["modules"]) == set(perms.MODULE_CODES)
        assert all(all(actions.values()) for actions in body["modules"].values())

    def test_worker_holds_only_granted_modules(self, client: TestClient):
        body = client.get("/api/v1/me/access", headers=_headers(client, WORKER)).json()
        assert body["full_access"] is False
        assert perms.ANIMALS in body["modules"]
        assert perms.FINANCE not in body["modules"]
        # Default responsibility grant: day-to-day work, but not deletion.
        assert body["modules"][perms.ANIMALS]["create"] is True
        assert body["modules"][perms.ANIMALS]["delete"] is False


class TestEmployeeManagement:
    def test_manager_can_create_an_employee(self, client: TestClient):
        body = _create_employee(client, email="hire1@origami.farm", department="produce")
        assert body["name"] == "New Hire"
        assert body["employment_status"] == "active"
        granted = {p["module_code"] for p in body["permissions"]}
        # Department preset + the baseline every employee gets.
        assert perms.AGRICULTURE in granted
        assert perms.TASKS in granted
        assert perms.FINANCE not in granted

    def test_created_employee_can_log_in(self, client: TestClient):
        _create_employee(client, email="hire2@origami.farm")
        r = client.post("/api/v1/auth/login", json={"email": "hire2@origami.farm", "password": "farmos12345"})
        assert r.status_code == 200, r.text

    def test_duplicate_email_is_rejected(self, client: TestClient):
        _create_employee(client, email="hire3@origami.farm")
        r = client.post(
            "/api/v1/employees",
            json={"name": "Clash", "email": "hire3@origami.farm", "password": "farmos12345"},
            headers=_headers(client),
        )
        assert r.status_code == 409

    def test_worker_cannot_list_or_create_employees(self, client: TestClient):
        assert client.get("/api/v1/employees", headers=_headers(client, WORKER)).status_code == 403
        r = client.post(
            "/api/v1/employees",
            json={"name": "Sneaky", "email": "sneaky@origami.farm", "password": "farmos12345"},
            headers=_headers(client, WORKER),
        )
        assert r.status_code == 403

    def test_manager_can_update_an_employee(self, client: TestClient):
        employee = _create_employee(client, email="hire4@origami.farm")
        r = client.patch(
            f"/api/v1/employees/{employee['id']}",
            json={"job_title": "Herd Lead", "employment_status": "on_leave"},
            headers=_headers(client),
        )
        assert r.status_code == 200, r.text
        assert r.json()["job_title"] == "Herd Lead"
        assert r.json()["employment_status"] == "on_leave"

    def test_deactivating_an_employee_keeps_the_record(self, client: TestClient):
        employee = _create_employee(client, email="hire5@origami.farm")
        assert client.delete(f"/api/v1/employees/{employee['id']}", headers=_headers(client)).status_code == 204
        listed = client.get("/api/v1/employees", headers=_headers(client)).json()
        assert employee["id"] not in {e["id"] for e in listed}
        with_inactive = client.get(
            "/api/v1/employees", params={"include_inactive": True}, headers=_headers(client)
        ).json()
        assert employee["id"] in {e["id"] for e in with_inactive}

    def test_manager_cannot_deactivate_themselves(self, client: TestClient):
        me = client.get("/api/v1/auth/me", headers=_headers(client)).json()
        r = client.delete(f"/api/v1/employees/{me['id']}", headers=_headers(client))
        assert r.status_code == 422


class TestResponsibilityAssignment:
    def test_manager_can_assign_several_modules_at_once(self, client: TestClient):
        """Tech spec §9 "Example F": one employee, several unrelated areas."""
        employee = _create_employee(client, email="multi@origami.farm")
        r = client.put(
            f"/api/v1/employees/{employee['id']}/permissions",
            json={
                "permissions": [
                    {"module_code": perms.ANIMALS, "can_view": True, "can_create": True, "can_edit": True},
                    {"module_code": perms.FEED_NUTRITION, "can_view": True, "can_create": True},
                    {"module_code": perms.INVENTORY, "can_view": True},
                ]
            },
            headers=_headers(client),
        )
        assert r.status_code == 200, r.text
        granted = {p["module_code"]: p for p in r.json()["permissions"]}
        assert set(granted) == {perms.ANIMALS, perms.FEED_NUTRITION, perms.INVENTORY}
        assert granted[perms.INVENTORY]["can_create"] is False

    def test_assignment_replaces_rather_than_appends(self, client: TestClient):
        employee = _create_employee(client, email="replace@origami.farm", department="animals")
        client.put(
            f"/api/v1/employees/{employee['id']}/permissions",
            json={"permissions": [{"module_code": perms.SALES, "can_view": True}]},
            headers=_headers(client),
        )
        detail = client.get(f"/api/v1/employees/{employee['id']}", headers=_headers(client)).json()
        assert {p["module_code"] for p in detail["permissions"]} == {perms.SALES}

    def test_unknown_module_is_rejected(self, client: TestClient):
        employee = _create_employee(client, email="badmod@origami.farm")
        r = client.put(
            f"/api/v1/employees/{employee['id']}/permissions",
            json={"permissions": [{"module_code": "teleportation", "can_view": True}]},
            headers=_headers(client),
        )
        assert r.status_code == 422

    def test_permissions_take_effect_immediately(self, client: TestClient):
        employee = _create_employee(client, email="effect@origami.farm")
        who = ("effect@origami.farm", "farmos12345")
        assert client.get("/api/v1/employees", headers=_headers(client, who)).status_code == 403

        client.put(
            f"/api/v1/employees/{employee['id']}/permissions",
            json={"permissions": [{"module_code": perms.EMPLOYEES, "can_view": True}]},
            headers=_headers(client),
        )
        assert client.get("/api/v1/employees", headers=_headers(client, who)).status_code == 200

    def test_a_manager_role_cannot_be_permission_limited(self, client: TestClient):
        employee = _create_employee(client, email="boss@origami.farm", role="manager")
        r = client.put(
            f"/api/v1/employees/{employee['id']}/permissions",
            json={"permissions": [{"module_code": perms.ANIMALS, "can_view": True}]},
            headers=_headers(client),
        )
        assert r.status_code == 422
        assert "full access" in r.json()["detail"]


class TestAnimalWrites:
    def test_animal_responsible_worker_can_add_an_animal(self, client: TestClient):
        r = client.post(
            "/api/v1/animals",
            json={"tag": "NEW-1", "name": "Amal", "species": "goat", "breed": "Baladi", "sex": "F"},
            headers=_headers(client, WORKER),
        )
        assert r.status_code == 201, r.text
        assert r.json()["tag"] == "NEW-1"

    def test_accountant_without_animals_cannot_add_one(self, client: TestClient):
        r = client.post(
            "/api/v1/animals",
            json={"tag": "NEW-2", "name": "Nope", "species": "cow"},
            headers=_headers(client, ACCOUNTANT),
        )
        assert r.status_code == 403

    def test_duplicate_ear_tag_is_rejected(self, client: TestClient):
        client.post(
            "/api/v1/animals",
            json={"tag": "DUP-1", "name": "First", "species": "cow"},
            headers=_headers(client),
        )
        r = client.post(
            "/api/v1/animals",
            json={"tag": "DUP-1", "name": "Second", "species": "cow"},
            headers=_headers(client),
        )
        assert r.status_code == 409

    def test_financial_fields_are_dropped_for_a_user_without_finance(self, client: TestClient):
        """Money on an animal is Finance data — a herd worker may register
        the animal but not set what it cost."""
        r = client.post(
            "/api/v1/animals",
            json={"tag": "MONEY-1", "name": "Priced", "species": "cow", "purchase_cost": 900},
            headers=_headers(client, WORKER),
        )
        assert r.status_code == 201, r.text
        assert r.json()["purchase_cost"] is None

    def test_manager_can_set_financial_fields(self, client: TestClient):
        r = client.post(
            "/api/v1/animals",
            json={"tag": "MONEY-2", "name": "Priced", "species": "cow", "purchase_cost": 900},
            headers=_headers(client),
        )
        assert r.status_code == 201
        assert r.json()["purchase_cost"] == 900

    def test_full_edit_records_before_and_after_in_the_audit_log(self, client: TestClient):
        created = client.post(
            "/api/v1/animals",
            json={"tag": "EDIT-1", "name": "Before", "species": "cow"},
            headers=_headers(client),
        ).json()
        r = client.put(
            f"/api/v1/animals/{created['id']}",
            json={"name": "After", "weight_kg": 480},
            headers=_headers(client),
        )
        assert r.status_code == 200, r.text
        assert r.json()["name"] == "After"

        audit = client.get(
            "/api/v1/audit",
            params={"entity_type": "animal", "entity_id": created["id"]},
            headers=_headers(client),
        ).json()
        update = next(e for e in audit if e["action"] == "animal_updated")
        assert update["changes_json"]["name"] == {"from": "Before", "to": "After"}
        assert update["user_name"] == "Rami Farah"

    def test_worker_cannot_archive_an_animal(self, client: TestClient):
        created = client.post(
            "/api/v1/animals",
            json={"tag": "ARCH-1", "name": "Keep", "species": "cow"},
            headers=_headers(client, WORKER),
        ).json()
        r = client.put(
            f"/api/v1/animals/{created['id']}", json={"active": False}, headers=_headers(client, WORKER)
        )
        assert r.status_code == 403


class TestAuditTrail:
    def test_employee_creation_is_audited(self, client: TestClient):
        employee = _create_employee(client, email="audited@origami.farm")
        audit = client.get(
            "/api/v1/audit", params={"entity_type": "employee", "entity_id": employee["id"]}, headers=_headers(client)
        ).json()
        assert any(e["action"] == "employee_created" for e in audit)
        assert audit[0]["summary"].startswith("Rami Farah")

    def test_permission_change_records_the_module_diff(self, client: TestClient):
        employee = _create_employee(client, email="permaudit@origami.farm", department="animals")
        client.put(
            f"/api/v1/employees/{employee['id']}/permissions",
            json={"permissions": [{"module_code": perms.SALES, "can_view": True}]},
            headers=_headers(client),
        )
        audit = client.get(
            "/api/v1/audit", params={"entity_type": "employee", "entity_id": employee["id"]}, headers=_headers(client)
        ).json()
        change = next(e for e in audit if e["action"] == "permissions_changed")
        assert change["changes_json"]["modules"]["to"] == [perms.SALES]
        assert perms.ANIMALS in change["changes_json"]["modules"]["from"]

    def test_worker_without_reports_cannot_read_the_audit_log(self, client: TestClient):
        assert client.get("/api/v1/audit", headers=_headers(client, WORKER)).status_code == 403
