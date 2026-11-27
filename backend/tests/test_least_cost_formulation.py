"""Least-cost formulation drafts (master prompt Package 12; database/LEAST-COST-FORMULATION.md).

    the farm's base concentrate (1,210 kg: corn, soybean, barley, wheat bran,
      cottonseed, beet pulp), each with its analysis and today's price —
      the lot that would be used next, else the feed's price
    → against a cow's requirements in her ration (the concentrate per head,
      the silage, her weight): up to three drafts — A the cheapest, B the
      cheapest with a safety margin, C the closest to the current formula —
      each meeting every requirement, each costed, with its saving
    → or *infeasible* naming the requirement that cannot be reached, or
      *insufficient data* (an analysis or a price unknown): no draft at all
    → the manager approves one draft, with a reason: a new **draft** version
      of the formula, never active by itself; a later price never rewrites
      the run nor any batch
"""
from __future__ import annotations

import pytest
from sqlalchemy import func, select

from app.domain import feed_models as fm
from app.domain import formulation_models as fmm
from app.domain import models
from tests.conftest import auth_headers
from tests.test_nutrition_assessment import ANALYSES, BASE, SILAGE, _analyse_all, _analysis, _product, _requirements, farm_mix  # noqa: F401

API = "/api/v1"
ACCOUNTANT = "nadine.acct@origami.farm"
PRICES = {"Corn grain": 0.30, "Soybean meal": 0.62, "Barley grain": 0.33, "Wheat bran": 0.22, "Cottonseed": 0.40, "Beet pulp": 0.28}
FEASIBLE = [
    {"nutrient_code": "CP", "min_value": 15.0, "max_value": 18.0},
    {"nutrient_code": "NEL", "min_value": 6.4},
    {"nutrient_code": "NDF", "min_value": 28.0},
    {"nutrient_code": "PENDF", "min_value": 20.0},
    {"nutrient_code": "P", "min_value": 0.30, "max_value": 0.50},
]


def _h(client, email="rami@origami.farm", **extra):
    return {**auth_headers(client, email), **extra}


def _price_all(client, farm_mix, *, skip=()):
    for name, price in PRICES.items():
        if name not in skip:
            r = client.patch(f"{API}/feed-products/{farm_mix['ids'][name]}", headers=_h(client), json={"default_unit_cost": price})
            assert r.status_code == 200, r.text


def _ready(client, farm_mix):
    _analyse_all(client, farm_mix)
    _analysis(client, farm_mix["silage"], SILAGE, source="lab", reference="Lab 2026-10-02")
    _price_all(client, farm_mix)
    return _requirements(client, values=FEASIBLE).json()


def _run(client, farm_mix, rs_id, **over):
    body = {"requirement_set_id": rs_id, "base_formula_version_id": farm_mix["version_id"], "concentrate_kg_per_head": 9.0,
            "forages": [{"feed_product_id": farm_mix["silage"], "as_fed_kg": 38.0}], "body_weight_kg": 640, **over}
    return client.post(f"{API}/nutrition/least-cost", headers=_h(client), json=body)


class TestDrafts:
    def test_three_drafts_each_meeting_every_requirement_and_costed(self, client, farm_mix):
        rs = _ready(client, farm_mix)
        r = _run(client, farm_mix, rs["id"])
        assert r.status_code == 201, r.text
        run = r.json()
        assert run["status"] == "drafts" and run["missing"] == [] and run["infeasible"] == []
        drafts = {d["key"]: d for d in run["drafts"]}
        assert set(drafts) == {"A", "B", "C"}
        for d in drafts.values():
            # The batch the farm makes: 1,210 kg, to the tenth of a kilo.
            assert sum(c["quantity_kg"] for c in d["components"]) == pytest.approx(1210, abs=0.01)
            assert {n["status"] for n in d["nutrients"]} == {"met"}, d["nutrients"]
            assert d["cost"] == pytest.approx(sum(c["cost"] for c in d["components"]), abs=0.05)
        # A is the cheapest; B pays for its margin; C changes the least.
        assert drafts["A"]["cost"] <= drafts["B"]["cost"] + 0.01 and drafts["A"]["cost"] <= drafts["C"]["cost"] + 0.01
        cp_a = next(n for n in drafts["A"]["nutrients"] if n["nutrient_code"] == "CP")["value"]
        cp_b = next(n for n in drafts["B"]["nutrients"] if n["nutrient_code"] == "CP")["value"]
        assert cp_b >= 15.0 * 1.03 - 0.01 and cp_a >= 15.0 - 0.01
        assert drafts["C"]["changed_kg"] >= 0
        # Each against what the current formula costs today.
        base_cost = sum(PRICES[n] * q for n, q in BASE)
        assert run["base"]["cost_today"] == pytest.approx(base_cost, abs=0.01)
        assert drafts["A"]["saving"] == pytest.approx(base_cost - drafts["A"]["cost"], abs=0.01)
        # The prices are the run's own, with where they come from.
        soy = next(p for p in run["prices"] if p["name"] == "Soybean meal")
        assert soy["price_per_kg"] == 0.62 and soy["source"] == "price"

    def test_the_limits_and_a_margin_of_zero(self, client, farm_mix):
        rs = _ready(client, farm_mix)
        ids = farm_mix["ids"]
        candidates = [{"feed_product_id": ids[n]} for n, _ in BASE]
        candidates[0] = {"feed_product_id": ids["Corn grain"], "min_pct": 20, "max_pct": 30}
        run = _run(client, farm_mix, rs["id"], candidates=candidates, margin_pct=0).json()
        assert run["status"] == "drafts"
        assert {d["key"] for d in run["drafts"]} == {"A", "C"}  # no margin, no draft B
        for d in run["drafts"]:
            corn = next((c for c in d["components"] if c["name"] == "Corn grain"), {"quantity_kg": 0})
            assert 0.20 * 1210 - 0.1 <= corn["quantity_kg"] <= 0.30 * 1210 + 0.1

    def test_a_requirement_that_cannot_be_reached_is_named(self, client, farm_mix):
        _ready(client, farm_mix)
        calcium = _requirements(client, code="DAIRY-CA", values=FEASIBLE + [{"nutrient_code": "CA", "min_value": 0.6}]).json()
        run = _run(client, farm_mix, calcium["id"]).json()
        assert run["status"] == "infeasible" and run["drafts"] == []
        assert [x["nutrient_code"] for x in run["infeasible"]] == ["CA"]
        assert "Calcium" in run["infeasible"][0]["detail"] and run["infeasible"][0]["value"] == 0.6
        # Soybean held to 5 %: the protein cannot be reached either.
        ids = farm_mix["ids"]
        held = [{"feed_product_id": ids[n], **({"max_pct": 5} if n == "Soybean meal" else {})} for n, _ in BASE]
        run = _run(client, farm_mix, _requirements(client, code="DAIRY-2", values=FEASIBLE).json()["id"], candidates=held).json()
        assert run["status"] == "infeasible" and "CP" in [x["nutrient_code"] for x in run["infeasible"]]


class TestNothingIsGuessed:
    def test_a_missing_analysis_or_price_means_no_optimisation(self, client, farm_mix):
        _analyse_all(client, farm_mix, skip=("Cottonseed",))
        _analysis(client, farm_mix["silage"], SILAGE, source="lab", reference="Lab 2026-10-02")
        _price_all(client, farm_mix, skip=("Beet pulp",))
        rs = _requirements(client, values=FEASIBLE).json()
        run = _run(client, farm_mix, rs["id"]).json()
        assert run["status"] == "insufficient_data" and run["drafts"] == []
        codes = {(m["code"], m.get("feed_product_id")) for m in run["missing"]}
        assert ("analysis_unknown", farm_mix["ids"]["Cottonseed"]) in codes
        assert ("price_unknown", farm_mix["ids"]["Beet pulp"]) in codes
        # And no intake: nothing to put the requirements on.
        assert any(m["code"] == "intake_unknown" for m in _run(client, farm_mix, rs["id"], concentrate_kg_per_head=None).json()["missing"])

    def test_other_species_and_a_blocked_premix_are_refused(self, client, farm_mix):
        rs = _ready(client, farm_mix)
        sheep = _requirements(client, code="EWE", name="Ewes", species_code="sheep", reference_body_weight_kg=70, expected_dmi_kg=1.9, values=FEASIBLE).json()
        r = _run(client, farm_mix, sheep["id"], body_weight_kg=70)
        assert r.status_code == 422 and "sheep" in r.json()["detail"]
        # Without a base formula, a cattle-only premix offered for ewes is refused before anything is solved.
        ids = farm_mix["ids"]
        r = client.post(f"{API}/nutrition/least-cost", headers=_h(client), json={
            "requirement_set_id": sheep["id"], "batch_size_kg": 300, "candidates": [{"feed_product_id": ids["Barley grain"]}, {"feed_product_id": "fp-dairy-premix"}],
            "concentrate_kg_per_head": 0.5, "no_forage": True, "body_weight_kg": 70})
        assert r.status_code == 422 and "premix" in r.json()["detail"].lower()
        r = client.post(f"{API}/nutrition/least-cost", headers=_h(client), json={
            "requirement_set_id": sheep["id"], "batch_size_kg": 300, "candidates": [{"feed_product_id": ids["Barley grain"]}],
            "premix": {"feed_product_id": "fp-dairy-premix", "quantity_kg": 3}, "concentrate_kg_per_head": 0.5, "no_forage": True, "body_weight_kg": 70})
        assert r.status_code == 422 and "premix" in r.json()["detail"].lower()
        assert rs["species_code"] == "cow"


class TestApprovalAndHistory:
    def test_the_manager_approves_one_draft_as_a_new_draft_version(self, client, db_session, farm_mix):
        session, _ = db_session
        rs = _ready(client, farm_mix)
        run = _run(client, farm_mix, rs["id"]).json()
        url = f"{API}/nutrition/least-cost/{run['id']}/approve"
        assert client.post(url, headers=_h(client), json={"draft": "A", "note": ""}).status_code == 422
        assert client.post(url, headers=_h(client, "karim.worker@origami.farm"), json={"draft": "A", "note": "x"}).status_code == 403
        r = client.post(url, headers=_h(client), json={"draft": "A", "note": "Reviewed with the nutritionist, 2026-11-27"})
        assert r.status_code == 200, r.text
        out = r.json()
        v = out["formula_version"]
        assert v["status"] == "draft" and v["version"] == 2 and v["batch_size"] == pytest.approx(1210)
        assert out["approval"]["draft"] == "A" and "nutritionist" in out["approval"]["note"]
        # The current formula is still the active one, unchanged; the new version waits for the usual activation.
        formula = client.get(f"{API}/feed-formulas/{farm_mix['formula']['id']}", headers=_h(client)).json()
        assert formula["active_version"] == 1
        active = next(x for x in formula["versions"] if x["version"] == 1)
        assert [c["target_quantity"] for c in active["components"]] == [q for _, q in BASE]
        drafted = next(x for x in formula["versions"] if x["version"] == 2)
        a = next(d for d in run["drafts"] if d["key"] == "A")
        assert sorted(c["target_quantity"] for c in drafted["components"]) == sorted(c["quantity_kg"] for c in a["components"])
        # Once per run.
        assert client.post(url, headers=_h(client), json={"draft": "B", "note": "again"}).status_code == 409
        assert session.scalar(select(func.count(models.AuditLog.id)).where(models.AuditLog.action == "least_cost_draft_approved")) == 1

    def test_a_later_price_rewrites_neither_the_run_nor_a_batch(self, client, db_session, farm_mix):
        session, _ = db_session
        rs = _ready(client, farm_mix)
        run = _run(client, farm_mix, rs["id"]).json()
        batch_cost = session.scalar(select(fm.FeedBatch.actual_cost).where(fm.FeedBatch.batch_code == "MIX-2609-01"))
        client.patch(f"{API}/feed-products/{farm_mix['ids']['Soybean meal']}", headers=_h(client), json={"default_unit_cost": 0.95})
        client.patch(f"{API}/feed-products/fp-barley", headers=_h(client), json={"default_unit_cost": 0.50})
        again = client.get(f"{API}/nutrition/least-cost/{run['id']}", headers=_h(client)).json()
        assert again["drafts"] == run["drafts"] and again["prices"] == run["prices"]
        session.expire_all()
        assert session.scalar(select(fm.FeedBatch.actual_cost).where(fm.FeedBatch.batch_code == "MIX-2609-01")) == batch_cost
        # A new run uses the new price.
        newer = _run(client, farm_mix, rs["id"]).json()
        assert next(p for p in newer["prices"] if p["name"] == "Soybean meal")["price_per_kg"] == 0.95
        # A draft is a plan: no stock moved.
        assert session.scalar(select(func.count(models.InventoryTransaction.id)).where(models.InventoryTransaction.linked_entity_type == "formulation_run")) == 0

    def test_roles_farms_and_a_retry(self, client, db_session, farm_mix):
        session, _ = db_session
        from app.core.security import hash_password

        rs = _ready(client, farm_mix)
        body = {"requirement_set_id": rs["id"], "base_formula_version_id": farm_mix["version_id"], "concentrate_kg_per_head": 9.0,
                "forages": [{"feed_product_id": farm_mix["silage"], "as_fed_kg": 38.0}], "body_weight_kg": 640}
        assert client.post(f"{API}/nutrition/least-cost", headers=_h(client, ACCOUNTANT), json=body).status_code == 403
        key = {"Idempotency-Key": "lcf-1"}
        one = client.post(f"{API}/nutrition/least-cost", headers=_h(client, **key), json=body).json()
        two = client.post(f"{API}/nutrition/least-cost", headers=_h(client, **key), json=body).json()
        assert one["id"] == two["id"] and session.scalar(select(func.count(fmm.FormulationRun.id))) == 1
        session.add(models.Farm(id="farm-other", name="Other", country="Lebanon", region="North", timezone="Asia/Beirut", default_currency="USD"))
        session.add(models.User(id="user-other", farm_id="farm-other", name="Other Manager", email="m@other.farm", password_hash=hash_password("farmos123"),
                                role="manager", language="en"))
        session.commit()
        other = _h(client, "m@other.farm")
        assert client.get(f"{API}/nutrition/least-cost/{one['id']}", headers=other).status_code == 404
        assert client.post(f"{API}/nutrition/least-cost", headers=other, json=body).status_code == 404
        assert client.post(f"{API}/nutrition/least-cost/{one['id']}/approve", headers=other, json={"draft": "A", "note": "x"}).status_code == 404
        assert [x["id"] for x in client.get(f"{API}/nutrition/least-cost", headers=_h(client)).json()] == [one["id"]]
