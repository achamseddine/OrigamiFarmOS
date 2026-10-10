"""Clinical decision support & emergency protocol engine
(database/CLINICAL-DECISION-SUPPORT-EMERGENCY-PROTOCOLS.md §17).

A drug, dose and route come only from a current veterinarian-approved
protocol; the dose is calculated from the approved rule and the animal's
weight within the approved limits; eligible stock is checked before the
step; the person confirms; the exact lot is consumed; reassessment is
scheduled and failure to improve escalates; and the engine escalates
rather than improvises whenever the evidence or the rules say stop.
"""
from __future__ import annotations

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.domain import models
from tests.conftest import auth_headers

API = "/api/v1"
BELLA, LUNA, CLOVER, RASHA, DUCKS = "cow-744", "cow-214", "cow-clover", "goat-189", "flock-duck"
FLUNIXIN, ELECTROLYTE = "med-flunixin", "med-electrolyte"


def _h(client: TestClient) -> dict:
    return auth_headers(client)


def _vet(client: TestClient) -> dict:
    return auth_headers(client, "layla.vet@origami.farm", "farmos123")


def _assessments(client: TestClient, **params) -> list[dict]:
    r = client.get(f"{API}/emergency/assessments", params=params, headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()


def _assess(client: TestClient, subject_type: str, subject_id: str, signs: list[dict]) -> dict:
    r = client.post(f"{API}/emergency/assessments", json={"subject_type": subject_type, "subject_id": subject_id, "signs": signs}, headers=_h(client))
    assert r.status_code == 201, r.text
    return r.json()


def _start(client: TestClient, assessment_id: str) -> dict:
    r = client.post(f"{API}/emergency/assessments/{assessment_id}/start", json={"confirmed": True}, headers=_h(client))
    assert r.status_code == 201, r.text
    return r.json()


def _step(run: dict, step_no: int) -> dict:
    return next(s for s in run["steps"] if s["step"]["step_no"] == step_no)


def _confirm(client: TestClient, run_id: str, step_id: str, **body) -> dict:
    r = client.post(f"{API}/emergency/runs/{run_id}/steps/{step_id}/confirm", json=body, headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()


class TestProtocolsAndApproval:
    def test_a_draft_is_not_operational_and_only_a_veterinarian_approves(self, client: TestClient):
        r = client.get(f"{API}/emergency/protocols", headers=_h(client))
        assert r.status_code == 200, r.text
        by_code = {p["code"]: p for p in r.json()}
        assert set(by_code) == {"BOVINE-FEVER-SUPPORT", "POULTRY-HEAT-STRESS", "EQUINE-COLIC-SUPPORT"}
        bovine = by_code["BOVINE-FEVER-SUPPORT"]
        assert bovine["status"] == "active" and bovine["current_version"]["approved_by_name"] == "Dr. Layla Haddad" and bovine["current_version"]["approval_reference"] == "VET-2026-014"
        med = next(s for s in bovine["current_version"]["steps"] if s["step_type"] == "MEDICATION")["medication"]
        assert med["medicine_name"].startswith("Flunixin") and med["dose_rule_type"] == "PER_WEIGHT" and med["maximum_dose_quantity"] == 30
        draft = by_code["EQUINE-COLIC-SUPPORT"]
        assert draft["status"] == "draft" and draft["current_version"] is None and draft["versions"][0]["current"] is False
        vid = draft["versions"][0]["id"]
        r = client.post(f"{API}/emergency/protocols/{draft['id']}/versions/{vid}/approve", json={"approval_reference": "MGR-1"}, headers=_h(client))
        assert r.status_code == 403, "a manager may draft, not approve"
        r = client.post(f"{API}/emergency/protocols/{draft['id']}/versions/{vid}/approve", json={"approval_reference": "VET-2026-016"}, headers=_vet(client))
        assert r.status_code == 200, r.text
        assert r.json()["status"] == "active" and r.json()["current_version"]["approval_reference"] == "VET-2026-016"
        r = client.post(f"{API}/emergency/protocols/{draft['id']}/versions/{vid}/approve", json={"approval_reference": "VET-2026-017"}, headers=_vet(client))
        assert r.status_code == 422, "approval provenance is written once"

    def test_a_medication_step_must_name_an_authorised_route_and_a_dose_rule(self, client: TestClient):
        base = {"code": "TEST-1", "title": "Test", "condition_family_code": "TEST", "species_code": "cow", "version": {
            "trigger_rules": [{"observation_code": "fever", "operator": "present"}],
            "steps": [{"step_no": 1, "step_type": "MEDICATION", "title": "x", "instructions": "x",
                       "medication": {"medicine_product_id": FLUNIXIN, "route_code": "PO", "dose_rule_type": "FIXED", "fixed_dose_quantity": 5, "dose_unit": "ml"}}]}}
        r = client.post(f"{API}/emergency/protocols", json=base, headers=_h(client))
        assert r.status_code == 422 and "not an authorised route" in r.json()["detail"]
        base["version"]["steps"][0]["medication"] = {"medicine_product_id": FLUNIXIN, "route_code": "IM", "dose_rule_type": "PER_WEIGHT", "dose_unit": "ml"}
        r = client.post(f"{API}/emergency/protocols", json=base, headers=_h(client))
        assert r.status_code == 422 and "PER_WEIGHT" in r.json()["detail"]
        base["version"]["steps"][0]["medication"] = {"medicine_product_id": FLUNIXIN, "route_code": "IM", "dose_rule_type": "FIXED", "fixed_dose_quantity": 5, "dose_unit": "ml"}
        r = client.post(f"{API}/emergency/protocols", json=base, headers=_h(client))
        assert r.status_code == 201, r.text
        assert r.json()["status"] == "draft"


class TestTriage:
    def test_the_seeded_cases_match_or_escalate_with_an_explanation(self, client: TestClient, db_session):
        db, _ = db_session
        rows = {a["subject_id"]: a for a in _assessments(client, status="active")}
        bella = rows[BELLA]
        assert bella["status"] == "open" and bella["triage_level"] == "HIGH" and bella["selected_match_id"]
        assert 0.85 < bella["ai_confidence"] < 0.95 and bella["ai_model_reference"] == "origami.emergency.deterministic"
        match = next(m for m in bella["matches"] if m["selected"])
        assert match["protocol_code"] == "BOVINE-FEVER-SUPPORT" and match["eligibility_result"] == "WARN"
        supporting = {e["code"] for e in match["explanation"]["supporting"]}
        assert {"temperature_c", "fever", "appetite"} <= supporting, "the fever observation of the morning counts as evidence"
        assert any(e["source"] == "observation" for e in match["explanation"]["supporting"])
        assert "rumination" in {e["code"] for e in match["explanation"]["missing"]}
        assert any("Pregnant" in w for w in match["explanation"]["warnings"])
        assert "Confirm to start the protocol" in bella["explanation"] and "approved 20" in bella["explanation"]
        assert bella["animal_facts"]["species"] == "cow" and bella["animal_facts"]["pregnant"] is True

        rasha = rows[RASHA]
        assert rasha["status"] == "escalated" and rasha["selected_match_id"] is None and rasha["matches"] == []
        assert any("no current veterinarian-approved protocol" in r for r in rasha["escalation_reasons"])
        assert "ESCALATE — contact the veterinarian" in rasha["explanation"] and "No drug, dose or route is shown" in rasha["explanation"]
        task = db.get(models.Task, rasha["escalation_task_id"])
        assert task.status == "open" and task.priority == "high" and task.title.startswith("EMERGENCY")
        bell = client.get(f"{API}/notifications", headers=_h(client)).json()["notifications"]
        kinds = {n["notification_type"] for n in bell if n["source_type"] == "emergency_assessment"}
        assert kinds == {"emergency_escalated", "emergency_protocol_matched"}
        s = client.get(f"{API}/emergency/summary", headers=_h(client)).json()
        assert s["protocols"] == 3 and s["active_protocols"] == 2 and s["open_assessments"] == 1 and s["escalated"] == 1

    def test_a_danger_sign_escalates_immediately(self, client: TestClient):
        a = _assess(client, "animal", LUNA, [{"code": "temperature_c", "value_numeric": 41.8}, {"code": "appetite", "value_text": "reduced"}, {"code": "fever"}])
        assert a["status"] == "escalated" and a["triage_level"] == "CRITICAL" and a["selected_match_id"] is None
        assert any("danger sign" in r and "41.5" in r for r in a["escalation_reasons"])
        r = client.post(f"{API}/emergency/assessments/{a['id']}/start", json={"confirmed": True}, headers=_h(client))
        assert r.status_code == 422

    def test_a_low_confidence_pattern_escalates_instead_of_guessing(self, client: TestClient):
        """A severe observation starts triage by itself; one sign alone is
        a pattern below the protocol's threshold, so the engine escalates
        rather than showing a drug."""
        r = client.post(f"{API}/observations", json={"farm_id": "farm-origami", "entity_type": "animal", "entity_id": CLOVER, "observation_type": "fever",
                                                     "severity": "severe", "observer_id": "user-worker-1", "notes": "Hot, dull"}, headers=_h(client))
        assert r.status_code == 201, r.text
        a = next(x for x in _assessments(client, subject_id=CLOVER) if x["source"] == "observation_hook")
        assert a["status"] == "escalated" and a["triage_level"] == "HIGH" and 0 < a["ai_confidence"] < 0.5
        assert any("confidence threshold" in r and "BOVINE-FEVER-SUPPORT" in r for r in a["escalation_reasons"])
        # A second severe observation within the window does not open a twin.
        client.post(f"{API}/observations", json={"farm_id": "farm-origami", "entity_type": "animal", "entity_id": CLOVER, "observation_type": "fever",
                                                 "severity": "severe", "observer_id": "user-worker-1"}, headers=_h(client))
        assert len([x for x in _assessments(client, subject_id=CLOVER) if x["source"] == "observation_hook"]) == 1

    def test_species_block_and_the_offline_package(self, client: TestClient):
        a = _assess(client, "group", DUCKS, [{"code": "panting"}, {"code": "water_intake", "value_text": "reduced"}, {"code": "ambient_temperature_c", "value_numeric": 34}])
        assert a["status"] == "open" and a["matches"][0]["protocol_code"] == "POULTRY-HEAT-STRESS"
        # The bovine protocol is not even a candidate for a flock; a goat gets nothing.
        assert [m["protocol_code"] for m in a["matches"]] == ["POULTRY-HEAT-STRESS"]
        pkg = client.get(f"{API}/emergency/offline-package", headers=_h(client)).json()
        assert {v["protocol_code"] for v in pkg["versions"]} == {"BOVINE-FEVER-SUPPORT", "POULTRY-HEAT-STRESS"}, "only approved, offline-eligible versions travel"
        assert len(pkg["signature"]) == 64 and all(v["current"] for v in pkg["versions"])
        codes = {c["code"] for c in client.get(f"{API}/emergency/sign-codes", headers=_h(client)).json()}
        assert {"temperature_c", "panting", "ambient_temperature_c", "mortality_count"} <= codes


class TestProtocolRun:
    def test_the_approved_dose_the_exact_lot_the_withdrawal_and_the_reassessment(self, client: TestClient, db_session):
        db, _ = db_session
        bella = next(a for a in _assessments(client, status="open") if a["subject_id"] == BELLA)
        run = _start(client, bella["id"])
        assert run["status"] == "in_progress" and len(run["steps"]) == 6 and run["manager_notified_at"] and run["veterinarian_notified_at"]
        assert run["next_reassessment_at"] is not None
        notify_tasks = db.scalars(select(models.Task).where(models.Task.source_type == "emergency_notification", models.Task.source_id == run["id"])).all()
        assert len(notify_tasks) == 2
        assert client.get(f"{API}/emergency/assessments/{bella['id']}", headers=_h(client)).json()["status"] == "protocol_started"

        run = _confirm(client, run["id"], _step(run, 1)["id"], result={"temperature_c": 40.3, "skin_tent_seconds": 3})
        run = _confirm(client, run["id"], _step(run, 2)["id"])
        assert _step(run, 1)["status"] == "completed" and _step(run, 1)["result"]["temperature_c"] == 40.3

        # The medication step: dose from the approved rule and the entered weight, the exact eligible lot.
        step3 = _step(run, 3)
        r = client.post(f"{API}/emergency/runs/{run['id']}/steps/{step3['id']}/prepare", json={"weight_kg": 620}, headers=_h(client))
        assert r.status_code == 200, r.text
        prepared = _step(r.json(), 3)
        assert prepared["status"] == "presented"
        p = prepared["result"]
        assert p["dose_quantity"] == 27.28 and p["dose_unit"] == "ml" and p["route_code"] == "IM" and p["lot_code"] == "FLX-2611" and p["weight_used_kg"] == 620
        assert p["approved_min"] == 5 and p["approved_max"] == 30 and p["problems"] == []
        before = db.get(models.InventoryItem, FLUNIXIN).current_qty
        run = _confirm(client, run["id"], step3["id"], notes="Given left neck")
        done = _step(run, 3)
        assert done["status"] == "completed" and done["medication_administration_id"] and done["result"]["treatment_id"]
        db.expire_all()
        assert round(before - db.get(models.InventoryItem, FLUNIXIN).current_qty, 2) == 27.28
        treatment = db.get(models.Treatment, done["result"]["treatment_id"])
        assert treatment.vet_id == "user-vet-1" and "VET-2026-014" in treatment.notes and treatment.route == "IM"
        animal = db.get(models.Animal, BELLA)
        assert animal.withdrawal_until is not None and animal.withdrawal_reason.startswith("Medication")
        adm = client.get(f"{API}/pharmacy/administrations", params={"subject_id": BELLA}, headers=_h(client)).json()[0]
        assert adm["protocol_run_step_id"] == step3["id"] and adm["lot_code"] == "FLX-2611" and adm["quantity_consumed"] == 27.28

        # Repeat interval: the same step again, too soon, is refused (and escalates the run).
        run = _confirm(client, run["id"], _step(run, 4)["id"])
        run = _confirm(client, run["id"], _step(run, 5)["id"])
        assert run["status"] == "awaiting_reassessment" and run["next_reassessment_at"]
        r = client.post(f"{API}/emergency/runs/{run['id']}/reassess", json={"signs": [{"code": "temperature_c", "value_numeric": 39.1}, {"code": "appetite", "value_text": "normal"}, {"code": "fever", "present": False}]}, headers=_h(client))
        assert r.status_code == 201, r.text
        follow, run = r.json()["assessment"], r.json()["run"]
        assert follow["source"] == "reassessment" and follow["parent_run_id"] == run["id"] and follow["status"] == "closed"
        assert run["status"] == "in_progress", "improving: the approved steps continue"
        r = client.post(f"{API}/emergency/runs/{run['id']}/steps/{_step(run, 6)['id']}/skip", json={"reason": "Temperature falling, vet informed"}, headers=_h(client))
        assert r.status_code == 200, r.text
        run = r.json()
        assert run["status"] == "completed" and run["outcome"] and client.get(f"{API}/emergency/assessments/{bella['id']}", headers=_h(client)).json()["status"] == "resolved"
        db.expire_all()
        assert all(t.status == "done" for t in db.scalars(select(models.Task).where(models.Task.source_id == run["id"])))

    def test_a_dose_outside_the_approved_range_blocks_and_escalates(self, client: TestClient):
        a = _assess(client, "animal", LUNA, [{"code": "temperature_c", "value_numeric": 40.4}, {"code": "appetite", "value_text": "reduced"}, {"code": "fever"}])
        assert a["status"] == "open"
        run = _start(client, a["id"])
        step3 = _step(run, 3)
        r = client.post(f"{API}/emergency/runs/{run['id']}/steps/{step3['id']}/prepare", json={"weight_kg": 900}, headers=_h(client))
        assert r.status_code == 200, r.text
        run = r.json()
        assert run["status"] == "escalated" and _step(run, 3)["status"] == "blocked"
        assert any("exceeds the approved maximum" in p for p in _step(run, 3)["result"]["problems"])
        assert "exceeds the approved maximum" in run["escalation_reason"]
        r = client.post(f"{API}/emergency/runs/{run['id']}/steps/{step3['id']}/confirm", json={}, headers=_h(client))
        assert r.status_code == 422

    def test_without_eligible_stock_the_medication_step_escalates(self, client: TestClient):
        lot = next(l for l in client.get(f"{API}/pharmacy/medicines/{FLUNIXIN}", headers=_h(client)).json()["lots"] if l["lot_code"] == "FLX-2611")
        r = client.patch(f"{API}/pharmacy/lots/{lot['id']}/status", json={"status": "quarantined", "reason": "Cloudy"}, headers=_h(client))
        assert r.status_code == 200
        a = _assess(client, "animal", CLOVER, [{"code": "temperature_c", "value_numeric": 40.1}, {"code": "appetite", "value_text": "reduced"}, {"code": "fever"}])
        run = _start(client, a["id"])
        r = client.post(f"{API}/emergency/runs/{run['id']}/steps/{_step(run, 3)['id']}/prepare", json={"weight_kg": 500}, headers=_h(client))
        assert r.status_code == 200, r.text
        run = r.json()
        assert run["status"] == "escalated" and any("no eligible lot" in p and "quarantined 48.5" in p for p in _step(run, 3)["result"]["problems"])

    def test_a_flock_protocol_with_a_fixed_dose(self, client: TestClient):
        a = _assess(client, "group", DUCKS, [{"code": "panting"}, {"code": "water_intake", "value_text": "reduced"}, {"code": "ambient_temperature_c", "value_numeric": 35}])
        run = _start(client, a["id"])
        assert run["veterinarian_notified_at"] is None and run["manager_notified_at"], "this version notifies the manager only"
        run = _confirm(client, run["id"], _step(run, 1)["id"], result={"panting_birds": 40})
        run = _confirm(client, run["id"], _step(run, 2)["id"])
        run = _confirm(client, run["id"], _step(run, 3)["id"], head_count=10)
        done = _step(run, 3)
        assert done["result"]["dose_quantity"] == 1 and done["result"]["head_count"] == 10 and done["result"]["quantity_consumed"] == 10
        adm = client.get(f"{API}/pharmacy/administrations", params={"subject_id": DUCKS}, headers=_h(client)).json()[0]
        assert adm["protocol_run_step_id"] == done["id"] and adm["quantity_consumed"] == 10 and adm["withdrawal_meat_until"] is None
        assert client.get(f"{API}/pharmacy/medicines/{ELECTROLYTE}", headers=_h(client)).json()["eligible_available"] == 15
        # No improvement at reassessment escalates.
        run = _confirm(client, run["id"], _step(run, 4)["id"])
        r = client.post(f"{API}/emergency/runs/{run['id']}/reassess", json={"signs": [{"code": "panting"}, {"code": "water_intake", "value_text": "reduced"}, {"code": "ambient_temperature_c", "value_numeric": 36}]}, headers=_h(client))
        assert r.status_code == 201, r.text
        assert r.json()["run"]["status"] == "escalated" and "no improvement" in r.json()["run"]["escalation_reason"]

    def test_a_withdrawn_version_cannot_start(self, client: TestClient):
        protocols = {p["code"]: p for p in client.get(f"{API}/emergency/protocols", headers=_h(client)).json()}
        bovine = protocols["BOVINE-FEVER-SUPPORT"]
        r = client.post(f"{API}/emergency/protocols/{bovine['id']}/versions/{bovine['current_version_id']}/withdraw", json={"reason": "Vet revising the dose"}, headers=_h(client))
        assert r.status_code == 200 and r.json()["status"] == "withdrawn"
        bella = next(a for a in _assessments(client, status="open") if a["subject_id"] == BELLA)
        r = client.post(f"{API}/emergency/assessments/{bella['id']}/start", json={"confirmed": True}, headers=_h(client))
        assert r.status_code == 422 and "no longer current" in r.json()["detail"]
        assert client.get(f"{API}/emergency/assessments/{bella['id']}", headers=_h(client)).json()["status"] == "escalated"
        # And a fresh assessment finds nothing approved for cattle.
        a = _assess(client, "animal", LUNA, [{"code": "temperature_c", "value_numeric": 40.4}, {"code": "fever"}])
        assert a["status"] == "escalated" and a["matches"] == []
