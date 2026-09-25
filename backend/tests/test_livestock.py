"""The generic animal model (docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md).

The §3 configuration table is the resolver's test matrix; §12's rules are
each exercised on the accept and the reject side; and the acceptance
criterion in §14 — a new species is configuration, not code — is checked
by adding one at runtime and registering an animal of it.
"""
from __future__ import annotations

import pytest
from sqlalchemy import select

from app.domain import livestock_models as lm
from app.domain import models
from app.livestock.catalog import Cap
from app.services import capability_service as caps

from .conftest import auth_headers

BASE = "/api/v1"
BELLA = "cow-744"      # F, lactating, pregnant -> dairy
THUNDER = "horse-h07"  # M stallion
HEN = "hen-247"        # F layer hen
LAYER_FLOCK = "flock-layer"


# =========================================================== the resolver
class TestResolver:
    """Tech spec §3, row by row."""

    def test_dairy_cow(self, db_session):
        session, _ = db_session
        cs = caps.resolve(session, "cow", "F", "adult", "dairy")
        for code in (Cap.EAR_TAG, Cap.BREEDING, Cap.PREGNANCY, Cap.LIVE_BIRTH, Cap.MILK_PRODUCTION, Cap.LACTATION, Cap.HEALTH):
            assert cs.has(code), code
        assert not cs.has(Cap.EGG_PRODUCTION)
        assert Cap.EAR_TAG in cs.required_codes()
        assert cs.required_identifier_types() == {"EAR_TAG"}
        assert cs.subject_kind == "individual"

    def test_bull_never_pregnant_or_milked(self, db_session):
        session, _ = db_session
        cs = caps.resolve(session, "cow", "M", "adult", "breeding")
        assert cs.has(Cap.BREEDING)
        assert not cs.has(Cap.PREGNANCY) and not cs.has(Cap.MILK_PRODUCTION)
        # Removed by biology, not by a rule — and the set says so.
        assert Cap.PREGNANCY in cs.suppressed

    def test_meat_ewe_reproduces_but_is_not_milked(self, db_session):
        session, _ = db_session
        cs = caps.resolve(session, "sheep", "F", "adult", "meat")
        assert cs.has(Cap.PREGNANCY) and cs.has(Cap.LIVE_BIRTH) and cs.has(Cap.GROWTH_TRACKING)
        assert not cs.has(Cap.MILK_PRODUCTION)
        # Configuration, not biology: a dairy ewe is milked.
        assert Cap.MILK_PRODUCTION not in cs.suppressed
        assert caps.resolve(session, "sheep", "F", "adult", "dairy").has(Cap.MILK_PRODUCTION)

    def test_mare(self, db_session):
        session, _ = db_session
        cs = caps.resolve(session, "horse", "F", "adult", "breeding")
        assert cs.has(Cap.PREGNANCY) and cs.has(Cap.LIVE_BIRTH) and cs.has(Cap.HOOF_CARE)
        assert not cs.has(Cap.MILK_PRODUCTION)
        assert cs.required_identifier_types() == {"MICROCHIP"}
        assert "EAR_TAG" not in cs.allowed_identifier_types()
        assert "PASSPORT" in cs.allowed_identifier_types()

    def test_layer_hen(self, db_session):
        session, _ = db_session
        cs = caps.resolve(session, "layer_hen", "F", "adult", "layer")
        assert cs.has(Cap.EGG_PRODUCTION) and cs.has(Cap.BREEDING)
        assert not cs.has(Cap.PREGNANCY) and not cs.has(Cap.LIVE_BIRTH)
        assert Cap.PREGNANCY in cs.suppressed
        assert "LEG_BAND" in cs.allowed_identifier_types()
        assert cs.reproduction_mode == "oviparous"

    def test_broiler_flock_grows_and_does_not_lay(self, db_session):
        session, _ = db_session
        cs = caps.resolve(session, "layer_hen", "F", "adult", "broiler")
        assert cs.has(Cap.GROWTH_TRACKING) and cs.has(Cap.FEED) and cs.has(Cap.MORTALITY)
        assert not cs.has(Cap.EGG_PRODUCTION) and not cs.has(Cap.BREEDING)

    def test_terminology_per_species(self, db_session):
        session, _ = db_session
        births = {sp: caps.resolve(session, sp, "F").terminology["birth_en"] for sp in ("cow", "sheep", "goat", "horse")}
        assert births == {"cow": "Calving", "sheep": "Lambing", "goat": "Kidding", "horse": "Foaling"}

    def test_unknown_species_is_an_error_not_a_default(self, db_session):
        session, _ = db_session
        with pytest.raises(caps.UnknownSpecies):
            caps.resolve(session, "dragon", "F")

    def test_most_specific_rule_wins(self, db_session):
        """A farm's own rule for cow/F/adult/dairy overrides the generic
        one for the species — the algorithm, not just the catalog."""
        session, _ = db_session
        assert caps.resolve(session, "cow", "F", "adult", "dairy").has(Cap.WEIGHT_TRACKING)
        session.add(lm.SpeciesCapabilityRule(
            species_code="cow", capability_code=Cap.WEIGHT_TRACKING, sex="F", life_stage="adult",
            management_profile="dairy", enabled=False, priority=1,
        ))
        session.commit()
        assert not caps.resolve(session, "cow", "F", "adult", "dairy").has(Cap.WEIGHT_TRACKING)
        # …and only for that combination.
        assert caps.resolve(session, "cow", "M", "adult", "breeding").has(Cap.WEIGHT_TRACKING)

    def test_biology_beats_configuration(self, db_session):
        """Even a rule that says a hen may be pregnant does not make her."""
        session, _ = db_session
        session.add(lm.SpeciesCapabilityRule(species_code="layer_hen", capability_code=Cap.PREGNANCY, enabled=True, priority=99))
        session.commit()
        cs = caps.resolve(session, "layer_hen", "F", "adult", "layer")
        assert not cs.has(Cap.PREGNANCY)
        assert Cap.PREGNANCY in cs.suppressed


# ============================================================== endpoints
class TestConfigurationEndpoints:
    def test_species_list_carries_terminology_and_icon(self, client):
        r = client.get(f"{BASE}/species", headers=auth_headers(client))
        assert r.status_code == 200
        by_code = {s["code"]: s for s in r.json()}
        assert {"cow", "sheep", "goat", "horse", "layer_hen", "duck", "turkey", "other"} <= set(by_code)
        assert by_code["goat"]["terminology_json"]["birth_en"] == "Kidding"
        assert by_code["horse"]["icon"] == "horse"

    def test_species_configuration(self, client):
        r = client.get(f"{BASE}/species/cow/configuration", headers=auth_headers(client))
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["species"]["code"] == "cow"
        assert {b["name"] for b in body["breeds"]} >= {"Holstein Friesian", "Jersey"}
        assert {p["code"] for p in body["management_profiles"]} >= {"dairy", "meat", "breeding"}
        assert any(rule["capability_code"] == Cap.MILK_PRODUCTION for rule in body["rules"])

    def test_configuration_offers_only_this_species_profiles(self, client):
        """A horse is never offered "broiler"; a hen is never offered "dairy"."""
        h = auth_headers(client)
        horse = {p["code"] for p in client.get(f"{BASE}/species/horse/configuration", headers=h).json()["management_profiles"]}
        assert horse == {"breeding", "work", "companion"}
        hen = {p["code"] for p in client.get(f"{BASE}/species/layer_hen/configuration", headers=h).json()["management_profiles"]}
        assert hen == {"layer", "broiler", "breeding"}

    def test_unknown_species_configuration_is_422(self, client):
        r = client.get(f"{BASE}/species/dragon/configuration", headers=auth_headers(client))
        assert r.status_code == 422
        assert "dragon" in r.json()["detail"]

    def test_resolve_accepts_the_specs_spelling(self, client):
        r = client.post(f"{BASE}/animal-capabilities/resolve",
                        json={"species": "cow", "sex": "FEMALE", "life_stage": "adult", "management_profile": "dairy"},
                        headers=auth_headers(client))
        assert r.status_code == 200, r.text
        body = r.json()
        codes = {c["code"] for c in body["capabilities"]}
        assert Cap.MILK_PRODUCTION in codes
        assert body["sex"] == "F"
        assert body["required_identifier_types"] == ["EAR_TAG"]
        assert body["terminology"]["birth_en"] == "Calving"

    def test_animal_capabilities_and_twin_agree(self, client):
        h = auth_headers(client)
        direct = client.get(f"{BASE}/animals/{BELLA}/capabilities", headers=h).json()
        twin = client.get(f"{BASE}/animals/{BELLA}", headers=h).json()
        assert {c["code"] for c in direct["capabilities"]} == {c["code"] for c in twin["capabilities"]["capabilities"]}
        assert Cap.MILK_PRODUCTION in {c["code"] for c in direct["capabilities"]}
        # The seeded ear tag became a typed identifier row.
        assert twin["identifiers"][0]["identifier_type"] == "EAR_TAG"
        assert twin["identifiers"][0]["identifier_value"] == twin["tag"] == "744"


# ========================================================== animal writes
class TestAnimalRegistration:
    def _create(self, client, **body):
        return client.post(f"{BASE}/animals", json=body, headers=auth_headers(client))

    def test_mare_registered_by_microchip_with_no_ear_tag(self, client):
        r = self._create(client, name="Luna", species="horse", sex="F", life_stage="adult", management_profile="breeding",
                         identifiers=[{"identifier_type": "MICROCHIP", "identifier_value": "985141000123456"},
                                      {"identifier_type": "PASSPORT", "identifier_value": "HOR-LB-882", "issuing_authority": "LEF"}])
        assert r.status_code == 201, r.text
        body = r.json()
        assert body["tag"] == "985141000123456"   # the primary identifier's value
        assert {i["identifier_type"] for i in body["identifiers"]} == {"MICROCHIP", "PASSPORT"}
        assert [i for i in body["identifiers"] if i["is_primary"]][0]["identifier_type"] == "MICROCHIP"

    def test_ear_tag_is_refused_on_a_horse(self, client):
        r = self._create(client, name="Storm", species="horse", sex="M",
                         identifiers=[{"identifier_type": "EAR_TAG", "identifier_value": "H-99"}])
        assert r.status_code == 422
        assert "ear tag" in r.json()["detail"].lower()

    def test_a_horse_must_have_a_microchip(self, client):
        r = self._create(client, name="Storm", species="horse", sex="M",
                         identifiers=[{"identifier_type": "NAME", "identifier_value": "Storm"}])
        assert r.status_code == 422
        assert "microchip" in r.json()["detail"].lower()

    def test_a_cow_needs_an_ear_tag(self, client):
        r = self._create(client, name="Nameless", species="cow", sex="F")
        assert r.status_code == 422
        assert "ear tag" in r.json()["detail"].lower()

    def test_legacy_tag_becomes_a_typed_identifier(self, client):
        cow = self._create(client, tag="901", name="Nour", species="cow", sex="F")
        assert cow.status_code == 201, cow.text
        assert cow.json()["identifiers"][0]["identifier_type"] == "EAR_TAG"
        hen = self._create(client, tag="B-77", name="Hen 77", species="layer_hen", sex="F", management_profile="layer")
        assert hen.status_code == 201, hen.text
        assert hen.json()["identifiers"][0]["identifier_type"] == "LEG_BAND"

    def test_duplicate_identifier_on_the_farm_is_409(self, client):
        r = self._create(client, tag="744", name="Twin", species="cow", sex="F")
        assert r.status_code == 409
        assert "744" in r.json()["detail"] and "Bella" in r.json()["detail"]

    def test_hen_cannot_be_pregnant(self, client):
        r = self._create(client, tag="B-78", name="Hen 78", species="layer_hen", sex="F", pregnant=True)
        assert r.status_code == 422
        assert "pregnancy" in r.json()["detail"].lower()

    def test_bull_cannot_be_lactating(self, client):
        r = self._create(client, tag="B-1", name="Taurus", species="cow", sex="M", lactating=True)
        assert r.status_code == 422
        assert "lactation" in r.json()["detail"].lower()

    def test_unknown_species_is_422_not_a_500(self, client):
        r = self._create(client, tag="X-1", name="Puff", species="dragon", sex="F")
        assert r.status_code == 422

    def test_adding_a_species_is_configuration(self, client, db_session):
        """§14: goats-that-were-not-there-yesterday. A new species row and
        its rules, then an animal of it — no code, no new table."""
        session, _ = db_session
        session.add(lm.Species(code="camel", name_en="Camels", name_ar="جمال", reproduction_mode="viviparous",
                               icon="barn", default_management="individual",
                               terminology_json={"birth_en": "Calving", "female_en": "Cow", "male_en": "Bull"}))
        session.flush()
        for cap, kw in ((Cap.EAR_TAG, {"required": True}), (Cap.INDIVIDUAL_TRACKING, {}), (Cap.HEALTH, {}),
                        (Cap.MILK_PRODUCTION, {"sex": "F", "management_profile": "dairy"}),
                        (Cap.LACTATION, {"sex": "F", "management_profile": "dairy"})):
            session.add(lm.SpeciesCapabilityRule(species_code="camel", capability_code=cap, enabled=True, **kw))
        session.commit()

        r = self._create(client, tag="C-1", name="Sahar", species="camel", sex="F", life_stage="adult",
                         management_profile="dairy", lactating=True)
        assert r.status_code == 201, r.text
        milk = client.post(f"{BASE}/production/milk",
                           json={"animal_id": r.json()["id"], "session": "morning", "liters": 6.0, "destination": "stored"},
                           headers=auth_headers(client))
        assert milk.status_code == 201, milk.text


class TestAnimalUpdates:
    def _put(self, client, animal_id, **changes):
        return client.put(f"{BASE}/animals/{animal_id}", json=changes, headers=auth_headers(client))

    def test_changing_sex_re_evaluates_pregnancy(self, client):
        r = self._put(client, BELLA, sex="M")
        assert r.status_code == 422
        assert "pregnancy" in r.json()["detail"].lower() or "lactation" in r.json()["detail"].lower()

    def test_changing_profile_re_evaluates_lactation(self, client):
        r = self._put(client, BELLA, management_profile="meat")
        assert r.status_code == 422

    def test_species_is_locked_once_there_is_history(self, client):
        # Bella has milk records from the seed.
        r = self._put(client, BELLA, species="goat")
        assert r.status_code == 409
        assert "cannot be changed" in r.json()["detail"]

    def test_species_can_change_before_any_history(self, client):
        created = client.post(f"{BASE}/animals", json={"tag": "T-1", "name": "Tempo", "species": "sheep", "sex": "F"},
                              headers=auth_headers(client)).json()
        r = self._put(client, created["id"], species="goat")
        assert r.status_code == 200, r.text
        assert r.json()["species"] == "goat"

    def test_editing_the_tag_retires_the_old_identifier(self, client, db_session):
        session, _ = db_session
        r = self._put(client, BELLA, tag="744-B")
        assert r.status_code == 200, r.text
        assert r.json()["tag"] == "744-B"
        rows = session.scalars(select(lm.AnimalIdentifier).where(lm.AnimalIdentifier.animal_id == BELLA)).all()
        by_value = {i.identifier_value: i for i in rows}
        assert by_value["744"].status == "retired" and not by_value["744"].is_primary
        assert by_value["744-B"].status == "active" and by_value["744-B"].is_primary


class TestIdentifierEndpoints:
    def test_add_and_retire(self, client):
        h = auth_headers(client)
        added = client.post(f"{BASE}/animals/{BELLA}/identifiers",
                            json={"identifier_type": "RFID", "identifier_value": "982000123456789"}, headers=h)
        assert added.status_code == 201, added.text
        assert added.json()["is_primary"] is False  # the ear tag stays primary
        listed = client.get(f"{BASE}/animals/{BELLA}/identifiers", headers=h).json()
        assert {i["identifier_type"] for i in listed} == {"EAR_TAG", "RFID"}

        gone = client.delete(f"{BASE}/animals/{BELLA}/identifiers/{added.json()['id']}", headers=h)
        assert gone.status_code == 204
        after = client.get(f"{BASE}/animals/{BELLA}/identifiers", headers=h).json()
        assert next(i for i in after if i["identifier_type"] == "RFID")["status"] == "retired"

    def test_cannot_retire_the_only_required_identifier(self, client):
        h = auth_headers(client)
        ear_tag = next(i for i in client.get(f"{BASE}/animals/{BELLA}/identifiers", headers=h).json()
                       if i["identifier_type"] == "EAR_TAG")
        r = client.delete(f"{BASE}/animals/{BELLA}/identifiers/{ear_tag['id']}", headers=h)
        assert r.status_code == 422
        assert "ear tag" in r.json()["detail"].lower()

    def test_a_new_primary_takes_over_the_tag(self, client):
        h = auth_headers(client)
        r = client.post(f"{BASE}/animals/{BELLA}/identifiers",
                        json={"identifier_type": "RFID", "identifier_value": "982000000000001", "is_primary": True}, headers=h)
        assert r.status_code == 201, r.text
        assert client.get(f"{BASE}/animals/{BELLA}", headers=h).json()["tag"] == "982000000000001"


# ===================================================== production gating
class TestProductionGating:
    def test_a_stallion_has_no_milk_record(self, client):
        r = client.post(f"{BASE}/production/milk",
                        json={"animal_id": THUNDER, "session": "morning", "liters": 2.0, "destination": "stored"},
                        headers=auth_headers(client))
        assert r.status_code == 422
        assert "milk production" in r.json()["detail"].lower()

    def test_a_dairy_cow_does(self, client):
        r = client.post(f"{BASE}/production/milk",
                        json={"animal_id": BELLA, "session": "morning", "liters": 11.0, "destination": "stored"},
                        headers=auth_headers(client))
        assert r.status_code == 201, r.text

    def test_a_laying_flock_lays(self, client):
        r = client.post(f"{BASE}/production/eggs",
                        json={"flock_id": LAYER_FLOCK, "total_eggs": 100, "sellable_eggs": 95, "broken_eggs": 5},
                        headers=auth_headers(client))
        assert r.status_code == 201, r.text

    def test_a_broiler_flock_does_not(self, client):
        h = auth_headers(client)
        group = client.post(f"{BASE}/animal-groups",
                            json={"name": "Broilers 04", "species": "layer_hen", "count": 300, "management_profile": "broiler"},
                            headers=h)
        assert group.status_code == 201, group.text
        r = client.post(f"{BASE}/production/eggs", json={"flock_id": group.json()["id"], "total_eggs": 10}, headers=h)
        assert r.status_code == 422
        assert "egg production" in r.json()["detail"].lower()

    def test_groups_are_for_species_that_are_kept_in_groups(self, client):
        h = auth_headers(client)
        sheep = client.post(f"{BASE}/animal-groups", json={"name": "Meadow flock", "species": "sheep", "count": 40}, headers=h)
        assert sheep.status_code == 201, sheep.text
        assert client.get(f"{BASE}/animal-groups/{sheep.json()['id']}/capabilities", headers=h).json()["subject_kind"] == "either"
        horses = client.post(f"{BASE}/animal-groups", json={"name": "Herd", "species": "horse", "count": 4}, headers=h)
        assert horses.status_code == 422
