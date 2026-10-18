"""Health cases, diagnoses, treatment plans, standing conditions and
weight history (database/HEALTH-VETERINARY-SCHEMA.md): observation is not
diagnosis, diagnosis is not treatment, a case is the episode they hang
on, weights are dated records, and the emergency engine opens and closes
its own cases.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.domain import health_models as hm
from app.domain import models
from tests.conftest import auth_headers

API = "/api/v1"
BELLA, LUNA, CLOVER, RASHA = "cow-744", "cow-214", "cow-clover", "goat-189"
FLUNIXIN, OXYTET = "med-flunixin", "med-oxytet"


def _h(client: TestClient) -> dict:
    return auth_headers(client)


def _vet(client: TestClient) -> dict:
    return auth_headers(client, "layla.vet@origami.farm", "farmos123")


def _worker(client: TestClient) -> dict:
    return auth_headers(client, "karim.worker@origami.farm", "farmos123")


def _publish_clinical_rules_v2(client: TestClient) -> dict:
    """A second, vet-approved version of the bovine fever protocol that adds
    the clinical eligibility rules (allergy, active diagnosis, weight age)
    and requires a weight no older than 30 days for the dose."""
    protocols = {p["code"]: p for p in client.get(f"{API}/emergency/protocols", headers=_h(client)).json()}
    bovine = protocols["BOVINE-FEVER-SUPPORT"]
    version = bovine["current_version"]
    body = {k: version[k] for k in ("protocol_text", "minimum_match_confidence", "requires_manager_notification", "requires_vet_notification",
                                    "requires_pre_action_confirmation", "offline_eligible", "reassessment_minutes")}
    body["trigger_rules"] = [{k: r[k] for k in ("observation_code", "operator", "threshold_numeric", "threshold_unit", "expected_value_code", "required", "weight", "danger_sign", "label")} for r in version["trigger_rules"]]
    body["eligibility_rules"] = [{k: r[k] for k in ("rule_type", "operator", "rule_payload", "failure_action", "message")} for r in version["eligibility_rules"]] + [
        {"rule_type": "allergy", "rule_payload": {"not": "penicillin_g"}, "failure_action": "REQUIRE_VET", "message": "Recorded penicillin reaction: the vet decides"},
        {"rule_type": "active_diagnosis", "rule_payload": {"not_in": ["renal_failure"]}, "failure_action": "BLOCK", "message": "Not with renal failure"},
        {"rule_type": "weight_age_days", "rule_payload": {"max": 30}, "failure_action": "WARN", "message": "Weight older than 30 days: weigh before dosing"},
    ]
    body["steps"] = [{**{k: s[k] for k in ("step_no", "step_type", "title", "instructions", "required", "requires_confirmation", "timing_offset_minutes")},
                      "medication": ({k: s["medication"][k] for k in ("medicine_product_id", "route_code", "dose_rule_type", "fixed_dose_quantity", "dose_per_weight_quantity", "dose_unit",
                                                                        "weight_unit", "minimum_dose_quantity", "maximum_dose_quantity", "repeat_interval_minutes", "maximum_administrations",
                                                                        "withdrawal_rule_payload")} | {"weight_max_age_days": 30}) if s["medication"] else None} for s in version["steps"]]
    r = client.post(f"{API}/emergency/protocols/{bovine['id']}/versions", json=body, headers=_h(client))
    assert r.status_code == 201, r.text
    v2 = r.json()
    r = client.post(f"{API}/emergency/protocols/{bovine['id']}/versions/{v2['id']}/approve", json={"approval_reference": "VET-2026-020"}, headers=_vet(client))
    assert r.status_code == 200, r.text
    return r.json()


class TestCases:
    def test_a_case_frames_observations_diagnosis_plan_and_treatment(self, client: TestClient, db_session):
        db, _ = db_session
        # The worker records; nobody diagnoses from here.
        r = client.post(f"{API}/observations", json={"farm_id": "farm-origami", "entity_type": "animal", "entity_id": LUNA, "observation_type": "lameness", "severity": "moderate",
                                                     "observer_id": "user-worker-1", "notes": "Left hind"}, headers=_worker(client))
        assert r.status_code == 201, r.text
        obs_id = r.json()["id"]
        accountant = auth_headers(client, "nadine.acct@origami.farm", "farmos123")
        r = client.post(f"{API}/health/cases", json={"subject_type": "animal", "subject_id": LUNA, "severity_code": "moderate", "notes": "Lame since morning"}, headers=accountant)
        assert r.status_code == 403, "opening a case needs animal-health create"
        r = client.post(f"{API}/health/cases", json={"subject_type": "animal", "subject_id": LUNA, "severity_code": "moderate", "notes": "Lame since morning"}, headers=_h(client))
        assert r.status_code == 201, r.text
        case = r.json()
        assert case["case_code"].startswith("HC-") and case["status"] == "open" and case["subject_name"] == "Luna" and case["active_diagnoses"] == []
        assert [o["id"] for o in case["observations"]] == [obs_id], "the last day's observations join the case"
        assert db.get(models.Animal, LUNA).status == "under_observation"
        # A later observation lands on the open case by itself.
        r = client.post(f"{API}/observations", json={"farm_id": "farm-origami", "entity_type": "animal", "entity_id": LUNA, "observation_type": "temperature_c", "value_numeric": 39.2,
                                                     "observer_id": "user-worker-1"}, headers=_worker(client))
        assert r.status_code == 201
        assert db.get(models.Observation, r.json()["id"]).health_case_id == case["id"]

        # Diagnosis is clinical: the worker is refused, the vet records one with a certainty.
        r = client.post(f"{API}/health/cases/{case['id']}/diagnoses", json={"diagnosis_code": "digital_dermatitis", "certainty_code": "suspected"}, headers=_worker(client))
        assert r.status_code == 403
        r = client.post(f"{API}/health/cases/{case['id']}/diagnoses", json={"diagnosis_code": "digital_dermatitis", "certainty_code": "guess"}, headers=_vet(client))
        assert r.status_code == 422
        r = client.post(f"{API}/health/cases/{case['id']}/diagnoses", json={"diagnosis_code": "digital_dermatitis", "diagnosis_text": "Digital dermatitis, left hind", "certainty_code": "suspected"}, headers=_vet(client))
        assert r.status_code == 201, r.text
        first = r.json()
        assert first["status"] == "active" and first["diagnosed_by_name"] == "Dr. Layla Haddad"
        r = client.post(f"{API}/health/cases/{case['id']}/diagnoses", json={"diagnosis_code": "sole_ulcer", "certainty_code": "confirmed", "supersedes_diagnosis_id": first["id"]}, headers=_vet(client))
        assert r.status_code == 201, r.text
        detail = client.get(f"{API}/health/cases/{case['id']}", headers=_h(client)).json()
        assert detail["active_diagnoses"] == ["sole_ulcer"] and {d["status"] for d in detail["diagnoses"]} == {"superseded", "active"}, "a revision supersedes, never overwrites"

        # The plan and the treatment under it, naming the stocked medicine.
        r = client.post(f"{API}/health/cases/{case['id']}/plans", json={"instructions": "Trim, block, anti-inflammatory for 3 days"}, headers=_vet(client))
        assert r.status_code == 201, r.text
        plan = r.json()
        r = client.post(f"{API}/health/treatments", json={"entity_type": "animal", "entity_id": LUNA, "medication": "Flunixin", "dose": "2.2 mg/kg", "route": "IM",
                                                         "responsible_user_id": "user-vet-1", "medicine_product_id": FLUNIXIN, "treatment_plan_id": plan["id"]}, headers=_vet(client))
        assert r.status_code == 201, r.text
        treatment = r.json()
        assert treatment["health_case_id"] == case["id"] and treatment["medicine_product_id"] == FLUNIXIN and treatment["treatment_plan_id"] == plan["id"]
        # An administration under that treatment must be of the prescribed product.
        r = client.post(f"{API}/pharmacy/administrations", json={"subject_type": "animal", "subject_id": LUNA, "inventory_item_id": OXYTET, "dose_quantity": 10, "dose_unit": "ml",
                                                                "route_code": "IM", "treatment_id": treatment["id"]}, headers=_h(client))
        assert r.status_code == 422 and "prescribes" in r.json()["detail"]
        r = client.post(f"{API}/pharmacy/administrations", json={"subject_type": "animal", "subject_id": LUNA, "inventory_item_id": FLUNIXIN, "dose_quantity": 10, "dose_unit": "ml",
                                                                "route_code": "IM", "treatment_id": treatment["id"]}, headers=_h(client))
        assert r.status_code == 201 and r.json()["health_case_id"] == case["id"], r.text
        detail = client.get(f"{API}/health/cases/{case['id']}", headers=_h(client)).json()
        assert detail["plans"][0]["status"] == "active" and detail["plans"][0]["treatments"][0]["id"] == treatment["id"] and len(detail["treatments"]) == 1

        # Closing needs an outcome; it resolves the diagnoses and completes the plan.
        r = client.post(f"{API}/health/cases/{case['id']}/close", json={"outcome": " "}, headers=_h(client))
        assert r.status_code == 422
        r = client.post(f"{API}/health/cases/{case['id']}/close", json={"outcome": "Sound after 5 days"}, headers=_h(client))
        assert r.status_code == 200 and r.json()["status"] == "resolved" and r.json()["closed_at"]
        closed = client.get(f"{API}/health/cases/{case['id']}", headers=_h(client)).json()
        assert closed["active_diagnoses"] == [] and closed["plans"][0]["status"] == "completed"
        assert client.post(f"{API}/health/cases/{case['id']}/diagnoses", json={"diagnosis_code": "x"}, headers=_vet(client)).status_code == 422
        assert [c["id"] for c in client.get(f"{API}/health/cases", params={"status": "all", "subject_id": LUNA}, headers=_h(client)).json()] == [case["id"]]
        events = {e.event_type for e in db.scalars(select(models.Event).where(models.Event.entity_id.in_((LUNA, case["id"]))))}
        assert {"health_case_opened", "diagnosis_recorded", "treatment_prescribed", "treatment_recorded", "health_case_closed"} <= events

    def test_the_emergency_engine_opens_and_closes_its_own_case(self, client: TestClient):
        rows = {a["subject_id"]: a for a in client.get(f"{API}/emergency/assessments", params={"status": "active"}, headers=_h(client)).json()}
        rasha, bella = rows[RASHA], rows[BELLA]
        assert rasha["health_case_id"], "an escalation opens the case"
        case = client.get(f"{API}/health/cases/{rasha['health_case_id']}", headers=_h(client)).json()
        assert case["source_type"] == "emergency_assessment" and case["severity_code"] == "moderate" and case["active_diagnoses"] == [], "the engine never writes a diagnosis"
        assert bella["health_case_id"] is None, "a match awaiting confirmation has no case yet"
        r = client.post(f"{API}/emergency/assessments/{bella['id']}/start", json={"confirmed": True}, headers=_h(client))
        assert r.status_code == 201, r.text
        run = r.json()
        assert run["health_case_id"]
        bcase = client.get(f"{API}/health/cases/{run['health_case_id']}", headers=_h(client)).json()
        assert bcase["source_type"] == "emergency_run" and bcase["primary_problem_code"] == "FEVER" and bcase["severity_code"] == "high"
        # Closing the escalated case through the emergency closes the health case with the outcome.
        r = client.post(f"{API}/emergency/assessments/{rasha['id']}/close", json={"outcome": "Vet visited, treated for pneumonia"}, headers=_h(client))
        assert r.status_code == 200
        case = client.get(f"{API}/health/cases/{rasha['health_case_id']}", headers=_h(client)).json()
        assert case["status"] == "resolved" and "pneumonia" in case["outcome"]
        # A case a person opened is theirs: a second escalation joins it and closing the emergency leaves it open.
        r = client.post(f"{API}/health/cases", json={"subject_type": "animal", "subject_id": CLOVER, "severity_code": "low", "notes": "Watching appetite"}, headers=_h(client))
        manual = r.json()
        a = client.post(f"{API}/emergency/assessments", json={"subject_type": "animal", "subject_id": CLOVER, "signs": [{"code": "temperature_c", "value_numeric": 41.9}]}, headers=_h(client)).json()
        assert a["status"] == "escalated" and a["health_case_id"] == manual["id"]
        assert client.get(f"{API}/health/cases/{manual['id']}", headers=_h(client)).json()["severity_code"] == "critical", "the engine raises the severity it found"
        client.post(f"{API}/emergency/assessments/{a['id']}/close", json={"outcome": "False alarm"}, headers=_h(client))
        assert client.get(f"{API}/health/cases/{manual['id']}", headers=_h(client)).json()["status"] == "open"


class TestConditionsAndWeights:
    def test_a_recorded_adverse_reaction_blocks_the_medication_step(self, client: TestClient):
        r = client.get(f"{API}/animals/{LUNA}/conditions", headers=_h(client))
        assert r.status_code == 200 and [c["code"] for c in r.json()] == ["penicillin_g"]
        assert client.post(f"{API}/animals/{LUNA}/conditions", json={"condition_type": "allergy", "code": "flunixin_meglumine", "label": "Flunixin reaction"}, headers=_worker(client)).status_code == 403
        r = client.post(f"{API}/animals/{LUNA}/conditions", json={"condition_type": "allergy", "code": "flunixin_meglumine", "label": "Flunixin reaction 2026", "severity": "high"}, headers=_vet(client))
        assert r.status_code == 201, r.text
        cond = r.json()
        # The protocol matches on the signs, but the step is blocked by the authoritative fact.
        a = client.post(f"{API}/emergency/assessments", json={"subject_type": "animal", "subject_id": LUNA, "signs": [
            {"code": "temperature_c", "value_numeric": 40.4}, {"code": "appetite", "value_text": "reduced"}, {"code": "fever"}]}, headers=_h(client)).json()
        assert a["status"] == "open" and a["animal_facts"]["allergies"] == ["flunixin_meglumine", "penicillin_g"]
        run = client.post(f"{API}/emergency/assessments/{a['id']}/start", json={"confirmed": True}, headers=_h(client)).json()
        step3 = next(s for s in run["steps"] if s["step"]["step_no"] == 3)
        r = client.post(f"{API}/emergency/runs/{run['id']}/steps/{step3['id']}/prepare", json={"weight_kg": 600}, headers=_h(client))
        assert r.status_code == 200, r.text
        run = r.json()
        assert run["status"] == "escalated" and any("recorded allergy" in p and "flunixin_meglumine" in p for p in next(s for s in run["steps"] if s["step"]["step_no"] == 3)["result"]["problems"])
        # Ended by the vet, it no longer counts.
        r = client.delete(f"{API}/animals/{LUNA}/conditions/{cond['id']}", headers=_vet(client))
        assert r.status_code == 200 and r.json()["active"] is False
        assert [c["code"] for c in client.get(f"{API}/animals/{LUNA}/conditions", headers=_h(client)).json()] == ["penicillin_g"]

    def test_an_allergy_eligibility_rule_requires_the_vet(self, client: TestClient):
        _publish_clinical_rules_v2(client)
        # Luna's recorded penicillin reaction fails the rule → the vet is required, no drug is shown.
        a = client.post(f"{API}/emergency/assessments", json={"subject_type": "animal", "subject_id": LUNA, "signs": [
            {"code": "temperature_c", "value_numeric": 40.4}, {"code": "appetite", "value_text": "reduced"}, {"code": "fever"}]}, headers=_h(client)).json()
        assert a["status"] == "escalated" and any("requires the veterinarian" in x and "penicillin" in x for x in a["escalation_reasons"])
        match = a["matches"][0]
        allergy = next(o for o in match["explanation"]["eligibility"] if o["rule_type"] == "allergy")
        assert allergy["passed"] is False and allergy["fact"] == ["penicillin_g"]
        # Clover has no such record: eligible, with a weight-age warning.
        a = client.post(f"{API}/emergency/assessments", json={"subject_type": "animal", "subject_id": CLOVER, "signs": [
            {"code": "temperature_c", "value_numeric": 40.4}, {"code": "appetite", "value_text": "reduced"}, {"code": "fever"}]}, headers=_h(client)).json()
        assert a["status"] == "open"
        warn = next(o for o in a["matches"][0]["explanation"]["eligibility"] if o["rule_type"] == "weight_age_days")
        assert warn["passed"] is False and warn["failure_action"] == "WARN" and warn["fact"] is None, "no dated weight on record"

    def test_weights_are_dated_records_and_the_dose_requires_a_fresh_one(self, client: TestClient, db_session):
        db, _ = db_session
        r = client.get(f"{API}/animals/horse-h07/weights", headers=_h(client))
        assert r.status_code == 200 and len(r.json()) == 1 and r.json()[0]["weight_kg"] == 480 and r.json()[0]["method"] == "scale"
        r = client.post(f"{API}/animals/{CLOVER}/weights", json={"weight_kg": -3}, headers=_h(client))
        assert r.status_code == 422
        old = (datetime.now(timezone.utc) - timedelta(days=45)).isoformat()
        r = client.post(f"{API}/animals/{CLOVER}/weights", json={"weight_kg": 560, "measured_at": old, "method": "tape"}, headers=_h(client))
        assert r.status_code == 201, r.text
        assert db.get(models.Animal, CLOVER).weight_kg == 560
        # Editing the animal's weight is a new dated record, not an overwrite.
        r = client.put(f"{API}/animals/{CLOVER}", json={"weight_kg": 575}, headers=_h(client))
        assert r.status_code == 200 and r.json()["weight_kg"] == 575
        history = client.get(f"{API}/animals/{CLOVER}/weights", headers=_h(client)).json()
        assert [w["weight_kg"] for w in history] == [575, 560] and history[0]["source_type"] == "animal_update"
        # A protocol that requires a weight no older than 30 days: the 45-day record alone would block; a weight entered now is recorded and used.
        _publish_clinical_rules_v2(client)  # v2 with weight_max_age_days = 30
        for w in db.scalars(select(hm.AnimalWeightRecord).where(hm.AnimalWeightRecord.animal_id == CLOVER)):
            w.measured_at = datetime.now(timezone.utc) - timedelta(days=45)
        db.commit()
        a = client.post(f"{API}/emergency/assessments", json={"subject_type": "animal", "subject_id": CLOVER, "signs": [
            {"code": "temperature_c", "value_numeric": 40.4}, {"code": "appetite", "value_text": "reduced"}, {"code": "fever"}]}, headers=_h(client)).json()
        assert a["status"] == "open", a
        warn = next(o for o in a["matches"][0]["explanation"]["eligibility"] if o["rule_type"] == "weight_age_days")
        assert warn["passed"] is False and warn["failure_action"] == "WARN" and warn["fact"] == 45, "the 45-day-old weight is the fact the rule saw"
        run = client.post(f"{API}/emergency/assessments/{a['id']}/start", json={"confirmed": True}, headers=_h(client)).json()
        step3 = next(s for s in run["steps"] if s["step"]["step_no"] == 3)
        r = client.post(f"{API}/emergency/runs/{run['id']}/steps/{step3['id']}/prepare", json={}, headers=_h(client))
        assert r.status_code == 200, r.text
        run = r.json()
        problems = next(s for s in run["steps"] if s["step"]["step_no"] == 3)["result"]["problems"]
        assert run["status"] == "escalated" and any("no older than 30 day" in p and "45 day" in p for p in problems)
        # A fresh run with the weight entered at the animal: the dose is calculated and the weight is on record.
        a = client.post(f"{API}/emergency/assessments", json={"subject_type": "animal", "subject_id": CLOVER, "signs": [
            {"code": "temperature_c", "value_numeric": 40.4}, {"code": "appetite", "value_text": "reduced"}, {"code": "fever"}]}, headers=_h(client)).json()
        run = client.post(f"{API}/emergency/assessments/{a['id']}/start", json={"confirmed": True}, headers=_h(client)).json()
        step3 = next(s for s in run["steps"] if s["step"]["step_no"] == 3)
        r = client.post(f"{API}/emergency/runs/{run['id']}/steps/{step3['id']}/prepare", json={"weight_kg": 580}, headers=_h(client))
        p = next(s for s in r.json()["steps"] if s["step"]["step_no"] == 3)["result"]
        assert p["problems"] == [] and p["weight_source"] == "entered now" and p["weight_age_days"] == 0 and p["dose_quantity"] == 25.52
        latest = client.get(f"{API}/animals/{CLOVER}/weights", headers=_h(client)).json()[0]
        assert latest["weight_kg"] == 580 and latest["method"] == "point_of_care" and latest["source_type"] == "emergency_run_step"
