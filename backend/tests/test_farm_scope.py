"""Farm isolation and module permissions on the core endpoints.

Two guarantees (architecture/SECURITY-ARCHITECTURE.md, BEHAVIORAL-MODEL §19):

* **Farm scope.** A token for one farm never reads or writes another
  farm's records — whatever `farm_id` the request names, and whatever id
  of another farm's animal, task or stock item it carries.
* **Module permissions.** A read or write the tablet offers only to the
  holders of a module is refused, server-side, to someone who does not
  hold it.

`TestContractSweep` walks the OpenAPI contract rather than a hand-kept
list, so a new endpoint that takes `farm_id` from the client and forgets
to check it fails here without anyone remembering to add a test.
"""
from __future__ import annotations

from datetime import datetime, timezone

import pytest
from fastapi import HTTPException
from sqlalchemy import select

from app.api.v1 import observations as observations_api
from app.api.v1 import visits as visits_api
from app.core import permissions as perms
from app.core.security import hash_password
from app.domain import models, mouneh_models
from app.domain import visits_models as vm
from app.main import app
from app.repositories.base import new_id
from app.schemas.observations import ALLOWED_ENTITY_TYPES
from app.schemas.visits import BookingActivitySelection
from tests.conftest import auth_headers

API = "/api/v1"
FARM = "farm-origami"
OTHER_FARM = "farm-other"
OTHER_MANAGER = "mgr@other.farm"
PASSWORD = "farmos123"


def _add_user(session, *, user_id, farm_id, email, role, modules=()):
    session.add(models.User(id=user_id, farm_id=farm_id, name=user_id, email=email, password_hash=hash_password(PASSWORD), role=role, language="en"))
    session.flush()
    for code in modules:
        session.add(models.UserModulePermission(
            id=new_id(), farm_id=farm_id, user_id=user_id, module_code=code,
            **{f"can_{a}": v for a, v in perms.DEFAULT_RESPONSIBILITY_GRANT.items()},
        ))


@pytest.fixture()
def other_farm(db_session):
    """A second, unrelated farm with its own manager. Its manager holds
    every permission on *their* farm — which must buy nothing on ours."""
    session, _ = db_session
    session.add(models.Farm(id=OTHER_FARM, name="Other Farm", country="X", region="Y", timezone="UTC", default_currency="USD"))
    session.flush()
    _add_user(session, user_id="user-other-mgr", farm_id=OTHER_FARM, email=OTHER_MANAGER, role="manager")
    # Licensed for Mouneh, so the Mouneh checks below are the farm check
    # and not the license gate.
    session.add(mouneh_models.ModuleLicense(id=new_id(), farm_id=OTHER_FARM, module_code="mouneh", status="active"))
    session.commit()
    return OTHER_FARM


def _other(client):
    return auth_headers(client, OTHER_MANAGER, PASSWORD)


def _first(session, model, **where):
    stmt = select(model)
    for column, value in where.items():
        stmt = stmt.where(getattr(model, column) == value)
    row = session.scalars(stmt).first()
    assert row is not None, f"seed has no {model.__name__} {where}"
    return row


# --------------------------------------------------------------------------
# The contract sweep
# --------------------------------------------------------------------------
def _farm_scoped_reads() -> list[str]:
    """Every GET whose contract takes `farm_id` (query or path) and needs
    nothing else, rendered with Origami's farm id."""
    out = []
    for path, ops in app.openapi()["paths"].items():
        op = ops.get("get")
        if op is None:
            continue
        params = op.get("parameters", [])
        if not any(p["name"] == "farm_id" for p in params):
            continue
        if any(p.get("required") and p["name"] != "farm_id" for p in params):
            continue
        out.append(path.replace("{farm_id}", FARM))
    return sorted(out)


FARM_SCOPED_READS = _farm_scoped_reads()


def test_the_sweep_covers_the_endpoints_it_was_written_for():
    """Guards the guard: if the OpenAPI walk stopped finding these, the
    sweep below would pass vacuously."""
    for path in ("/sales", "/expenses", "/observations", "/tasks", "/production/milk", "/health/treatments",
                 "/recommendations", "/morning-briefing", "/reports/daily-summary", f"/farms/{FARM}/bootstrap", "/sync/pull"):
        assert f"{API}{path}" in FARM_SCOPED_READS, path


class TestContractSweep:
    @pytest.mark.parametrize("path", FARM_SCOPED_READS)
    def test_another_farm_is_refused(self, client, other_farm, path):
        r = client.get(path, params={"farm_id": FARM}, headers=_other(client))
        assert r.status_code == 403, f"{path} answered {r.status_code} to another farm's manager: {r.text[:200]}"

    @pytest.mark.parametrize("path", FARM_SCOPED_READS)
    def test_the_farms_own_manager_is_served(self, client, path):
        r = client.get(path, params={"farm_id": FARM}, headers=auth_headers(client))
        assert r.status_code == 200, f"{path}: {r.status_code} {r.text[:200]}"


# --------------------------------------------------------------------------
# Writes and reads that name another farm's record by id
# --------------------------------------------------------------------------
class TestCrossFarmRecordIds:
    def test_milk_on_another_farms_animal(self, client, other_farm):
        r = client.post(f"{API}/production/milk", headers=_other(client),
                        json={"animal_id": "cow-744", "session": "morning", "liters": 5, "destination": "stored"})
        assert r.status_code == 404

    def test_eggs_harvest_on_another_farms_flock_and_field(self, client, db_session, other_farm):
        session, _ = db_session
        flock = _first(session, models.Flock, farm_id=FARM)
        field = _first(session, models.Field, farm_id=FARM)
        h = _other(client)
        assert client.post(f"{API}/production/eggs", headers=h, json={"flock_id": flock.id, "total_eggs": 10}).status_code == 404
        assert client.post(f"{API}/production/harvest", headers=h, json={"field_id": field.id, "product_name": "x", "quantity": 1}).status_code == 404

    def test_issuing_another_farms_stock_leaves_it_untouched(self, client, db_session, other_farm):
        session, factory = db_session
        item = _first(session, models.InventoryItem, farm_id=FARM)
        before = item.current_qty
        r = client.post(f"{API}/feed/transactions", headers=_other(client),
                        json={"item_id": item.id, "direction": "out", "quantity": 1, "allow_negative": True})
        assert r.status_code == 404
        with factory() as fresh:
            assert fresh.get(models.InventoryItem, item.id).current_qty == before

    def test_another_farms_task_cannot_be_changed_or_deleted(self, client, db_session, other_farm):
        session, _ = db_session
        task = _first(session, models.Task, farm_id=FARM)
        h = _other(client)
        assert client.patch(f"{API}/tasks/{task.id}", headers=h, json={"status": "done"}).status_code == 404
        assert client.delete(f"{API}/tasks/{task.id}", headers=h).status_code == 404

    def test_a_task_cannot_be_created_in_or_assigned_to_another_farm(self, client, other_farm):
        r = client.post(f"{API}/tasks", headers=_other(client), json={"farm_id": FARM, "title": "planted"})
        assert r.status_code == 403
        r = client.post(f"{API}/tasks", headers=_other(client), json={"farm_id": OTHER_FARM, "title": "x", "assigned_to": "user-worker-1"})
        assert r.status_code == 404

    def test_another_farms_recommendation_cannot_be_decided(self, client, db_session, other_farm):
        client.get(f"{API}/recommendations", params={"farm_id": FARM}, headers=auth_headers(client))  # generate
        session, _ = db_session
        rec = _first(session, models.Recommendation, farm_id=FARM)
        r = client.patch(f"{API}/recommendations/{rec.id}/decision", headers=_other(client),
                         json={"decision": "rejected", "decided_by": "user-other-mgr"})
        assert r.status_code == 404

    def test_another_farms_animal_twin_and_location(self, client, other_farm):
        h = _other(client)
        assert client.get(f"{API}/animals/cow-744", headers=h).status_code == 404
        assert client.patch(f"{API}/animals/cow-744", headers=h, json={"location_label": "Elsewhere"}).status_code == 404

    def test_observation_cannot_be_planted_on_another_farm(self, client, other_farm):
        body = {"entity_type": "animal", "entity_id": "cow-744", "observation_type": "appetite",
                "value_text": "planted", "observer_id": "user-other-mgr"}
        h = _other(client)
        # naming the other farm outright
        assert client.post(f"{API}/observations", headers=h, json={**body, "farm_id": FARM}).status_code == 403
        # or naming its own farm and another farm's animal — which would
        # otherwise attach to that animal's open health case
        assert client.post(f"{API}/observations", headers=h, json={**body, "farm_id": OTHER_FARM}).status_code == 404

    def test_observer_must_be_on_this_farm(self, client, other_farm):
        r = client.post(f"{API}/observations", headers=auth_headers(client), json={
            "farm_id": FARM, "entity_type": "animal", "entity_id": "cow-744", "observation_type": "appetite",
            "value_text": "reduced", "observer_id": "user-other-mgr"})
        assert r.status_code == 422
        # on a colleague's behalf is fine
        r = client.post(f"{API}/observations", headers=auth_headers(client), json={
            "farm_id": FARM, "entity_type": "animal", "entity_id": "cow-744", "observation_type": "appetite",
            "value_text": "reduced", "observer_id": "user-worker-1"})
        assert r.status_code == 201

    def test_milk_recorder_must_be_on_this_farm(self, client, other_farm):
        r = client.post(f"{API}/production/milk", headers=auth_headers(client), json={
            "animal_id": "cow-744", "session": "morning", "liters": 5, "destination": "stored", "recorded_by": "user-other-mgr"})
        assert r.status_code == 422

    def test_legacy_sync_push_stays_on_its_own_farm(self, client, db_session, other_farm):
        session, _ = db_session
        task = _first(session, models.Task, farm_id=FARM)
        h = _other(client)
        item = {"idempotency_key": new_id(), "operation": "update", "entity_type": "task", "entity_id": task.id,
                "payload": {"status": "done"}, "client_created_at": datetime.now(timezone.utc).isoformat()}
        r = client.post(f"{API}/sync/push", headers=h, json={"farm_id": FARM, "device_id": "t", "items": [item]})
        assert r.status_code == 403
        r = client.post(f"{API}/sync/push", headers=h, json={"farm_id": OTHER_FARM, "device_id": "t", "items": [item]})
        assert r.status_code == 200 and r.json()["results"][0]["status"] == "rejected"
        session.expire_all()
        assert session.get(models.Task, task.id).status != "done"

    def test_mouneh_cost_preview_does_not_price_another_farms_recipe(self, client, db_session, other_farm):
        session, _ = db_session
        product = _first(session, mouneh_models.MounehProduct, farm_id=FARM)
        recipe = _first(session, mouneh_models.MounehRecipe, product_id=product.id)
        material = _first(session, mouneh_models.RawMaterial, farm_id=FARM)
        h = _other(client)
        assert client.post(f"{API}/mouneh/cost-preview", headers=h, json={"recipe_id": recipe.id}).status_code == 404
        assert client.post(f"{API}/mouneh/cost-preview", headers=h, json={"product_id": product.id}).status_code == 404
        r = client.post(f"{API}/mouneh/cost-preview", headers=h,
                        json={"materials": [{"material_id": material.id, "quantity": 1, "unit": material.unit}], "output_qty": 1})
        assert r.status_code == 404
        # the farm's own preview still prices
        assert client.post(f"{API}/mouneh/cost-preview", headers=auth_headers(client), json={"recipe_id": recipe.id}).status_code == 200

    def test_a_booking_cannot_use_another_farms_activity(self, db_session):
        session, _ = db_session
        activity = _first(session, vm.VisitActivity, farm_id=FARM)
        selection = BookingActivitySelection(activity_id=activity.id, scheduled_at=datetime.now(timezone.utc), quantity=1)
        with pytest.raises(HTTPException) as refused:
            visits_api._validate_and_price_activities(session, [selection], farm_id=OTHER_FARM)
        assert refused.value.status_code == 404


class TestBootstrap:
    def test_never_returns_password_hashes(self, client):
        r = client.get(f"{API}/farms/{FARM}/bootstrap", headers=auth_headers(client))
        assert r.status_code == 200
        users = r.json()["users"]
        assert users and all("password_hash" not in u for u in users)


# --------------------------------------------------------------------------
# Module permissions on the same farm
# --------------------------------------------------------------------------
@pytest.fixture()
def agriculture_employee(db_session):
    """The seeded "produce" department: Agriculture, Produce & Harvest and
    Inventory — no milk, eggs, sales or animals."""
    session, _ = db_session
    _add_user(session, user_id="user-agri", farm_id=FARM, email="agri@origami.farm", role="worker",
              modules=perms.BASELINE_EMPLOYEE_MODULES + perms.DEPARTMENT_MODULE_PRESETS["produce"])
    session.commit()
    return ("agri@origami.farm", PASSWORD)


class TestModulePermissions:
    def test_animal_care_worker_cannot_read_finance(self, client):
        h = auth_headers(client, "karim.worker@origami.farm")
        for path in ("/sales", "/expenses", "/customers", "/reports/daily-summary"):
            r = client.get(f"{API}{path}", params={"farm_id": FARM}, headers=h)
            assert r.status_code == 403, path
            assert "Ask a farm manager" in r.json()["detail"]

    def test_animal_care_worker_keeps_their_own_screens(self, client):
        h = auth_headers(client, "karim.worker@origami.farm")
        for path in ("/animals", "/health/treatments", "/production/milk", "/production/eggs", "/feed/items",
                     "/feed/transactions", "/tasks", "/recommendations", "/morning-briefing", "/suppliers"):
            r = client.get(f"{API}{path}", params={"farm_id": FARM}, headers=h)
            assert r.status_code == 200, f"{path}: {r.text[:200]}"

    def test_accountant_reads_finance_not_the_herd(self, client):
        h = auth_headers(client, "nadine.acct@origami.farm")
        for path in ("/sales", "/expenses", "/customers", "/reports/daily-summary"):
            assert client.get(f"{API}{path}", params={"farm_id": FARM}, headers=h).status_code == 200, path
        for path in ("/animals", "/health/treatments", "/production/milk", "/observations"):
            assert client.get(f"{API}{path}", params={"farm_id": FARM}, headers=h).status_code == 403, path

    def test_agriculture_employees_produce_screen_still_loads(self, client, agriculture_employee):
        """The tablet's ProductionProvider fetches fields, milk, eggs and
        harvest together for Produce & Harvest; refusing one would blank
        the whole Produce screen."""
        h = auth_headers(client, *agriculture_employee)
        for path in ("/production/fields", "/production/milk", "/production/eggs", "/production/harvest"):
            assert client.get(f"{API}{path}", params={"farm_id": FARM}, headers=h).status_code == 200, path

    def test_agriculture_employee_writes_only_their_own_records(self, client, db_session, agriculture_employee):
        session, _ = db_session
        field = _first(session, models.Field, farm_id=FARM)
        h = auth_headers(client, *agriculture_employee)
        r = client.post(f"{API}/production/harvest", headers=h, json={"field_id": field.id, "product_name": "Tomato", "quantity": 3})
        assert r.status_code == 201
        r = client.post(f"{API}/production/milk", headers=h, json={"animal_id": "cow-744", "session": "morning", "liters": 5, "destination": "stored"})
        assert r.status_code == 403
        r = client.post(f"{API}/observations", headers=h, json={
            "farm_id": FARM, "entity_type": "animal", "entity_id": "cow-744", "observation_type": "appetite",
            "value_text": "x", "observer_id": "user-agri"})
        assert r.status_code == 403
        r = client.post(f"{API}/observations", headers=h, json={
            "farm_id": FARM, "entity_type": "field", "entity_id": field.id, "observation_type": "soil",
            "value_text": "dry", "observer_id": "user-agri"})
        assert r.status_code == 201

    def test_only_a_manager_decides_a_recommendation_in_their_own_name(self, client, db_session):
        mgr = auth_headers(client)
        client.get(f"{API}/recommendations", params={"farm_id": FARM}, headers=mgr)
        session, _ = db_session
        rec = _first(session, models.Recommendation, farm_id=FARM)
        worker = auth_headers(client, "karim.worker@origami.farm")
        r = client.patch(f"{API}/recommendations/{rec.id}/decision", headers=worker, json={"decision": "accepted", "decided_by": "user-worker-1"})
        assert r.status_code == 403
        r = client.patch(f"{API}/recommendations/{rec.id}/decision", headers=mgr, json={"decision": "accepted", "decided_by": "user-owner"})
        assert r.status_code == 403
        r = client.patch(f"{API}/recommendations/{rec.id}/decision", headers=mgr, json={"decision": "accepted", "decided_by": "user-rami"})
        assert r.status_code == 200 and r.json()["status"] == "accepted"
        session.expire_all()
        assert session.get(models.Recommendation, rec.id).decided_by == "user-rami"


def test_every_observable_subject_has_an_owner_and_a_module():
    assert set(observations_api._SUBJECTS) == ALLOWED_ENTITY_TYPES
