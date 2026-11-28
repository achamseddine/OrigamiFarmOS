"""Nutrient requirements and the explainable assessment of a formula
(master prompt Package 11; database/NUTRITION-ASSESSMENT.md).

    the farm's base concentrate: 350 kg corn + 260 kg soybean ingredient
      + 200 kg barley + 200 kg wheat bran + 100 kg cottonseed + 100 kg beet
      pulp = 1,210 kg before any premix (never relabelled a one-ton batch)
    → each ingredient's analysis (declared or lab, as fed or on dry matter)
    → the mix on an as-fed and a dry-matter basis, with what each ingredient
      brings — and an optional premix added on top, the 1,210 kg kept
    → a cow's ration (the concentrate, the forage, her weight) against a
      versioned requirement set with its source
    → met / below / above per nutrient, or *insufficient data* naming what is
      unknown; never a ration authorised, never a milk yield predicted
"""
from __future__ import annotations

import pytest
from sqlalchemy import func, select

from app.domain import feed_models as fm
from app.services import nutrition_service as nut
from tests.conftest import auth_headers

API = "/api/v1"
WORKER = "karim.worker@origami.farm"
ACCOUNTANT = "nadine.acct@origami.farm"
BASE = [("Corn grain", 350), ("Soybean meal", 260), ("Barley grain", 200), ("Wheat bran", 200), ("Cottonseed", 100), ("Beet pulp", 100)]

# Synthetic analyses for the fixture (as fed): DM %, CP %, NEL MJ/kg, NDF %, peNDF %, Ca %, P %.
ANALYSES = {
    "Corn grain": {"DM": 88, "CP": 8.0, "NEL": 7.0, "NDF": 9.0, "PENDF": 0.0, "CA": 0.03, "P": 0.27},
    "Soybean meal": {"DM": 89, "CP": 44.0, "NEL": 7.4, "NDF": 13.0, "PENDF": 0.0, "CA": 0.30, "P": 0.63},
    "Barley grain": {"DM": 89, "CP": 11.0, "NEL": 6.8, "NDF": 18.0, "PENDF": 6.0, "CA": 0.05, "P": 0.35},
    "Wheat bran": {"DM": 89, "CP": 15.5, "NEL": 5.9, "NDF": 42.0, "PENDF": 4.0, "CA": 0.12, "P": 1.05},
    "Cottonseed": {"DM": 91, "CP": 21.0, "NEL": 8.4, "NDF": 45.0, "PENDF": 40.0, "CA": 0.15, "P": 0.55},
    "Beet pulp": {"DM": 90, "CP": 9.0, "NEL": 6.3, "NDF": 41.0, "PENDF": 15.0, "CA": 0.62, "P": 0.08},
}
SILAGE = {"DM": 33, "CP": 2.6, "NEL": 2.1, "NDF": 14.5, "PENDF": 11.0, "CA": 0.08, "P": 0.08}


def _h(client, email="rami@origami.farm", **extra):
    return {**auth_headers(client, email), **extra}


def _product(client, name, *, ingredient=True, category="concentrate", ration_type=None):
    source = "purchased" if ingredient else "farm_produced"
    r = client.post(f"{API}/feed-products", headers=_h(client), json={"name": name, "source_type": source, "is_ingredient": ingredient,
                                                                      "category": category, "ration_type": ration_type or "raw_material"})
    assert r.status_code == 201, r.text
    return r.json()["id"]


def _analysis(client, product_id, values: dict, *, basis="as_fed", source="declared", reference="Supplier sheet 2026-10"):
    r = client.post(f"{API}/feed-nutrient-profiles", headers=_h(client), json={
        "subject_type": "feed_product", "subject_id": product_id, "basis": basis, "source_type": source, "reference": reference,
        "values": [{"nutrient_code": k, "value": v} for k, v in values.items()]})
    assert r.status_code == 201, r.text
    return r.json()["id"]


@pytest.fixture()
def farm_mix(client):
    """The base concentrate, as a cow formula of 1,210 kg, and its six ingredients."""
    ids = {name: _product(client, name) for name, _ in BASE}
    out = _product(client, "Base concentrate", ingredient=False, category="complete_feed", ration_type="concentrate")
    r = client.post(f"{API}/feed-formulas", headers=_h(client), json={
        "name": "Base concentrate", "feed_product_id": out, "species_code": "cow", "batch_size": 1210,
        "components": [{"feed_product_id": ids[n], "target_quantity": q} for n, q in BASE]})
    assert r.status_code == 201, r.text
    formula = r.json()
    version = next(v for v in formula["versions"] if v["version"] == formula["active_version"])
    return {"ids": ids, "formula": formula, "version_id": version["id"], "silage": "fp-corn-silage"}


def _analyse_all(client, farm_mix, *, skip=()):
    for name, values in ANALYSES.items():
        if name not in skip:
            _analysis(client, farm_mix["ids"][name], values)


def _requirements(client, **over):
    body = {
        "code": "DAIRY-EARLY", "name": "Early lactation, 650 kg, 30 kg milk", "species_code": "cow", "production_stage": "early_lactation",
        "reference_body_weight_kg": 650, "milk_yield_kg": 30, "expected_dmi_kg": 22,
        "source_reference": "Farm nutritionist, ration review 2026-09 (after NRC 2001 dairy tables)", "source_type": "nutritionist",
        "values": [
            {"nutrient_code": "CP", "min_value": 16.0, "max_value": 18.0},
            {"nutrient_code": "NEL", "min_value": 6.4},
            {"nutrient_code": "NDF", "min_value": 28.0},
            {"nutrient_code": "PENDF", "min_value": 21.0},
            {"nutrient_code": "CA", "min_value": 0.6},
            {"nutrient_code": "P", "min_value": 0.35, "max_value": 0.45},
        ],
        **over,
    }
    return client.post(f"{API}/nutrition/requirement-sets", headers=_h(client), json=body)


def _assess(client, farm_mix, requirement_set_id, **over):
    body = {"formula_version_id": farm_mix["version_id"], "requirement_set_id": requirement_set_id,
            "concentrate_kg_per_head": 9.0, "forages": [{"feed_product_id": farm_mix["silage"], "as_fed_kg": 38.0}], "body_weight_kg": 640, **over}
    return client.post(f"{API}/nutrition/assessments", headers=_h(client), json=body)


class TestTheBaseConcentrate:
    def test_the_1210_kg_mix_its_mass_balance_and_a_premix_on_top(self, client, farm_mix):
        rs = _requirements(client).json()
        r = _assess(client, farm_mix, rs["id"], forages=[], concentrate_kg_per_head=None)
        assert r.status_code == 201, r.text
        mix = r.json()["mix"]
        # 1,210 kg before any premix — never relabelled a one-ton batch.
        assert mix["base_total_kg"] == 1210 and mix["total_kg"] == 1210 and mix["premix"] is None
        corn = next(c for c in mix["components"] if c["name"] == "Corn grain")
        assert corn["quantity_kg"] == 350 and corn["inclusion_pct"] == pytest.approx(28.93, abs=0.01)
        assert sum(c["inclusion_pct"] for c in mix["components"]) == pytest.approx(100, abs=0.05)

        # The same mix with 12 kg of the dairy premix on top: 1,222 kg, the base still 1,210.
        premixed = _assess(client, farm_mix, rs["id"], forages=[], concentrate_kg_per_head=None,
                           premix={"feed_product_id": "fp-dairy-premix", "quantity_kg": 12}).json()["mix"]
        assert premixed["base_total_kg"] == 1210 and premixed["total_kg"] == 1222
        assert premixed["premix"]["quantity_kg"] == 12 and premixed["premix"]["inclusion_pct"] == pytest.approx(0.98, abs=0.01)
        corn = next(c for c in premixed["components"] if c["name"] == "Corn grain")
        assert corn["inclusion_pct"] == pytest.approx(350 / 1222 * 100, abs=0.01)

        # The formula itself is untouched: same version, same 1,210 kg, same rows.
        formula = client.get(f"{API}/feed-formulas/{farm_mix['formula']['id']}", headers=_h(client)).json()
        version = next(v for v in formula["versions"] if v["id"] == farm_mix["version_id"])
        assert version["batch_size"] == 1210 and len(version["components"]) == 6
        assert [c["target_quantity"] for c in version["components"]] == [q for _, q in BASE]

    def test_unknown_soy_cottonseed_and_beet_pulp_block_any_recommendation(self, client, farm_mix):
        _analyse_all(client, farm_mix, skip=("Soybean meal", "Cottonseed", "Beet pulp"))
        _analysis(client, farm_mix["silage"], SILAGE, source="lab", reference="Lab 2026-10-02")
        rs = _requirements(client).json()
        r = _assess(client, farm_mix, rs["id"])
        assert r.status_code == 201, r.text
        a = r.json()
        assert a["status"] == "insufficient_data"
        assert a["recommendation"] is None
        missing = " ".join(m["detail"] for m in a["missing"])
        for name in ("Soybean meal", "Cottonseed", "Beet pulp"):
            assert name in missing
        # Nothing is claimed met on part of the mix: each requirement reads insufficient.
        assert {n["status"] for n in a["ration"]["nutrients"]} == {"insufficient_data"}
        # The mix itself still shows what is known, with its coverage.
        cp = next(n for n in a["mix"]["nutrients"] if n["nutrient_code"] == "CP")
        assert cp["coverage_pct"] == pytest.approx((350 + 200 + 200) / 1210 * 100, abs=0.1) and cp["dry_matter_value"] is None

    def test_unknown_intake_forage_or_weight_is_insufficient_data(self, client, farm_mix):
        _analyse_all(client, farm_mix)
        rs = _requirements(client).json()
        # No concentrate intake per head.
        a = _assess(client, farm_mix, rs["id"], concentrate_kg_per_head=None).json()
        assert a["status"] == "insufficient_data" and any(m["code"] == "intake_unknown" for m in a["missing"])
        # The silage has no analysis.
        a = _assess(client, farm_mix, rs["id"]).json()
        assert a["status"] == "insufficient_data" and any(m["code"] == "forage_profile_unknown" for m in a["missing"])
        _analysis(client, farm_mix["silage"], SILAGE, source="lab", reference="Lab 2026-10-02")
        # No body weight, while the requirements are for a 650 kg cow.
        a = _assess(client, farm_mix, rs["id"], body_weight_kg=None).json()
        assert a["status"] == "insufficient_data" and any(m["code"] == "body_weight_unknown" for m in a["missing"])
        # A 480 kg heifer is not what a 650 kg cow's requirements are for.
        a = _assess(client, farm_mix, rs["id"], body_weight_kg=480).json()
        assert a["status"] == "insufficient_data" and any(m["code"] == "body_weight_outside_set" for m in a["missing"])

    def test_with_everything_known_each_requirement_is_met_or_not_and_explained(self, client, farm_mix):
        _analyse_all(client, farm_mix)
        _analysis(client, farm_mix["silage"], SILAGE, source="lab", reference="Lab 2026-10-02")
        rs = _requirements(client).json()
        r = _assess(client, farm_mix, rs["id"])
        assert r.status_code == 201, r.text
        a = r.json()
        assert a["status"] in ("meets", "does_not_meet") and a["missing"] == []
        ration = a["ration"]
        # 9 kg of concentrate (about 88.9% DM) and 38 kg of silage at 33% DM.
        conc_dm = sum(q * ANALYSES[n]["DM"] / 100 for n, q in BASE) / 1210 * 9
        assert ration["dry_matter_intake_kg"] == pytest.approx(conc_dm + 38 * 0.33, abs=0.01)
        by = {n["nutrient_code"]: n for n in ration["nutrients"]}
        assert set(by) == {"CP", "NEL", "NDF", "PENDF", "CA", "P"}
        cp = by["CP"]
        assert cp["status"] in ("met", "below", "above") and cp["min_value"] == 16.0
        # Explained: what each feed brings to the ration's protein.
        assert {c["name"] for c in cp["contributions"]} == {"Base concentrate", "Corn Silage"}
        assert sum(c["share_pct"] for c in cp["contributions"]) == pytest.approx(100, abs=0.1)
        # Calcium is short (0.6% wanted): it says so, and a recommendation explains it without prescribing a ration.
        assert by["CA"]["status"] == "below"
        assert a["status"] == "does_not_meet"
        assert "Calcium" in a["recommendation"] and "not a ration" in a["recommendation"].lower()
        # The intake against the set's expected intake.
        assert ration["expected_dmi_kg"] == 22
        # The requirement set, its version and its source travel with it.
        assert a["requirement_set"]["version"] == 1 and "nutritionist" in a["requirement_set"]["source_reference"]
        # Never a milk yield predicted from a recipe.
        assert "milk" not in {k.lower() for k in a}


class TestDryMatter:
    def test_as_fed_and_dry_matter_conversion(self):
        # 8% protein as fed in a grain of 88% DM is 9.09% of its dry matter.
        assert nut.to_dry_matter(8.0, dm_pct=88) == pytest.approx(9.0909, abs=1e-4)
        assert nut.to_as_fed(9.0909, dm_pct=88) == pytest.approx(8.0, abs=1e-3)
        with pytest.raises(nut.NutritionError):
            nut.to_dry_matter(8.0, dm_pct=0)

    def test_an_analysis_on_dry_matter_is_read_as_such(self, client, farm_mix):
        _analyse_all(client, farm_mix, skip=("Corn grain",))
        dm_values = {k: (v if k == "DM" else nut.to_dry_matter(v, dm_pct=88)) for k, v in ANALYSES["Corn grain"].items()}
        _analysis(client, farm_mix["ids"]["Corn grain"], dm_values, basis="dry_matter", source="lab", reference="Lab 2026-09-30")
        rs = _requirements(client).json()
        a = _assess(client, farm_mix, rs["id"], forages=[], concentrate_kg_per_head=None).json()
        cp = next(n for n in a["mix"]["nutrients"] if n["nutrient_code"] == "CP")
        expected_af = sum(q * ANALYSES[n]["CP"] for n, q in BASE) / 1210
        assert cp["as_fed_value"] == pytest.approx(expected_af, abs=0.01)
        dm_kg = sum(q * ANALYSES[n]["DM"] / 100 for n, q in BASE)
        assert a["mix"]["dry_matter_kg"] == pytest.approx(dm_kg, abs=0.01)
        assert cp["dry_matter_value"] == pytest.approx(expected_af * 1210 / dm_kg, abs=0.01)
        corn = next(c for c in a["mix"]["components"] if c["name"] == "Corn grain")
        assert corn["profile"]["source_type"] == "lab" and corn["profile"]["basis"] == "dry_matter"

    def test_an_analysis_without_dry_matter_cannot_be_put_on_dry_matter(self, client, farm_mix):
        _analyse_all(client, farm_mix, skip=("Wheat bran",))
        _analysis(client, farm_mix["ids"]["Wheat bran"], {"CP": 15.5})
        rs = _requirements(client).json()
        a = _assess(client, farm_mix, rs["id"], forages=[], concentrate_kg_per_head=None).json()
        assert any(m["code"] == "dry_matter_unknown" and "Wheat bran" in m["detail"] for m in a["missing"])


class TestRequirementSets:
    def test_a_requirement_set_needs_its_source_and_changes_by_new_versions(self, client, farm_mix):
        assert _requirements(client, source_reference="").status_code == 422
        assert _requirements(client, values=[]).status_code == 422
        assert _requirements(client, values=[{"nutrient_code": "CP", "min_value": 18, "max_value": 16}]).status_code == 422
        assert _requirements(client, values=[{"nutrient_code": "NOPE", "min_value": 1}]).status_code == 422
        v1 = _requirements(client).json()
        assert v1["version"] == 1 and v1["status"] == "active"
        _analyse_all(client, farm_mix)
        _analysis(client, farm_mix["silage"], SILAGE, source="lab", reference="Lab 2026-10-02")
        first = _assess(client, farm_mix, v1["id"]).json()
        # A revision is a new version beside the first; the old one is retired, not rewritten.
        v2 = client.post(f"{API}/nutrition/requirement-sets/{v1['id']}/versions", headers=_h(client), json={
            "source_reference": "Nutritionist revision 2026-11: calcium raised", "values": [{"nutrient_code": "CP", "min_value": 16.0, "max_value": 18.0},
                                                                                            {"nutrient_code": "CA", "min_value": 0.7}]})
        assert v2.status_code == 201, v2.text
        assert v2.json()["version"] == 2 and v2.json()["code"] == "DAIRY-EARLY"
        sets = client.get(f"{API}/nutrition/requirement-sets", headers=_h(client), params={"include_retired": True}).json()
        assert {(s["version"], s["status"]) for s in sets if s["code"] == "DAIRY-EARLY"} == {(1, "retired"), (2, "active")}
        # The first assessment still reads against version 1, as it was.
        again = client.get(f"{API}/nutrition/assessments/{first['id']}", headers=_h(client)).json()
        assert again["requirement_set"]["version"] == 1 and again["ration"] == first["ration"]
        # A retired set is not assessed against.
        assert _assess(client, farm_mix, v1["id"]).status_code == 409

    def test_other_species_need_their_own_requirements(self, client, farm_mix):
        sheep = _requirements(client, code="EWE-LATE", name="Ewes, late gestation", species_code="sheep", reference_body_weight_kg=70,
                              expected_dmi_kg=1.9).json()
        r = _assess(client, farm_mix, sheep["id"], body_weight_kg=70)
        assert r.status_code == 422 and "sheep" in r.json()["detail"] and "cow" in r.json()["detail"]

    def test_a_premix_that_is_not_for_this_species_is_refused(self, client, farm_mix):
        out = _product(client, "Ewe mix", ingredient=False, category="complete_feed", ration_type="concentrate")
        r = client.post(f"{API}/feed-formulas", headers=_h(client), json={
            "name": "Ewe mix", "feed_product_id": out, "species_code": "sheep", "batch_size": 300,
            "components": [{"feed_product_id": farm_mix["ids"]["Barley grain"], "target_quantity": 200},
                           {"feed_product_id": farm_mix["ids"]["Beet pulp"], "target_quantity": 100}]})
        assert r.status_code == 201, r.text
        ewe = r.json()
        sheep = _requirements(client, code="EWE-LATE", name="Ewes", species_code="sheep", reference_body_weight_kg=70, expected_dmi_kg=1.9).json()
        r = client.post(f"{API}/nutrition/assessments", headers=_h(client), json={
            "formula_version_id": ewe["versions"][0]["id"], "requirement_set_id": sheep["id"], "premix": {"feed_product_id": "fp-dairy-premix", "quantity_kg": 3}})
        assert r.status_code == 422, r.text
        assert "premix" in r.json()["detail"].lower()


class TestWhoAndWhichFarm:
    def test_roles_and_farms(self, client, db_session, farm_mix):
        session, _ = db_session
        from app.core.security import hash_password
        from app.domain import models

        # Requirement sets are the manager's; whoever sees the feed reads them; accounts do not.
        assert _requirements(client).status_code == 201
        rs = client.get(f"{API}/nutrition/requirement-sets", headers=_h(client)).json()[0]
        worker_try = client.post(f"{API}/nutrition/requirement-sets", headers=_h(client, WORKER), json={
            "code": "X", "name": "X", "species_code": "cow", "source_reference": "x", "values": [{"nutrient_code": "CP", "min_value": 1}]})
        assert worker_try.status_code == 403
        assert client.get(f"{API}/nutrition/requirement-sets", headers=_h(client, ACCOUNTANT)).status_code == 403
        a = _assess(client, farm_mix, rs["id"]).json()
        session.add(models.Farm(id="farm-other", name="Other", country="Lebanon", region="North", timezone="Asia/Beirut", default_currency="USD"))
        session.add(models.User(id="user-other", farm_id="farm-other", name="Other Manager", email="m@other.farm", password_hash=hash_password("farmos123"),
                                role="manager", language="en"))
        session.commit()
        other = _h(client, "m@other.farm")
        assert client.get(f"{API}/nutrition/assessments/{a['id']}", headers=other).status_code == 404
        assert client.get(f"{API}/nutrition/requirement-sets", headers=other).json() == []
        assert _assess(client, farm_mix, rs["id"]).status_code == 201
        r = client.post(f"{API}/nutrition/assessments", headers=other, json={"formula_version_id": farm_mix["version_id"], "requirement_set_id": rs["id"]})
        assert r.status_code == 404

    def test_an_assessment_is_kept_as_it_was_and_a_retry_is_one(self, client, db_session, farm_mix):
        session, _ = db_session
        rs = _requirements(client).json()
        key = {"Idempotency-Key": "assess-1"}
        one = client.post(f"{API}/nutrition/assessments", headers=_h(client, **key), json={"formula_version_id": farm_mix["version_id"], "requirement_set_id": rs["id"]})
        two = client.post(f"{API}/nutrition/assessments", headers=_h(client, **key), json={"formula_version_id": farm_mix["version_id"], "requirement_set_id": rs["id"]})
        assert one.json()["id"] == two.json()["id"]
        from app.domain import nutrition_models as nm
        assert session.scalar(select(func.count(nm.NutritionAssessment.id))) == 1
        # A later analysis does not change what was assessed then.
        _analyse_all(client, farm_mix)
        assert client.get(f"{API}/nutrition/assessments/{one.json()['id']}", headers=_h(client)).json()["mix"] == one.json()["mix"]
        listed = client.get(f"{API}/nutrition/assessments", headers=_h(client), params={"formula_version_id": farm_mix["version_id"]}).json()
        assert [x["id"] for x in listed] == [one.json()["id"]]
        assert session.scalar(select(func.count(fm.FeedFormulaVersion.id)).where(fm.FeedFormulaVersion.formula_id == farm_mix["formula"]["id"])) == 1
