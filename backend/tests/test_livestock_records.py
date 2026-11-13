"""Livestock history, groups and reproduction (database/LIVESTOCK-SCHEMA.md,
REPRODUCTION-SCHEMA.md, PRODUCTION-SCHEMA.md §8, behavioural model §2–§3, §14).

Seed facts these tests lean on (app/seed.py, app/livestock/seed.py):
Bella (cow-744) pregnant 120 days from an insemination, in her 2nd
lactation, in the Dairy Herd with Luna and Clover; Luna calved 90 days ago
and her heifer calf is not yet registered; Daisy (sheep) was served 35 days
ago with no check; the Layer Flock is hybrid (2450 head, two registered
hens); a layer-hen batch is in the incubator.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from app.core import permissions as perms
from app.core.security import hash_password
from app.domain import feed_models as fm
from app.domain import livestock_models as lm
from app.domain import models
from app.domain import reproduction_models as rm
from app.repositories.base import new_id
from app.services import feeding_program_service
from tests.conftest import auth_headers

API = "/api/v1"
FARM = "farm-origami"
BELLA, LUNA, CLOVER, DAISY, THUNDER = "cow-744", "cow-214", "cow-clover", "sheep-s045", "horse-h07"
HEN, HERD, GOATS, SHEEP, LAYERS = "hen-247", "grp-dairy-herd", "grp-goat-b", "grp-sheep-a", "flock-layer"


def _h(client, email="rami@origami.farm"):
    return auth_headers(client, email)


def _twin(client, animal_id, h=None):
    r = client.get(f"{API}/animals/{animal_id}", headers=h or _h(client))
    assert r.status_code == 200, r.text
    return r.json()


def _members(client, group_id, **params):
    r = client.get(f"{API}/animal-groups/{group_id}/members", params=params, headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()


def _group(client, group_id):
    return client.get(f"{API}/animal-groups/{group_id}", headers=_h(client)).json()


def _new_cow(client, name, tag, **extra):
    r = client.post(f"{API}/animals", headers=_h(client), json={
        "name": name, "species": "cow", "sex": "F", "life_stage": "adult", "management_profile": "dairy",
        "identifiers": [{"identifier_type": "EAR_TAG", "identifier_value": tag, "is_primary": True}], **extra,
    })
    assert r.status_code == 201, r.text
    return r.json()


# ------------------------------------------------------------------ state history
class TestStateHistory:
    def test_registration_opens_the_history(self, client):
        cow = _new_cow(client, "Rima", "T-501", location_label="Calf Barn")
        rows = client.get(f"{API}/animals/{cow['id']}/history", headers=_h(client)).json()
        assert {(r["state_type"], r["value"]) for r in rows} == {
            ("STATUS", "active"), ("LIFE_STAGE", "adult"), ("MANAGEMENT_PROFILE", "dairy"), ("LOCATION", "Calf Barn")}
        assert all(r["effective_to"] is None for r in rows)

    def test_a_move_closes_the_old_location_and_opens_the_new(self, client):
        h = _h(client)
        before = client.get(f"{API}/animals/{BELLA}/history", params={"state_type": "location"}, headers=h).json()
        assert len(before) == 1 and before[0]["effective_to"] is None
        r = client.patch(f"{API}/animals/{BELLA}", json={"location_label": "Isolation Pen"}, headers=h)
        assert r.status_code == 200 and r.json()["location_label"] == "Isolation Pen"
        after = client.get(f"{API}/animals/{BELLA}/history", params={"state_type": "LOCATION"}, headers=h).json()
        assert [r["value"] for r in after] == ["Isolation Pen", before[0]["value"]]
        assert after[0]["effective_to"] is None and after[1]["effective_to"] is not None

    def test_an_edit_writes_stage_and_profile_history(self, client):
        h = _h(client)
        r = client.put(f"{API}/animals/{THUNDER}", json={"life_stage": "senior", "management_profile": "work"}, headers=h)
        assert r.status_code == 200, r.text
        types = [(x["state_type"], x["value"]) for x in client.get(f"{API}/animals/{THUNDER}/history", headers=h).json() if x["effective_to"] is None]
        assert ("LIFE_STAGE", "senior") in types and ("MANAGEMENT_PROFILE", "work") in types
        assert client.get(f"{API}/animals/{THUNDER}/history", params={"state_type": "colour"}, headers=h).status_code == 422


# ------------------------------------------------------------------ pregnancy / lactation are records
class TestNoEditableFlags:
    def test_an_edit_cannot_set_pregnancy_or_lactation(self, client):
        h = _h(client)
        r = client.put(f"{API}/animals/{CLOVER}", json={"pregnant": True}, headers=h)
        assert r.status_code == 422 and "pregnancy check" in r.json()["detail"]
        r = client.put(f"{API}/animals/{CLOVER}", json={"lactating": False}, headers=h)
        assert r.status_code == 422 and "dry-off" in r.json()["detail"]

    def test_resending_the_current_state_is_harmless(self, client):
        h = _h(client)
        bella = _twin(client, BELLA)
        r = client.put(f"{API}/animals/{BELLA}", json={"name": "Bella", "pregnant": True, "lactating": True, "pregnancy_days": 3}, headers=h)
        assert r.status_code == 200, r.text
        assert r.json()["pregnancy_days"] == bella["pregnancy_days"], "pregnancy_days is derived, never written"

    def test_registration_turns_opening_state_into_episodes(self, client, db_session):
        cow = _new_cow(client, "Hala", "T-502", pregnant=True, pregnancy_days=60, lactating=True, lactation_cycle=2)
        assert cow["pregnant"] and cow["pregnancy_days"] == 60 and cow["lactating"] and cow["lactation_cycle"] == 2
        assert cow["expected_due_date"] is not None
        session, _ = db_session
        episodes = session.scalars(select(rm.PregnancyEpisode).where(rm.PregnancyEpisode.animal_id == cow["id"])).all()
        assert [(e.status, e.source) for e in episodes] == [("active", "registration")]
        lactation = session.scalars(select(rm.LactationEpisode).where(rm.LactationEpisode.animal_id == cow["id"])).one()
        assert lactation.lactation_number == 2 and lactation.status == "active"

    def test_profile_change_waits_for_the_dry_off(self, client):
        h = _h(client)
        r = client.put(f"{API}/animals/{CLOVER}", json={"management_profile": "meat"}, headers=h)
        assert r.status_code == 422
        assert client.post(f"{API}/animals/{CLOVER}/dry-off", json={}, headers=h).status_code == 200
        r = client.put(f"{API}/animals/{CLOVER}", json={"management_profile": "meat"}, headers=h)
        assert r.status_code == 200 and r.json()["lactating"] is False


# ------------------------------------------------------------------ groups
class TestGroups:
    def test_a_herd_counts_its_members_and_names_the_animal_s_group(self, client):
        assert _group(client, HERD)["count"] == 3 and _group(client, HERD)["tracking_mode"] == "MEMBERSHIP_DERIVED"
        assert {m["animal_id"] for m in _members(client, HERD)} == {BELLA, LUNA, CLOVER}
        cow = _new_cow(client, "Nour", "T-503", group_name="dairy herd")
        assert cow["group_name"] == "Dairy Herd" and _group(client, HERD)["count"] == 4

    def test_joining_another_exclusive_group_is_a_move(self, client):
        h = _h(client)
        pen = client.post(f"{API}/animal-groups", json={"name": "Dry Cow Pen", "species": "cow", "group_type": "pen"}, headers=h)
        assert pen.status_code == 201 and pen.json()["tracking_mode"] == "MEMBERSHIP_DERIVED", pen.text
        r = client.post(f"{API}/animal-groups/{pen.json()['id']}/members", json={"animal_id": LUNA, "reason": "drying off"}, headers=h)
        assert r.status_code == 201, r.text
        assert _twin(client, LUNA)["group_name"] == "Dry Cow Pen"
        assert _group(client, HERD)["count"] == 2 and _group(client, pen.json()["id"])["count"] == 1
        past = [m for m in _members(client, HERD, include_past=True) if m["animal_id"] == LUNA]
        assert len(past) == 1 and past[0]["current"] is False and past[0]["end_reason"].startswith("moved_to:")
        assert client.post(f"{API}/animal-groups/{pen.json()['id']}/members", json={"animal_id": LUNA}, headers=h).status_code == 409

    def test_the_feeding_resolver_follows_the_membership(self, client, db_session):
        h = _h(client)
        pen = client.post(f"{API}/animal-groups", json={"name": "Heifer Pen", "species": "cow", "group_type": "pen"}, headers=h).json()
        client.post(f"{API}/animal-groups/{pen['id']}/members", json={"animal_id": CLOVER}, headers=h)
        session, factory = db_session
        with factory() as fresh:
            clover = fresh.get(models.Animal, CLOVER)
            assert feeding_program_service.group_for_animal(fresh, clover).id == pen["id"]
            assert CLOVER not in {a.id for a in feeding_program_service.animals_in_group(fresh, fresh.get(models.Flock, HERD))}

    def test_a_cohort_overlaps_without_moving_anyone(self, client):
        h = _h(client)
        cohort = client.post(f"{API}/animal-groups", json={"name": "Spring scan list", "species": "cow", "group_type": "cohort"}, headers=h).json()
        assert client.post(f"{API}/animal-groups/{cohort['id']}/members", json={"animal_id": BELLA}, headers=h).status_code == 201
        assert _twin(client, BELLA)["group_name"] == "Dairy Herd"
        assert {g["group_name"] for g in _twin(client, BELLA)["groups"]} == {"Dairy Herd", "Spring scan list"}

    def test_a_group_holds_one_species_and_one_farm(self, client):
        h = _h(client)
        r = client.post(f"{API}/animal-groups/{GOATS}/members", json={"animal_id": BELLA}, headers=h)
        assert r.status_code == 422 and "one species" in r.json()["detail"]
        assert client.post(f"{API}/animal-groups/{GOATS}/members", json={"animal_id": "no-such-animal"}, headers=h).status_code == 404

    def test_an_edit_moves_the_herd_by_name_and_refuses_a_typo(self, client):
        h = _h(client)
        r = client.put(f"{API}/animals/{CLOVER}", json={"group_name": "Dairy Hrd"}, headers=h)
        assert r.status_code == 422 and "Dairy Herd" in r.json()["detail"]
        r = client.put(f"{API}/animals/{CLOVER}", json={"group_name": ""}, headers=h)
        assert r.status_code == 200 and r.json()["group_name"] is None
        assert _group(client, HERD)["count"] == 2

    def test_a_flock_count_is_a_ledger(self, client):
        h = _h(client)
        ledger = client.get(f"{API}/animal-groups/{LAYERS}/quantity-events", headers=h).json()
        assert ledger[0]["resulting_quantity"] == 2450 and sum(e["quantity_delta"] for e in ledger) == 2450
        r = client.post(f"{API}/animal-groups/{LAYERS}/quantity-events", json={"event_type": "death", "quantity_delta": -5, "reason": "Predator"}, headers=h)
        assert r.status_code == 201 and r.json()["resulting_quantity"] == 2445
        assert _group(client, LAYERS)["count"] == 2445
        assert client.post(f"{API}/animal-groups/{LAYERS}/quantity-events", json={"event_type": "DEATH", "quantity_delta": 5}, headers=h).status_code == 422
        assert client.post(f"{API}/animal-groups/{LAYERS}/quantity-events", json={"event_type": "SALE", "quantity_delta": -99999}, headers=h).status_code == 422
        # A recount typed as a number becomes an adjustment row, not an overwrite.
        assert client.patch(f"{API}/animal-groups/{LAYERS}", json={"count": 2440}, headers=h).status_code == 200
        latest = client.get(f"{API}/animal-groups/{LAYERS}/quantity-events", headers=h).json()[0]
        assert (latest["event_type"], latest["quantity_delta"], latest["resulting_quantity"]) == ("COUNT_ADJUSTMENT", -5, 2440)

    def test_a_herd_that_counts_members_takes_no_head_count_events(self, client):
        r = client.post(f"{API}/animal-groups/{HERD}/quantity-events", json={"event_type": "ADDITION", "quantity_delta": 1}, headers=_h(client))
        assert r.status_code == 422


# ------------------------------------------------------------------ reproduction
class TestBreedingAndPregnancy:
    def test_daisy_is_waiting_for_her_check(self, client):
        overview = client.get(f"{API}/reproduction/overview", headers=_h(client)).json()
        assert DAISY in {a["animal_id"] for a in overview["awaiting_pregnancy_check"]}
        bella = next(p for p in overview["pregnant"] if p["animal_id"] == BELLA)
        assert bella["days_pregnant"] == 120 and 150 < bella["days_to_due"] < 170
        assert overview["in_milk_count"] == 5 and len(overview["incubations"]) == 1

    def test_a_positive_check_dates_the_pregnancy_from_the_service(self, client):
        r = client.post(f"{API}/animals/{DAISY}/pregnancy-checks", json={"assessment_type": "ultrasound", "result_code": "positive"}, headers=_h(client))
        assert r.status_code == 201, r.text
        body = r.json()
        assert body["pregnancy"]["originating_breeding_event_id"] is not None
        conceived = datetime.fromisoformat(body["pregnancy"]["estimated_conception_at"])
        due = datetime.fromisoformat(body["pregnancy"]["expected_due_date"])
        assert (due - conceived).days == 147, "a ewe's configured gestation"
        assert body["summary"]["pregnant"] and not body["summary"]["awaiting_pregnancy_check"]
        twin = _twin(client, DAISY)
        assert twin["pregnant"] and twin["pregnancy_days"] == 35

    def test_a_negative_check_ends_an_open_pregnancy(self, client):
        h = _h(client)
        r = client.post(f"{API}/animals/{BELLA}/pregnancy-checks", json={"result_code": "NEGATIVE", "assessment_type": "PALPATION"}, headers=h)
        assert r.status_code == 201 and r.json()["pregnancy"] is None
        assert _twin(client, BELLA)["pregnant"] is False
        timeline = client.get(f"{API}/animals/{BELLA}/reproduction", headers=h).json()
        assert timeline["pregnancies"][0]["outcome_code"] == "NOT_PREGNANT"

    def test_a_pregnant_animal_is_not_bred_again(self, client):
        r = client.post(f"{API}/animals/{BELLA}/breedings", json={"event_type": "ARTIFICIAL_INSEMINATION"}, headers=_h(client))
        assert r.status_code == 409

    def test_the_sire_must_be_a_male_of_the_species(self, client):
        h = _h(client)
        r = client.post(f"{API}/animals/{DAISY}/breedings", json={"event_type": "NATURAL_MATING", "male_animal_id": THUNDER}, headers=h)
        assert r.status_code == 422 and "horse" in r.json()["detail"]
        r = client.post(f"{API}/animals/{THUNDER}/breedings", json={"event_type": "HEAT_OBSERVED"}, headers=h)
        assert r.status_code == 422 and "female" in r.json()["detail"]

    def test_a_hen_is_never_pregnancy_checked(self, client):
        r = client.post(f"{API}/animals/{HEN}/pregnancy-checks", json={"result_code": "POSITIVE"}, headers=_h(client))
        assert r.status_code == 422 and "pregnancy" in r.json()["detail"].lower()

    def test_a_loss_ends_the_pregnancy(self, client):
        h = _h(client)
        r = client.post(f"{API}/animals/{BELLA}/pregnancy-loss", json={"outcome_code": "abortion", "notes": "Found at 4 months"}, headers=h)
        assert r.status_code == 200 and r.json()["pregnancy"]["outcome_code"] == "ABORTION"
        assert client.post(f"{API}/animals/{BELLA}/pregnancy-loss", json={}, headers=h).status_code == 404

    def test_a_mistaken_breeding_is_voided_not_deleted(self, client):
        h = _h(client)
        timeline = client.get(f"{API}/animals/{DAISY}/reproduction", headers=h).json()
        breeding_id = timeline["breedings"][0]["id"]
        assert client.post(f"{API}/animals/{DAISY}/breedings/{breeding_id}/void", json={"reason": "Wrong ewe"}, headers=h).status_code == 200
        timeline = client.get(f"{API}/animals/{DAISY}/reproduction", headers=h).json()
        assert timeline["breedings"][0]["status"] == "voided" and not timeline["summary"]["awaiting_pregnancy_check"]
        # A breeding a pregnancy rests on cannot be voided.
        bella_breeding = client.get(f"{API}/animals/{BELLA}/reproduction", headers=h).json()["breedings"][0]["id"]
        assert client.post(f"{API}/animals/{BELLA}/breedings/{bella_breeding}/void", json={"reason": "x"}, headers=h).status_code == 409


class TestBirth:
    CALF = {"outcome_code": "LIVE", "sex": "F", "birth_weight_kg": 40, "register_now": True, "name": "Bella's calf",
            "identifiers": [{"identifier_type": "EAR_TAG", "identifier_value": "C-1001", "is_primary": True}]}

    def test_a_calving_closes_the_pregnancy_registers_the_calf_and_starts_milking(self, client, db_session):
        h = _h(client)
        r = client.post(f"{API}/animals/{BELLA}/births", json={"assistance_code": "easy", "offspring": [self.CALF]}, headers=h)
        assert r.status_code == 201, r.text
        body = r.json()
        calf_id = body["registered_offspring_ids"][0]
        assert body["birth"]["live_count"] == 1 and body["birth"]["sire_name"] is None and body["birth"]["sire_reference"].startswith("Holstein AI")
        assert body["summary"]["pregnant"] is False and body["summary"]["lactation"]["lactation_number"] == 3
        calf = _twin(client, calf_id)
        assert calf["species"] == "cow" and calf["life_stage"] == "newborn" and calf["dam_tag"] == "744"
        assert calf["relationships"]["dam"]["animal_id"] == BELLA and calf["tag"] == "C-1001"
        assert _twin(client, BELLA)["relationships"]["offspring"][0]["animal_id"] == calf_id
        session, _ = db_session
        lactations = session.scalars(select(rm.LactationEpisode).where(rm.LactationEpisode.animal_id == BELLA).order_by(rm.LactationEpisode.started_at)).all()
        assert [(lac.lactation_number, lac.status, lac.end_reason_code) for lac in lactations] == [(2, "ended", "NEW_LACTATION"), (3, "active", None)]

    def test_a_newborn_the_rules_refuse_refuses_the_whole_birth(self, client):
        h = _h(client)
        calf = {**self.CALF, "identifiers": []}
        r = client.post(f"{API}/animals/{BELLA}/births", json={"offspring": [calf]}, headers=h)
        assert r.status_code == 422 and r.json()["detail"].startswith("Newborn 1:")
        assert _twin(client, BELLA)["pregnant"] is True, "nothing half-recorded"

    def test_a_calf_born_untagged_is_registered_later_from_its_birth(self, client):
        h = _h(client)
        birth = client.get(f"{API}/animals/{LUNA}/reproduction", headers=h).json()["births"][0]
        assert birth["offspring"][0]["registrable"] is True
        body = {"name": "Luna's heifer", "identifiers": [{"identifier_type": "EAR_TAG", "identifier_value": "C-0990", "is_primary": True}]}
        r = client.post(f"{API}/births/{birth['id']}/offspring/1/register", json=body, headers=h)
        assert r.status_code == 201, r.text
        heifer = _twin(client, r.json()["offspring_animal_id"])
        assert heifer["sex"] == "F" and heifer["weight_kg"] == 38 and heifer["relationships"]["dam"]["animal_id"] == LUNA
        assert client.post(f"{API}/births/{birth['id']}/offspring/1/register", json=body, headers=h).status_code == 409

    def test_stillborn_is_recorded_not_registered(self, client):
        r = client.post(f"{API}/animals/{BELLA}/births", json={"offspring": [{"outcome_code": "STILLBORN", "register_now": True}]}, headers=_h(client))
        assert r.status_code == 422
        r = client.post(f"{API}/animals/{BELLA}/births", json={"offspring": [{"outcome_code": "STILLBORN", "sex": "M"}]}, headers=_h(client))
        assert r.status_code == 201 and r.json()["birth"]["stillborn_count"] == 1 and r.json()["registered_offspring_ids"] == []

    def test_only_a_live_bearer_gives_birth(self, client):
        h = _h(client)
        assert client.post(f"{API}/animals/{HEN}/births", json={"offspring": [{"outcome_code": "LIVE"}]}, headers=h).status_code == 422
        assert client.post(f"{API}/animals/{THUNDER}/births", json={"offspring": [{"outcome_code": "LIVE"}]}, headers=h).status_code == 422

    def test_lambs_can_be_counted_into_a_flock(self, client):
        h = _h(client)
        flock = client.post(f"{API}/animal-groups", json={"name": "Lamb Pen", "species": "sheep", "group_type": "pen", "count": 10}, headers=h).json()
        assert flock["tracking_mode"] == "QUANTITY_MANAGED"
        twins = [{"outcome_code": "LIVE", "destination_group_id": flock["id"]}, {"outcome_code": "LIVE", "destination_group_id": flock["id"]}]
        r = client.post(f"{API}/animals/{DAISY}/births", json={"offspring": twins}, headers=h)
        assert r.status_code == 201, r.text
        assert r.json()["counted_into_groups"] == 2 and _group(client, flock["id"])["count"] == 12
        assert r.json()["lactation_not_started"] is not None, "a meat-unprofiled ewe has no LACTATION; the birth says so"


class TestLactation:
    def test_dry_off_then_a_new_lactation_counts_up(self, client):
        h = _h(client)
        assert client.post(f"{API}/animals/{CLOVER}/lactations", json={}, headers=h).status_code == 409
        r = client.post(f"{API}/animals/{CLOVER}/dry-off", json={}, headers=h)
        assert r.status_code == 200 and r.json()["summary"]["lactation"] is None
        assert _twin(client, CLOVER)["lactating"] is False and _twin(client, CLOVER)["dried_off_at"] is not None
        r = client.post(f"{API}/animals/{CLOVER}/lactations", json={}, headers=h)
        assert r.status_code == 201 and r.json()["lactation"]["lactation_number"] == 2

    def test_only_a_lactating_kind_of_animal_milks(self, client):
        h = _h(client)
        assert client.post(f"{API}/animals/{THUNDER}/lactations", json={}, headers=h).status_code == 422
        assert client.post(f"{API}/animals/{THUNDER}/dry-off", json={}, headers=h).status_code == 404


# ------------------------------------------------------------------ exit
class TestExit:
    def test_a_sale_closes_what_cannot_continue_and_keeps_the_record(self, client, db_session):
        h = _h(client)
        r = client.post(f"{API}/animals/{BELLA}/exit", json={"exit_type": "SOLD", "reason": "Sold to a neighbour"}, headers=h)
        assert r.status_code == 200 and r.json()["lifecycle_status"] == "sold"
        twin = _twin(client, BELLA)
        assert twin["active"] is False and twin["pregnant"] is False and twin["lactating"] is False and twin["groups"] == []
        assert _group(client, HERD)["count"] == 2
        session, _ = db_session
        session.expire_all()
        assert session.scalars(select(fm.FeedingAssignment).where(fm.FeedingAssignment.subject_id == BELLA, fm.FeedingAssignment.status == "active")).all() == []
        assert session.scalars(select(models.MilkRecord).where(models.MilkRecord.animal_id == BELLA)).first() is not None, "history stays"
        # Afterwards: no milk, no feeding, no second exit, not in the herd list.
        r = client.post(f"{API}/production/milk", json={"animal_id": BELLA, "session": "morning", "liters": 10, "destination": "stored"}, headers=h)
        assert r.status_code == 409 and "no longer on the farm" in r.json()["detail"]
        r = client.post(f"{API}/feeding-events", json={"subject_type": "animal", "subject_id": BELLA, "components": [{"feed_product_id": "x", "quantity": 1}]}, headers=h)
        assert r.status_code in (409, 422)
        assert client.post(f"{API}/animals/{BELLA}/exit", json={"exit_type": "dead"}, headers=h).status_code == 409
        herd = client.get(f"{API}/animals", params={"farm_id": FARM}, headers=h).json()
        assert BELLA not in {a["id"] for a in herd}
        everyone = client.get(f"{API}/animals", params={"farm_id": FARM, "include_exited": True}, headers=h).json()
        assert BELLA in {a["id"] for a in everyone}

    def test_a_hen_s_death_comes_off_her_flock_s_count(self, client):
        r = client.post(f"{API}/animals/{HEN}/exit", json={"exit_type": "dead"}, headers=_h(client, "karim.worker@origami.farm"))
        assert r.status_code == 200, r.text
        assert _group(client, LAYERS)["count"] == 2449
        latest = client.get(f"{API}/animal-groups/{LAYERS}/quantity-events", headers=_h(client)).json()[0]
        assert latest["event_type"] == "DEATH" and latest["source_id"] == HEN

    def test_a_death_is_anyone_s_to_record_a_sale_is_a_manager_s(self, client):
        worker = _h(client, "karim.worker@origami.farm")
        r = client.post(f"{API}/animals/{THUNDER}/exit", json={"exit_type": "sold"}, headers=worker)
        assert r.status_code == 403 and "approve" in r.json()["detail"]
        assert client.post(f"{API}/animals/{THUNDER}/exit", json={"exit_type": "eaten"}, headers=_h(client)).status_code == 422

    def test_only_an_archived_animal_comes_back(self, client):
        h = _h(client)
        assert client.put(f"{API}/animals/{THUNDER}", json={"active": False}, headers=h).status_code == 200
        assert _twin(client, THUNDER)["lifecycle_status"] == "archived"
        r = client.post(f"{API}/animals/{THUNDER}/restore", json={}, headers=h)
        assert r.status_code == 200 and r.json()["active"] is True
        client.post(f"{API}/animals/{THUNDER}/exit", json={"exit_type": "sold"}, headers=h)
        assert client.post(f"{API}/animals/{THUNDER}/restore", json={}, headers=h).status_code == 409


# ------------------------------------------------------------------ incubation
class TestIncubation:
    def test_eggs_hatch_into_a_flock_s_count(self, client):
        h = _h(client)
        batch = client.get(f"{API}/incubations", headers=h).json()[0]
        assert batch["status"] == "incubating" and batch["days_to_hatch"] == 9
        r = client.post(f"{API}/incubations/{batch['id']}/hatch", json={"hatched_live": 120, "unhatched": 25, "culled": 5,
                                                                         "destination_group_id": LAYERS}, headers=h)
        assert r.status_code == 200 and r.json()["hatch"]["hatch_rate_percent"] == 80.0
        assert _group(client, LAYERS)["count"] == 2570
        assert client.post(f"{API}/incubations/{batch['id']}/hatch", json={"hatched_live": 1}, headers=h).status_code == 409

    def test_the_counts_cannot_exceed_the_eggs_set(self, client):
        h = _h(client)
        batch = client.post(f"{API}/incubations", json={"species_code": "duck", "eggs_set": 40}, headers=h)
        assert batch.status_code == 201 and batch.json()["code"].startswith("INC-"), batch.text
        expected = datetime.fromisoformat(batch.json()["expected_hatch_date"]) - datetime.fromisoformat(batch.json()["set_at"])
        assert expected.days == 28
        assert client.post(f"{API}/incubations/{batch.json()['id']}/hatch", json={"hatched_live": 41}, headers=h).status_code == 422
        r = client.post(f"{API}/incubations/{batch.json()['id']}/cancel", json={"reason": "Power cut"}, headers=h)
        assert r.status_code == 200 and r.json()["status"] == "failed"

    def test_incubation_follows_configuration(self, client):
        h = _h(client)
        assert client.post(f"{API}/incubations", json={"species_code": "cow", "eggs_set": 5}, headers=h).status_code == 422
        r = client.post(f"{API}/incubations", json={"species_code": "layer_hen", "eggs_set": 5, "source_group_id": LAYERS}, headers=h)
        assert r.status_code == 422, "a laying flock is not a breeding flock"


# ------------------------------------------------------------------ lookup, twin, permissions
class TestLookupAndTwin:
    def test_any_identifier_finds_the_animal(self, client):
        h = _h(client)
        r = client.post(f"{API}/animals/{LUNA}/identifiers", json={"identifier_type": "RFID", "identifier_value": "982000411223344"}, headers=h)
        assert r.status_code == 201, r.text
        found = client.get(f"{API}/animals/lookup", params={"value": "982000411223344"}, headers=h).json()
        assert [(f["animal_id"], f["matched_type"]) for f in found] == [(LUNA, "RFID")]
        assert [a["id"] for a in client.get(f"{API}/animals", params={"farm_id": FARM, "search": "9820004112"}, headers=h).json()] == [LUNA]
        assert client.get(f"{API}/animals/lookup", params={"value": "bella"}, headers=h).json()[0]["animal_id"] == BELLA

    def test_a_retired_tag_still_resolves_flagged(self, client):
        h = _h(client)
        client.post(f"{API}/animals/{LUNA}/identifiers", json={"identifier_type": "EAR_TAG", "identifier_value": "214-B", "is_primary": True}, headers=h)
        old = next(i for i in _twin(client, LUNA)["identifiers"] if i["identifier_value"] == "214")
        assert client.delete(f"{API}/animals/{LUNA}/identifiers/{old['id']}", headers=h).status_code == 204
        found = client.get(f"{API}/animals/lookup", params={"value": "214"}, headers=h).json()
        assert found[0]["animal_id"] == LUNA and found[0]["retired"] is True

    def test_the_twin_carries_the_livestock_record(self, client):
        twin = _twin(client, LUNA)
        assert twin["reproduction"]["applies"] == {"breeding": True, "pregnancy": True, "live_birth": True, "lactation": True}
        assert twin["reproduction"]["terminology"]["birth_en"] == "Calving" and twin["reproduction"]["last_birth"]["live_count"] == 1
        assert twin["groups"][0]["group_name"] == "Dairy Herd" and twin["recent_history"]
        hen = _twin(client, HEN)
        assert hen["reproduction"]["applies"]["pregnancy"] is False and hen["reproduction"]["applies"]["live_birth"] is False

    def test_who_may_read_and_record(self, client):
        acct = _h(client, "nadine.acct@origami.farm")
        assert client.get(f"{API}/animals/{BELLA}", headers=acct).status_code == 403
        assert client.post(f"{API}/animals/{DAISY}/breedings", json={"event_type": "HEAT_OBSERVED"}, headers=acct).status_code == 403
        vet = _h(client, "layla.vet@origami.farm")
        assert client.post(f"{API}/animals/{DAISY}/pregnancy-checks", json={"result_code": "INCONCLUSIVE"}, headers=vet).status_code == 201


@pytest.fixture()
def other_farm_manager(db_session):
    session, _ = db_session
    session.add(models.Farm(id="farm-other", name="Other", country="X", region="Y", timezone="UTC", default_currency="USD"))
    session.flush()
    session.add(models.User(id="user-o", farm_id="farm-other", name="O", email="o@other.farm", password_hash=hash_password("farmos123"),
                            role="manager", language="en"))
    session.commit()
    return "o@other.farm"


def test_another_farm_cannot_touch_this_herd(client, other_farm_manager):
    h = _h(client, other_farm_manager)
    assert client.post(f"{API}/animals/{DAISY}/breedings", json={"event_type": "HEAT_OBSERVED"}, headers=h).status_code == 404
    assert client.post(f"{API}/animals/{BELLA}/exit", json={"exit_type": "dead"}, headers=h).status_code == 404
    assert client.get(f"{API}/animals/{BELLA}/reproduction", headers=h).status_code == 404
    assert client.post(f"{API}/animal-groups/{HERD}/members", json={"animal_id": BELLA}, headers=h).status_code == 404
    assert client.get(f"{API}/animals/lookup", params={"value": "744"}, headers=h).json() == []
