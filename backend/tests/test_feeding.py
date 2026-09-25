"""The generic feed architecture (docs/GENERIC-FEED-ARCHITECTURE.md).

Organised by the acceptance criteria of §22 and §34: one feeding engine
for cows, goats, sheep, horses and poultry; purchased feed fed straight;
farm mixes as traceable batches; immutable formula history; group
inheritance with individual exceptions; lot-level traceability; policy,
reservation, reconciliation, days of cover and reorder alerts.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from tests.conftest import auth_headers

API = "/api/v1"
FARM = "farm-origami"
BELLA = "cow-744"          # lactating dairy cow, in the Dairy Herd, ~20.9 L/day
LUNA = "cow-214"           # lactating dairy cow, in the Dairy Herd, no milk records
THUNDER = "horse-h07"      # stallion
HERD = "grp-dairy-herd"
LAYERS = "flock-layer"
PREMIX = "fp-dairy-premix"
DAIRY_MIX = "fp-dairy-mix"
ALFALFA = "fp-alfalfa"
CONCENTRATE = "fp-dairy-concentrate"
BARLEY = "fp-barley"
LAYER_FEED = "fp-layer-feed"


def _h(client: TestClient) -> dict:
    return auth_headers(client)


def _availability(client: TestClient, product_id: str) -> dict:
    r = client.get(f"{API}/feed-products/{product_id}", headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()["availability"]


def _formula(client: TestClient, code: str = "DAIRY-MIX-24L") -> dict:
    r = client.get(f"{API}/feed-formulas", headers=_h(client))
    assert r.status_code == 200, r.text
    return next(f for f in r.json() if f["code"] == code)


def _resolve(client: TestClient, **state) -> dict:
    r = client.post(f"{API}/feeding-programs/resolve", json=state, headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()


def _plan(client: TestClient, subject_id: str) -> dict:
    r = client.get(f"{API}/livestock-subjects/{subject_id}/feeding-plan", headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()


def _premix_lot(client: TestClient) -> dict:
    r = client.get(f"{API}/feed-lots", params={"feed_product_id": PREMIX}, headers=_h(client))
    return next(l for l in r.json() if l["source_type"] == "purchased")


# --------------------------------------------------------------- products
class TestProductsAndLots:
    def test_inventory_items_became_feed_products_with_opening_lots(self, client: TestClient):
        r = client.get(f"{API}/feed-products", headers=_h(client))
        assert r.status_code == 200, r.text
        products = {p["code"]: p for p in r.json()}
        assert "DAIRY-MIX-24L" in products and "ALFALFA-HAY" in products
        # Stock is the ledger, not a second balance: the item's 3,250 kg is
        # the sum of its lots.
        mix = products["DAIRY-MIX-24L"]
        assert mix["availability"]["on_hand"] == 3250
        assert sum(l["quantity_on_hand"] for l in mix["availability"]["lots"]) == 3250
        assert mix["source_type"] == "farm_produced" and mix["has_active_formula"] is True
        # Medicine is inventory, not feed.
        assert not any(p["name"] == "Medicine" for p in r.json())

    def test_goods_receipt_keeps_received_accepted_and_rejected_apart(self, client: TestClient):
        before = _availability(client, BARLEY)["on_hand"]
        r = client.post(f"{API}/feed-lots/receive", headers=_h(client), json={
            "feed_product_id": BARLEY, "quantity": 500, "rejected_quantity": 20, "ordered_quantity": 500, "unit_cost": 0.38,
            "supplier_label": "Bekaa Hay Co.", "lot_code": "BAR-TEST-01", "reference": "PO-9001",
        })
        assert r.status_code == 201, r.text
        lot = r.json()
        assert (lot["ordered_quantity"], lot["received_quantity"], lot["accepted_quantity"], lot["rejected_quantity"]) == (500, 500, 480, 20)
        assert lot["quantity_on_hand"] == 480
        assert _availability(client, BARLEY)["on_hand"] == before + 480
        # The movement names its lot.
        moves = client.get(f"{API}/feed/transactions", params={"farm_id": FARM, "days": 1}, headers=_h(client)).json()
        assert any(m["lot_id"] == lot["id"] and m["direction"] == "in" and m["quantity"] == 480 for m in moves)

    def test_purchased_feed_is_fed_without_a_formula(self, client: TestClient):
        """§22: a purchased concentrate / hay is fed straight from its lot."""
        before = _availability(client, ALFALFA)
        r = client.post(f"{API}/feeding-events", headers=_h(client), json={
            "subject_type": "animal", "subject_id": THUNDER, "event_type": "offered",
            "components": [{"feed_product_id": ALFALFA, "quantity_offered": 5}],
        })
        assert r.status_code == 201, r.text
        event = r.json()
        assert event["components"][0]["lot_id"] is not None
        assert event["total_cost"] and event["total_cost"] > 0
        assert _availability(client, ALFALFA)["on_hand"] == before["on_hand"] - 5

    def test_quarantined_lot_cannot_be_issued(self, client: TestClient):
        lot = _premix_lot(client)
        r = client.patch(f"{API}/feed-lots/{lot['id']}/status", json={"status": "quarantined", "reason": "mould on the top bags"}, headers=_h(client))
        assert r.status_code == 200, r.text
        avail = _availability(client, PREMIX)
        assert avail["unusable"] == 490 and avail["available"] == 0
        # A batch that would draw on it is refused.
        formula = _formula(client)
        r = client.post(f"{API}/feed-batches", json={"formula_id": formula["id"], "target_quantity": 200}, headers=_h(client))
        assert r.status_code == 201, r.text
        r = client.post(f"{API}/feed-batches/{r.json()['id']}/complete", headers=_h(client), json={
            "actual_quantity": 200,
            "actuals": [{"feed_product_id": "fp-corn-silage", "actual_quantity": 76}, {"feed_product_id": ALFALFA, "actual_quantity": 44},
                        {"feed_product_id": CONCENTRATE, "actual_quantity": 70}, {"feed_product_id": BARLEY, "actual_quantity": 8},
                        {"feed_product_id": PREMIX, "actual_quantity": 2}],
        })
        assert r.status_code == 422, r.text
        assert "unusable" in r.json()["detail"] or "quarantined" in r.json()["detail"]

    def test_legacy_feed_transaction_endpoint_creates_lots(self, client: TestClient):
        before = len(client.get(f"{API}/feed-lots", params={"feed_product_id": DAIRY_MIX}, headers=_h(client)).json())
        r = client.post(f"{API}/feed/transactions", headers=_h(client), json={"item_id": "feed-dairy-mix", "direction": "in", "quantity": 100, "reason": "purchase"})
        assert r.status_code == 201, r.text
        assert r.json()["current_qty"] == 3350
        assert len(client.get(f"{API}/feed-lots", params={"feed_product_id": DAIRY_MIX}, headers=_h(client)).json()) == before + 1


# --------------------------------------------------------------- formulas
class TestFormulasAndBatches:
    def test_on_farm_mix_becomes_a_traceable_batch_and_lot(self, client: TestClient):
        """§22: ingredients out of their lots, a new lot in, at real cost."""
        formula = _formula(client)
        mix_before = _availability(client, DAIRY_MIX)["on_hand"]
        premix_before = _availability(client, PREMIX)["on_hand"]
        r = client.post(f"{API}/feed-batches", json={"formula_id": formula["id"], "target_quantity": 500, "batch_code": "MIX-TEST"}, headers=_h(client))
        assert r.status_code == 201, r.text
        batch = r.json()
        assert batch["status"] == "in_progress" and batch["formula_version"] == formula["active_version"]
        targets = {c["feed_product_id"]: c["target_quantity"] for c in batch["components"]}
        assert targets["fp-corn-silage"] == 190 and targets[PREMIX] == 5
        r = client.post(f"{API}/feed-batches/{batch['id']}/complete", headers=_h(client), json={
            "actual_quantity": 500,
            "actuals": [{"feed_product_id": "fp-corn-silage", "actual_quantity": 188}, {"feed_product_id": ALFALFA, "actual_quantity": 112},
                        {"feed_product_id": CONCENTRATE, "actual_quantity": 175}, {"feed_product_id": BARLEY, "actual_quantity": 20},
                        {"feed_product_id": PREMIX, "actual_quantity": 5}],
        })
        assert r.status_code == 200, r.text
        done = r.json()
        assert done["status"] == "completed" and done["output_lot_id"]
        assert done["actual_cost"] and done["unit_cost"] and abs(done["unit_cost"] - done["actual_cost"] / 500) < 1e-6
        variance = {v["feed_product_id"]: v for v in done["variance"]}
        assert variance["fp-corn-silage"]["variance"] == -2 and variance[ALFALFA]["variance"] == 2
        assert _availability(client, DAIRY_MIX)["on_hand"] == mix_before + 500
        assert _availability(client, PREMIX)["on_hand"] == premix_before - 5
        # Forward trace from the premix lot reaches this batch; backward
        # trace from the output lot names the premix lot.
        premix_lot = _premix_lot(client)
        trace = client.get(f"{API}/feed-lots/{premix_lot['id']}/trace", headers=_h(client)).json()
        assert any(b["batch_code"] == "MIX-TEST" for b in trace["downstream_batches"])
        out_trace = client.get(f"{API}/feed-lots/{done['output_lot_id']}/trace", headers=_h(client)).json()
        assert any(u["lot_id"] == premix_lot["id"] for u in out_trace["upstream_ingredient_lots"])

    def test_formula_revision_preserves_historical_batches(self, client: TestClient):
        """§6, §16: v1 made a batch and is locked; v3 becomes active; the old
        batch still resolves to v1."""
        formula = _formula(client)
        v1 = next(v for v in formula["versions"] if v["version"] == 1)
        assert v1["status"] == "retired" and v1["locked"] is True
        assert formula["active_version"] == 2
        r = client.post(f"{API}/feed-formulas/{formula['id']}/versions", headers=_h(client), json={
            "batch_size": 1000, "components": [
                {"feed_product_id": "fp-corn-silage", "target_quantity": 360}, {"feed_product_id": ALFALFA, "target_quantity": 240},
                {"feed_product_id": CONCENTRATE, "target_quantity": 350}, {"feed_product_id": BARLEY, "target_quantity": 40},
                {"feed_product_id": PREMIX, "target_quantity": 10}],
            "notes": "Winter hay.",
        })
        assert r.status_code == 201, r.text
        assert r.json()["version"] == 3 and r.json()["status"] == "active"
        again = _formula(client)
        assert again["active_version"] == 3
        assert next(v for v in again["versions"] if v["version"] == 2)["status"] == "retired"
        batches = client.get(f"{API}/feed-batches", headers=_h(client)).json()
        old = next(b for b in batches if b["batch_code"] == "MIX-2609-01")
        assert old["formula_version"] == 1 and old["formula_version_id"] == v1["id"]

    def test_horse_formula_cannot_use_cattle_only_premix(self, client: TestClient):
        """§34: refused before any inventory moves."""
        r = client.post(f"{API}/feed-products", headers=_h(client), json={
            "name": "Horse Mix", "source_type": "farm_produced", "is_ingredient": False, "is_feedable": True, "category": "complete_feed",
        })
        assert r.status_code == 201, r.text
        horse_mix = r.json()["id"]
        premix_before = _availability(client, PREMIX)["on_hand"]
        r = client.post(f"{API}/feed-formulas", headers=_h(client), json={
            "name": "Horse Mix", "feed_product_id": horse_mix, "species_code": "horse", "batch_size": 100,
            "components": [{"feed_product_id": ALFALFA, "target_quantity": 80}, {"feed_product_id": BARLEY, "target_quantity": 19},
                           {"feed_product_id": PREMIX, "target_quantity": 1}],
        })
        assert r.status_code == 422, r.text
        assert "horse" in r.json()["detail"].lower() and "Premix" in r.json()["detail"]
        assert _availability(client, PREMIX)["on_hand"] == premix_before
        # Without the premix the horse formula is fine.
        r = client.post(f"{API}/feed-formulas", headers=_h(client), json={
            "name": "Horse Mix", "feed_product_id": horse_mix, "species_code": "horse", "batch_size": 100,
            "components": [{"feed_product_id": ALFALFA, "target_quantity": 80}, {"feed_product_id": BARLEY, "target_quantity": 20}],
        })
        assert r.status_code == 201, r.text

    def test_inclusion_cap_is_enforced(self, client: TestClient):
        formula = _formula(client)
        r = client.post(f"{API}/feed-formulas/{formula['id']}/versions", headers=_h(client), json={
            "batch_size": 1000, "components": [
                {"feed_product_id": "fp-corn-silage", "target_quantity": 400}, {"feed_product_id": ALFALFA, "target_quantity": 200},
                {"feed_product_id": CONCENTRATE, "target_quantity": 350}, {"feed_product_id": PREMIX, "target_quantity": 50}],
        })
        assert r.status_code == 422, r.text
        assert "maximum inclusion" in r.json()["detail"]

    def test_formula_nutrients_are_a_weighted_average_with_coverage(self, client: TestClient):
        formula = _formula(client)
        r = client.get(f"{API}/feed-formulas/{formula['id']}/versions/2/nutrients", headers=_h(client))
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["coverage_pct"] == 100 and body["source_type"] == "calculated"
        cp = next(v for v in body["values"] if v["nutrient_code"] == "CP")
        assert 8 < cp["value"] < 18

    def test_lab_analysis_sits_beside_the_declared_profile(self, client: TestClient):
        r = client.get(f"{API}/feed-nutrient-profiles", params={"subject_type": "feed_product", "subject_id": ALFALFA}, headers=_h(client))
        assert r.status_code == 200, r.text
        sources = {p["source_type"] for p in r.json()}
        assert sources == {"declared", "lab"}


# --------------------------------------------------------------- resolver
class TestResolver:
    def test_lactating_and_dry_cows_get_different_programs_from_one_engine(self, client: TestClient):
        high = _resolve(client, species_code="cow", sex="F", management_profile="dairy", lactation_state="lactating", production={"milk_l_per_day": 25})
        assert high["best"]["program_code"] == "DAIRY-HIGH"
        assert any("milk" in r for r in high["best"]["reasons"])
        medium = _resolve(client, species_code="cow", sex="F", management_profile="dairy", lactation_state="lactating", production={"milk_l_per_day": 15})
        assert medium["best"]["program_code"] == "DAIRY-MEDIUM"
        dry = _resolve(client, species_code="cow", sex="F", management_profile="dairy", lactation_state="dry")
        assert dry["best"]["program_code"] == "DRY-COW"

    def test_calves_and_bulls(self, client: TestClient):
        assert _resolve(client, species_code="cow", life_stage="young")["best"]["program_code"] == "CALF-STARTER"
        assert _resolve(client, species_code="cow", sex="M")["best"]["program_code"] == "BREEDING-BULL"

    def test_horses_use_the_same_engine(self, client: TestClient):
        assert _resolve(client, species_code="horse", sex="F", reproductive_state="pregnant")["best"]["program_code"] == "MARE-PREGNANT"
        assert _resolve(client, species_code="horse", sex="F", lactation_state="lactating")["best"]["program_code"] == "MARE-LACTATING"
        assert _resolve(client, species_code="horse", life_stage="young")["best"]["program_code"] == "HORSE-GROWTH"
        assert _resolve(client, species_code="horse", sex="M")["best"]["program_code"] == "HORSE-MAINTENANCE"

    def test_layer_and_broiler_poultry(self, client: TestClient):
        assert _resolve(client, species_code="layer_hen", management_profile="layer")["best"]["program_code"] == "LAYER"
        assert _resolve(client, species_code="duck", management_profile="broiler")["best"]["program_code"] == "BROILER-GROWER"

    def test_unknown_production_is_a_warning_not_a_silent_match(self, client: TestClient):
        res = _resolve(client, species_code="cow", sex="F", management_profile="dairy", lactation_state="lactating")
        assert res["best"]["program_code"] == "DAIRY-LACTATING"
        assert any("unknown" in w for w in res["warnings"])
        codes = {e["program_code"] for e in res["eligible"]}
        assert "DAIRY-HIGH" not in codes

    def test_a_new_program_is_configuration_only(self, client: TestClient):
        r = client.post(f"{API}/feeding-programs", headers=_h(client), json={
            "name": "Ram maintenance", "components": [{"feed_product_id": ALFALFA, "quantity_per_head": 2.2}],
            "rules": [{"species_code": "sheep", "sex": "M", "priority": 5}],
        })
        assert r.status_code == 201, r.text
        assert _resolve(client, species_code="sheep", sex="M")["best"]["program_code"] == "RAM-MAINTENANCE"

    def test_a_program_whose_ration_is_prohibited_for_its_species_cannot_activate(self, client: TestClient):
        r = client.post(f"{API}/feeding-programs", headers=_h(client), json={
            "name": "Horse premix", "components": [{"feed_product_id": PREMIX, "quantity_per_head": 0.1}],
            "rules": [{"species_code": "horse"}],
        })
        assert r.status_code == 422, r.text


# ------------------------------------------------------------ assignments
class TestInheritanceAndExceptions:
    def test_a_cow_inherits_the_herd_program_and_keeps_her_supplement(self, client: TestClient):
        plan = _plan(client, BELLA)
        assert plan["program"]["source"] == "inherited"
        assert plan["program"]["inherited_from"]["group_id"] == HERD
        assert plan["program"]["program_code"] == "DAIRY-HIGH"
        supplement = next(s for s in plan["supplements"] if s["feed_product_id"] == CONCENTRATE)
        assert supplement["daily_per_head"] == 2
        conc = next(t for t in plan["daily_targets"] if t["feed_product_id"] == CONCENTRATE)
        assert conc["daily_total"] == 6 + 2
        assert plan["review"]["required"] is False

    def test_an_override_never_erases_the_group_program(self, client: TestClient):
        r = client.post(f"{API}/livestock-subjects/{LUNA}/feeding-assignments", headers=_h(client), json={
            "assignment_type": "override", "feed_product_id": ALFALFA, "quantity_per_head": 4, "reason": "Body condition — less hay for 2 weeks",
        })
        assert r.status_code == 201, r.text
        plan = _plan(client, LUNA)
        assert plan["program"]["source"] == "inherited"
        hay = next(c for c in plan["components"] if c["feed_product_id"] == ALFALFA)
        assert hay["daily_per_head"] == 4 and hay["note"] and "override" in hay["note"]
        r = client.delete(f"{API}/livestock-subjects/{LUNA}/feeding-assignments/{r.json()['id']}", headers=_h(client))
        assert r.status_code == 200, r.text
        hay = next(c for c in _plan(client, LUNA)["components"] if c["feed_product_id"] == ALFALFA)
        assert hay["daily_per_head"] == 6

    def test_a_restriction_blocks_the_feed(self, client: TestClient):
        r = client.post(f"{API}/livestock-subjects/{BELLA}/feeding-assignments", headers=_h(client), json={
            "assignment_type": "restriction", "feed_product_id": CONCENTRATE, "reason": "Vet: acidosis, no concentrate",
        })
        assert r.status_code == 201, r.text
        plan = _plan(client, BELLA)
        assert all(t["feed_product_id"] != CONCENTRATE for t in plan["daily_targets"])
        r = client.post(f"{API}/feeding-events", headers=_h(client), json={
            "subject_type": "animal", "subject_id": BELLA, "components": [{"feed_product_id": CONCENTRATE, "quantity_offered": 1}],
        })
        assert r.status_code == 422 and "restricted" in r.json()["detail"], r.text

    def test_an_explicit_assignment_is_distinguishable_from_inheritance(self, client: TestClient):
        r = client.post(f"{API}/livestock-subjects/{BELLA}/feeding-assignments", headers=_h(client), json={"program_id": "prog-dairy-medium"})
        assert r.status_code == 201, r.text
        plan = _plan(client, BELLA)
        assert plan["program"]["source"] == "explicit" and plan["program"]["program_code"] == "DAIRY-MEDIUM"
        rows = client.get(f"{API}/livestock-subjects/{BELLA}/feeding-assignments", headers=_h(client)).json()
        assert [a["assignment_type"] for a in rows].count("explicit") == 1

    def test_activating_a_new_program_version_moves_its_subjects(self, client: TestClient):
        r = client.post(f"{API}/feeding-programs/prog-dairy-high/versions", headers=_h(client), json={
            "components": [{"feed_product_id": DAIRY_MIX, "quantity_per_head": 11, "frequency": "per_feeding"},
                           {"feed_product_id": ALFALFA, "quantity_per_head": 3, "frequency": "per_feeding"},
                           {"feed_product_id": CONCENTRATE, "quantity_per_head": 3, "frequency": "per_feeding"}],
            "rules": [{"species_code": "cow", "sex": "F", "life_stage": "adult", "management_profile": "dairy", "lactation_state": "lactating",
                       "production_metric": "milk_l_per_day", "production_min": 20, "priority": 10}],
        })
        assert r.status_code == 201, r.text
        plan = _plan(client, HERD)
        assert plan["program"]["version"] == 2
        mix = next(c for c in plan["components"] if c["feed_product_id"] == DAIRY_MIX)
        assert mix["daily_per_head"] == 22


# ----------------------------------------------------------------- events
class TestFeedingEvents:
    def test_group_feeding_is_one_event_with_a_head_count_and_a_cost(self, client: TestClient):
        r = client.post(f"{API}/feeding-events", headers=_h(client), json={
            "subject_type": "group", "subject_id": HERD, "event_type": "delivered",
            "components": [{"feed_product_id": DAIRY_MIX, "quantity_offered": 30}, {"feed_product_id": ALFALFA, "quantity_offered": 9},
                           {"feed_product_id": CONCENTRATE, "quantity_offered": 9}],
        })
        assert r.status_code == 201, r.text
        event = r.json()
        assert event["head_count"] == 3 and event["total_cost"] > 0
        assert event["program_version_id"] is not None
        history = client.get(f"{API}/livestock-subjects/{HERD}/feeding-history", headers=_h(client)).json()
        assert history[0]["id"] == event["id"]
        costs = client.get(f"{API}/feed-costs", params={"days": 30}, headers=_h(client)).json()
        assert any(s["subject_id"] == HERD and s["cost"] > 0 for s in costs["by_subject"])
        assert costs["batch_cost_total"] > 0

    def test_a_feeding_traces_back_to_its_lots_and_forward_to_the_animals(self, client: TestClient):
        """§12 both ways."""
        r = client.post(f"{API}/feeding-events", headers=_h(client), json={
            "subject_type": "animal", "subject_id": THUNDER, "components": [{"feed_product_id": BARLEY, "quantity_offered": 2}],
        })
        assert r.status_code == 201, r.text
        lot_id = r.json()["components"][0]["lot_id"]
        assert lot_id
        trace = client.get(f"{API}/feed-lots/{lot_id}/trace", headers=_h(client)).json()
        exposed = {(e["subject_type"], e["subject_id"]) for e in trace["exposed_subjects"]}
        assert ("animal", THUNDER) in exposed
        assert trace["lot"]["supplier_label"] == "Bekaa Hay Co."

    def test_a_reversal_restores_the_lots_and_keeps_the_original(self, client: TestClient):
        before = _availability(client, BARLEY)["on_hand"]
        r = client.post(f"{API}/feeding-events", headers=_h(client), json={
            "subject_type": "animal", "subject_id": THUNDER, "components": [{"feed_product_id": BARLEY, "quantity_offered": 3}],
        })
        event_id = r.json()["id"]
        assert _availability(client, BARLEY)["on_hand"] == before - 3
        r = client.post(f"{API}/feeding-events/{event_id}/reverse", json={"reason": "Wrong horse"}, headers=_h(client))
        assert r.status_code == 201, r.text
        assert r.json()["status"] == "reversal" and r.json()["reversal_of_id"] == event_id
        assert _availability(client, BARLEY)["on_hand"] == before
        history = client.get(f"{API}/livestock-subjects/{THUNDER}/feeding-history", headers=_h(client)).json()
        assert {e["status"] for e in history if e["id"] == event_id} == {"reversed"}

    def test_missing_consumption_is_null_not_zero(self, client: TestClient):
        r = client.post(f"{API}/feeding-events", headers=_h(client), json={
            "subject_type": "animal", "subject_id": THUNDER, "components": [{"feed_product_id": ALFALFA, "quantity_offered": 4}],
        })
        assert r.json()["components"][0]["quantity_consumed"] is None
        r = client.post(f"{API}/feeding-events", headers=_h(client), json={
            "subject_type": "animal", "subject_id": THUNDER, "event_type": "consumed_estimate",
            "components": [{"feed_product_id": ALFALFA, "quantity_offered": 4, "quantity_consumed": 3.5}],
        })
        assert r.status_code == 201 and r.json()["components"][0]["quantity_consumed"] == 3.5

    def test_direct_feeding_of_a_prohibited_feed_is_blocked(self, client: TestClient):
        """§34: the premix never reaches a horse."""
        r = client.post(f"{API}/feeding-events", headers=_h(client), json={
            "subject_type": "animal", "subject_id": THUNDER, "components": [{"feed_product_id": PREMIX, "quantity_offered": 0.5}],
        })
        assert r.status_code == 422, r.text
        assert "horse" in r.json()["detail"].lower()

    def test_a_premix_that_needs_a_formula_is_not_fed_directly_even_to_a_cow(self, client: TestClient):
        r = client.post(f"{API}/feeding-events", headers=_h(client), json={
            "subject_type": "animal", "subject_id": BELLA, "components": [{"feed_product_id": PREMIX, "quantity_offered": 0.1}],
        })
        assert r.status_code == 422 and "approved formula" in r.json()["detail"], r.text


# --------------------------------------------------------------- lifecycle
class TestLifecycleReview:
    def _review_tasks(self, client: TestClient, subject_id: str) -> list[dict]:
        tasks = client.get(f"{API}/tasks", params={"farm_id": FARM}, headers=_h(client)).json()
        return [t for t in tasks if t.get("source_type") == "feeding_review" and t.get("source_id") == subject_id]

    def test_dry_off_raises_a_review_and_changes_nothing_by_itself(self, client: TestClient):
        """§10: an event triggers a review task; the assignment stays."""
        r = client.put(f"{API}/animals/{LUNA}", json={"lactating": False}, headers=_h(client))
        assert r.status_code == 200, r.text
        tasks = self._review_tasks(client, LUNA)
        assert len(tasks) == 1 and "Luna" in tasks[0]["title"]
        assert "DRY" in tasks[0]["description"].upper() or "Dry cow" in tasks[0]["description"]
        plan = _plan(client, LUNA)
        assert plan["program"]["program_code"] == "DAIRY-HIGH" and plan["program"]["source"] == "inherited"
        assert plan["review"]["required"] is True and plan["review"]["recommended"]["program_code"] == "DRY-COW"
        # A second state change while the review is open does not add a task.
        client.put(f"{API}/animals/{LUNA}", json={"pregnant": True}, headers=_h(client))
        assert len(self._review_tasks(client, LUNA)) == 1
        # Acting on it — an explicit assignment — closes the review.
        r = client.post(f"{API}/livestock-subjects/{LUNA}/feeding-assignments", json={"program_id": "prog-dry-cow"}, headers=_h(client))
        assert r.status_code == 201, r.text
        assert all(t["status"] == "done" for t in self._review_tasks(client, LUNA))

    def test_a_milk_record_across_a_band_reviews_once(self, client: TestClient):
        """A new cow in the herd inherits the high-production ration with no
        yield data; her first 9 L day puts her below every band → review.
        A second record the same day (18 L → medium band) changes the
        recommendation but adds no second task."""
        r = client.post(f"{API}/animals", headers=_h(client), json={
            "name": "Noor", "species": "cow", "sex": "F", "life_stage": "adult", "management_profile": "dairy", "lactating": True,
            "group_name": "Dairy Herd", "identifiers": [{"identifier_type": "EAR_TAG", "identifier_value": "T-901", "is_primary": True}],
        })
        assert r.status_code == 201, r.text
        noor = r.json()["id"]
        assert _plan(client, noor)["program"]["source"] == "inherited"
        r = client.post(f"{API}/production/milk", headers=_h(client), json={"animal_id": noor, "session": "morning", "liters": 9, "destination": "stored"})
        assert r.status_code == 201, r.text
        tasks = self._review_tasks(client, noor)
        assert len(tasks) == 1 and "production band" in tasks[0]["description"].lower()
        r = client.post(f"{API}/production/milk", headers=_h(client), json={"animal_id": noor, "session": "evening", "liters": 9, "destination": "stored"})
        assert r.status_code == 201, r.text
        assert len(self._review_tasks(client, noor)) == 1
        assert _plan(client, noor)["review"]["recommended"]["program_code"] == "DAIRY-MEDIUM"

    def test_a_group_change_is_accepted_and_reviewed(self, client: TestClient):
        r = client.patch(f"{API}/animal-groups/{HERD}", json={"count": 4}, headers=_h(client))
        assert r.status_code == 200, r.text


# ---------------------------------------------------- policy & reservation
class TestPolicyAndAllocation:
    def test_availability_excludes_reserved_stock(self, client: TestClient):
        avail = _availability(client, PREMIX)
        assert (avail["on_hand"], avail["reserved"], avail["available"]) == (490, 400, 90)

    def test_reserved_stock_cannot_be_used_for_another_purpose(self, client: TestClient):
        r = client.post(f"{API}/feed/transactions", headers=_h(client), json={"item_id": "feed-dairy-premix", "direction": "out", "quantity": 200, "reason": "transfer"})
        assert r.status_code == 422, r.text
        assert "reserved" in r.json()["detail"]
        r = client.post(f"{API}/feed/transactions", headers=_h(client), json={"item_id": "feed-dairy-premix", "direction": "out", "quantity": 50, "reason": "transfer"})
        assert r.status_code == 201, r.text
        assert _availability(client, PREMIX)["available"] == 40

    def test_a_batch_for_the_reserved_purpose_draws_on_the_reservation(self, client: TestClient):
        # A cow-formula batch is the purpose the premix was reserved for (species cow).
        formula = _formula(client)
        r = client.post(f"{API}/feed-batches", json={"formula_id": formula["id"], "target_quantity": 1000}, headers=_h(client))
        r = client.post(f"{API}/feed-batches/{r.json()['id']}/complete", headers=_h(client), json={
            "actual_quantity": 1000,
            "actuals": [{"feed_product_id": "fp-corn-silage", "actual_quantity": 380}, {"feed_product_id": ALFALFA, "actual_quantity": 220},
                        {"feed_product_id": CONCENTRATE, "actual_quantity": 350}, {"feed_product_id": BARLEY, "actual_quantity": 40},
                        {"feed_product_id": PREMIX, "actual_quantity": 10}],
        })
        # Mixing is not a species-purposed issue; it draws the 10 kg from the
        # unreserved 90 kg, leaving the herd's 400 kg untouched.
        assert r.status_code == 200, r.text
        avail = _availability(client, PREMIX)
        assert (avail["on_hand"], avail["reserved"], avail["available"]) == (480, 400, 80)

    def test_cross_species_transfer_of_a_restricted_allocation_is_refused(self, client: TestClient):
        alloc = client.get(f"{API}/feed-allocations", params={"feed_product_id": PREMIX}, headers=_h(client)).json()[0]
        r = client.post(f"{API}/feed-allocations/{alloc['id']}/transfer", json={"quantity": 50, "species_code": "horse"}, headers=_h(client))
        assert r.status_code == 422 and "Cross-species" in r.json()["detail"], r.text
        # Within the species, an approver may move part of it to one animal.
        r = client.post(f"{API}/feed-allocations/{alloc['id']}/transfer", json={"quantity": 50, "species_code": "cow", "subject_type": "animal", "subject_id": BELLA}, headers=_h(client))
        assert r.status_code == 201, r.text
        assert r.json()["allocated_quantity"] == 50 and r.json()["subject_id"] == BELLA
        assert _availability(client, PREMIX)["reserved"] == 400

    def test_policy_validation_explains_itself(self, client: TestClient):
        r = client.post(f"{API}/feed-products/{PREMIX}/usage-policy/validate", json={"species_code": "horse"}, headers=_h(client))
        assert r.status_code == 200 and r.json()["allowed"] is False
        assert any("horse" in reason for reason in r.json()["reasons"])
        r = client.post(f"{API}/feed-products/{PREMIX}/usage-policy/validate", json={"species_code": "cow", "management_profile": "dairy", "through_formula": True, "inclusion_pct": 1.0}, headers=_h(client))
        assert r.json()["allowed"] is True and r.json()["max_inclusion_pct"] == 1.5

    def test_a_lot_policy_cannot_broaden_the_product_policy(self, client: TestClient):
        lot = _premix_lot(client)
        r = client.put(f"{API}/feed-products/{PREMIX}/usage-policy", headers=_h(client), json={
            "name": "Lot exception", "lot_id": lot["id"], "rules": [{"effect": "allow", "species_code": "horse"}],
        })
        assert r.status_code == 422, r.text


# --------------------------------------------- forecast, reorder, reconcile
class TestForecastAndReconciliation:
    def test_days_of_cover_uses_eligible_stock_and_program_demand(self, client: TestClient):
        rows = {r["code"]: r for r in client.get(f"{API}/feed-inventory/days-of-cover", headers=_h(client)).json()}
        layer = rows["LAYER-FEED"]
        assert layer["demand_source"] == "programs" and layer["daily_demand"] > 250
        assert layer["days_of_cover"] < layer["lead_time_days"] + 3
        assert layer["status"] == "stockout_risk" and layer["projected_stockout_at"]
        premix = rows["CATTLE-DAIRY-PREMIX"]
        assert premix["available"] == 90 and premix["status"] == "reorder"
        assert list(premix["demand_by_species"]) == ["cow"]

    def test_reorder_notification_names_the_livestock_at_risk_and_is_suppressed_once_acknowledged(self, client: TestClient):
        """§29, §34."""
        recs = {r["code"]: r for r in client.get(f"{API}/feed-inventory/reorder-recommendations", headers=_h(client)).json()}
        assert "LAYER-FEED" in recs and "Layer ration" in recs["LAYER-FEED"]["programs_affected"]
        assert recs["LAYER-FEED"]["suggested_reorder_quantity"] > 0
        bell = client.get(f"{API}/notifications", headers=_h(client)).json()["notifications"]
        alert = next(n for n in bell if n["notification_type"] == "feed_reorder_required" and n["entity_id"] == LAYER_FEED)
        assert "days of cover" in alert["description"] and "lead time" in alert["description"]
        r = client.post(f"{API}/feed-inventory/reorder-recommendations/{LAYER_FEED}/acknowledge", json={"note": "Order 3 t from Al Mashreq"}, headers=_h(client))
        assert r.status_code == 201, r.text
        task_id = r.json()["task_id"]
        recs = {r["code"]: r for r in client.get(f"{API}/feed-inventory/reorder-recommendations", headers=_h(client)).json()}
        assert recs["LAYER-FEED"]["covered_by_task_id"] == task_id
        bell = client.get(f"{API}/notifications", headers=_h(client)).json()["notifications"]
        assert not any(n["notification_type"] == "feed_reorder_required" and n["entity_id"] == LAYER_FEED for n in bell)
        tasks = client.get(f"{API}/tasks", params={"farm_id": FARM}, headers=_h(client)).json()
        assert any(t["id"] == task_id and t["source_type"] == "feed_reorder" for t in tasks)

    def test_forecast_projects_the_requirement_over_the_horizon(self, client: TestClient):
        rows = {r["code"]: r for r in client.get(f"{API}/feed-inventory/forecast", params={"horizon_days": 14}, headers=_h(client)).json()}
        layer = rows["LAYER-FEED"]
        assert layer["forecast_quantity"] > layer["available"]
        assert layer["projected_requirement"] > 0 and layer["suggested_reorder_quantity"] >= layer["projected_requirement"]

    def test_unexplained_variance_is_visible_and_closes_only_with_an_explained_adjustment(self, client: TestClient):
        """§27, §34: 25 kg short of the ledger is a variance, not waste."""
        recs = client.get(f"{API}/feed-reconciliations", headers=_h(client)).json()
        rec = next(r for r in recs if r["feed_product_id"] == PREMIX)
        assert rec["status"] == "open" and rec["variance_quantity"] == -25
        assert rec["issued_to_batches"] == 10 and rec["received_quantity"] == 500
        bell = client.get(f"{API}/notifications", headers=_h(client)).json()["notifications"]
        assert any(n["notification_type"] == "feed_variance" and n["entity_id"] == rec["id"] for n in bell)
        on_hand = _availability(client, PREMIX)["on_hand"]
        r = client.post(f"{API}/feed-reconciliations/{rec['id']}/close", json={"post_adjustment": True, "explanation": "Two torn bags found behind the mixer, swept out."}, headers=_h(client))
        assert r.status_code == 200 and r.json()["status"] == "closed", r.text
        assert _availability(client, PREMIX)["on_hand"] == on_hand - 25
        moves = client.get(f"{API}/feed/transactions", params={"farm_id": FARM, "days": 1}, headers=_h(client)).json()
        assert any(m["reason"] == "reconciliation_adjustment" and m["quantity"] == 25 for m in moves)

    def test_an_adjustment_without_an_explanation_is_refused(self, client: TestClient):
        r = client.post(f"{API}/feed-inventory/adjustments", json={"feed_product_id": BARLEY, "delta": -5, "reason": "waste", "explanation": " "}, headers=_h(client))
        assert r.status_code == 422, r.text
        r = client.post(f"{API}/feed-inventory/adjustments", json={"feed_product_id": BARLEY, "delta": -5, "reason": "waste", "explanation": "Rain got into the last bag."}, headers=_h(client))
        assert r.status_code == 201, r.text

    def test_a_new_reconciliation_accounts_for_every_kilogram(self, client: TestClient):
        now = datetime.now(timezone.utc)
        r = client.post(f"{API}/feed-reconciliations", headers=_h(client), json={
            "feed_product_id": CONCENTRATE, "period_from": (now - timedelta(days=30)).isoformat(), "period_to": now.isoformat(),
            "counted_closing_quantity": 1534,
        })
        assert r.status_code == 201, r.text
        rec = r.json()
        assert rec["received_quantity"] == 2000 and rec["issued_to_batches"] == 347
        assert rec["expected_closing_quantity"] == 1534 and rec["variance_quantity"] == 0
