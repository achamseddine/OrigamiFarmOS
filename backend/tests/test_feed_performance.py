"""Feed Performance Intelligence (database/FEED-PERFORMANCE-INTELLIGENCE.md).

The deterministic first increment: exposure windows with lineage, explicit
baselines, explained assessments with a likelihood and a confidence,
deduplicated alerts that acknowledge without resolving and resolve when
the evidence clears, mix and supplier scores, and the hooks that keep it
current. Nothing here writes a feed, stock, production or health fact.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.domain import models
from app.repositories.base import new_id
from tests.conftest import auth_headers

API = "/api/v1"
HERD = "grp-dairy-herd"
LAYERS = "flock-layer"
CLOVER = "cow-clover"      # steady milker in the Dairy Herd
GIGI = "goat-gigi"         # lactating Saanen goat, healthy, no milk records in the seed
GOAT_MIX = "fp-goat-mix"
DAIRY_MIX = "fp-dairy-mix"


def _h(client: TestClient) -> dict:
    return auth_headers(client)


def _now() -> datetime:
    return datetime.now(timezone.utc).replace(hour=7, minute=0, second=0, microsecond=0)


def _evaluate(client: TestClient, **params) -> dict:
    r = client.post(f"{API}/feed-performance/evaluate", params=params, headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()


def _alerts(client: TestClient, status: str = "open") -> list[dict]:
    r = client.get(f"{API}/feed-performance/alerts", params={"status": status}, headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()


def _complete_second_mix(client: TestClient, bump: float = 1.0) -> dict:
    """Completes the seeded in-progress mix (MIX-000002). `bump` scales the
    largest component's actual, so the mix can be made to deviate from its
    formula on purpose."""
    batches_ = client.get(f"{API}/feed-batches", headers=_h(client)).json()
    open_batch = next(b for b in batches_ if b["status"] == "in_progress")
    biggest = max(open_batch["components"], key=lambda c: c["target_quantity"])["feed_product_id"]
    actuals = [{"feed_product_id": c["feed_product_id"], "actual_quantity": round(c["target_quantity"] * (bump if c["feed_product_id"] == biggest else 1), 2)}
               for c in open_batch["components"]]
    r = client.post(f"{API}/feed-batches/{open_batch['id']}/complete", json={"actual_quantity": 800, "actuals": actuals}, headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()


def _milk(db, animal_id: str, liters_by_day_offset: dict[int, float]) -> None:
    """Authoring test facts straight into the production table, the way the
    seed does: `offset` days from today (negative = past, positive = future)."""
    for offset, liters in liters_by_day_offset.items():
        db.add(models.MilkRecord(id=new_id(), animal_id=animal_id, session="morning", liters=liters, destination="stored",
                                 recorded_at=_now() + timedelta(days=offset), recorded_by="user-worker-1"))
    db.commit()


def _feed(client: TestClient, subject_type: str, subject_id: str, product_id: str, qty: float, days_ago: int, event_type: str = "delivered", lot_id: str | None = None) -> dict:
    comp = {"feed_product_id": product_id, "quantity_offered": qty}
    if lot_id:
        comp["lot_id"] = lot_id
    r = client.post(f"{API}/feeding-events", json={"subject_type": subject_type, "subject_id": subject_id, "event_type": event_type,
                                                  "occurred_at": (_now() - timedelta(days=days_ago)).isoformat(), "components": [comp]}, headers=_h(client))
    assert r.status_code == 201, r.text
    return r.json()


# ----------------------------------------------------------------- exposure
class TestExposure:
    def test_an_exposure_window_carries_the_mix_and_its_ingredient_lots(self, client: TestClient):
        done = _complete_second_mix(client)
        assert done["output_lot_code"] == "MIX-000002"
        _feed(client, "group", HERD, DAIRY_MIX, 30, days_ago=0, lot_id=done["output_lot_id"])
        _evaluate(client)

        r = client.get(f"{API}/feed-performance/exposures", params={"subject_type": "group", "subject_id": HERD}, headers=_h(client))
        assert r.status_code == 200, r.text
        window = next(w for w in r.json() if w["lot_id"] == done["output_lot_id"])
        assert window["feed_batch_id"] == done["id"] and window["feeding_event_count"] == 1 and window["offered_quantity"] == 30
        assert window["exposure_end"] is None, "fed today, so the exposure is ongoing"
        lineage = window["lineage"]
        assert lineage["mix"]["mix_code"] == "MIX-000002" and lineage["mix"]["mix_number"] == 2
        assert lineage["source_type"] == "farm_produced"
        ingredients = lineage["ingredient_lots"]
        assert len(ingredients) == 5 and all(i["lot_code"] for i in ingredients)
        premix = next(i for i in ingredients if i["product_name"] == "Cattle Dairy Premix")
        assert premix["supplier_label"] == "NutriPlus", "the purchased ingredient keeps its supplier through the mix"

    def test_the_projection_is_rebuilt_from_the_events_not_edited(self, client: TestClient):
        before = client.get(f"{API}/feed-performance/exposures", params={"subject_type": "group", "subject_id": HERD}, headers=_h(client)).json()
        ids_before = {w["id"] for w in before}
        _evaluate(client)
        after = client.get(f"{API}/feed-performance/exposures", params={"subject_type": "group", "subject_id": HERD}, headers=_h(client)).json()
        assert len(after) == len(before) and ids_before.isdisjoint({w["id"] for w in after})
        assert {(w["feed_product_id"], w["lot_id"], w["feeding_event_count"]) for w in after} == {(w["feed_product_id"], w["lot_id"], w["feeding_event_count"]) for w in before}


# -------------------------------------------------------------- assessments
class TestAssessments:
    def test_a_persistent_decline_after_a_feed_change_is_explained_alerted_acknowledged_and_recovers(self, client: TestClient, db_session):
        db, _ = db_session
        # Seven steady days, then a goat mix is introduced and milk drops a fifth for three days.
        _milk(db, GIGI, {-d: 3.0 for d in range(3, 10)})
        _milk(db, GIGI, {-2: 2.4, -1: 2.3, 0: 2.5})
        for d in (4, 3, 2, 1, 0):
            _feed(client, "animal", GIGI, GOAT_MIX, 1.2, days_ago=d)

        r = client.post(f"{API}/feed-performance/monitors", json={"subject_type": "animal", "subject_id": GIGI, "production_metric_code": "milk_l_per_day"}, headers=_h(client))
        assert r.status_code == 201, r.text
        monitor = r.json()
        assert monitor["baseline_method_code"] == "rolling_subject" and monitor["latest_assessment"] is None

        r = client.post(f"{API}/feed-performance/monitors/{monitor['id']}/evaluate", headers=_h(client))
        assert r.status_code == 200, r.text
        a = r.json()
        assert a["status"] == "anomaly" and a["feed_related_likelihood"] == "HIGH"
        assert -21 < a["variance_percent"] < -19 and a["baseline_value"] == 3.0 and a["observed_value"] == 2.4
        assert a["model_reference"] == "origami.feed_performance.deterministic" and a["model_version"]
        assert 0.5 <= a["confidence_score"] <= 0.7, "confidence is lowered for every piece of context the farm does not record"
        assert {"environment", "milk_components", "weight_change", "group_membership"} <= set(a["confounders"]["missing_context"])
        assert a["confounders"]["health_events"] == 0 and a["confounders"]["refusal_events"] == 0
        change = a["evidence"]["feed_changes"][0]
        assert change["feed_product_id"] == GOAT_MIX and change["days_of_exposure"] >= 2 and change["lot_code"]
        assert a["evidence"]["baseline_window"]["observation_days"] == 7 and a["evidence"]["evaluation_window"]["observation_days"] == 3
        assert "20.0% below the rolling subject baseline" in a["explanation"]
        assert "Relevant change: Goat Mix" in a["explanation"] and "an association, not a cause" in a["explanation"]

        # One alert, with a review task and a bell signal; a repeat evaluation refreshes it, never twins it.
        alerts = [x for x in _alerts(client) if x["subject_id"] == GIGI]
        assert len(alerts) == 1
        alert = alerts[0]
        assert alert["alert_type"] == "PRODUCTION_DECLINE_AFTER_FEED_CHANGE" and alert["severity"] == "high" and alert["status"] == "open"
        assert alert["feed_product_id"] == GOAT_MIX and alert["assessment_id"] == a["id"] and alert["subject_name"] == "Gigi"
        tasks = db.scalars(select(models.Task).where(models.Task.source_type == "feed_performance_review", models.Task.source_id == alert["id"])).all()
        assert len(tasks) == 1 and tasks[0].status == "open" and tasks[0].priority == "high"
        bell = client.get(f"{API}/notifications", headers=_h(client)).json()["notifications"]
        assert any(n["source_type"] == "feed_performance_alert" and n["source_id"] == alert["id"] for n in bell)
        client.post(f"{API}/feed-performance/monitors/{monitor['id']}/evaluate", headers=_h(client))
        assert len([x for x in _alerts(client) if x["subject_id"] == GIGI]) == 1
        assert len(client.get(f"{API}/feed-performance/assessments", params={"monitor_id": monitor["id"]}, headers=_h(client)).json()) == 2, "every evaluation is kept"

        # Acknowledging records that a person saw it. The condition stands, so the alert stays open.
        r = client.post(f"{API}/feed-performance/alerts/{alert['id']}/acknowledge", headers=_h(client))
        assert r.status_code == 200, r.text
        assert r.json()["status"] == "acknowledged" and r.json()["acknowledged_by"]
        assert [x["status"] for x in _alerts(client) if x["subject_id"] == GIGI] == ["acknowledged"]
        bell = client.get(f"{API}/notifications", headers=_h(client)).json()["notifications"]
        assert not any(n["source_id"] == alert["id"] for n in bell), "acknowledged alerts leave the bell"

        # Milk comes back within the threshold: the alert resolves itself and its task closes.
        _milk(db, GIGI, {1: 2.9, 2: 2.9, 3: 2.9})
        r = client.post(f"{API}/feed-performance/monitors/{monitor['id']}/evaluate", params={"as_of": (_now() + timedelta(days=3)).isoformat()}, headers=_h(client))
        assert r.status_code == 200, r.text
        assert r.json()["status"] == "normal" and r.json()["feed_related_likelihood"] == "LOW"
        assert not [x for x in _alerts(client) if x["subject_id"] == GIGI]
        resolved = next(x for x in _alerts(client, "all") if x["id"] == alert["id"])
        assert resolved["status"] == "resolved" and resolved["resolved_at"] and "within the threshold" in resolved["resolution_note"]
        db.expire_all()
        assert db.get(models.Task, tasks[0].id).status == "done"

    def test_insufficient_evidence_is_named_not_read_as_no_change(self, client: TestClient):
        r = client.get(f"{API}/feed-performance/monitors", headers=_h(client))
        assert r.status_code == 200, r.text
        monitors = r.json()
        assert len(monitors) == 4, "the seed watches the dairy herd's milk and the three flocks' eggs"
        layers = next(m for m in monitors if m["subject_id"] == LAYERS)
        latest = layers["latest_assessment"]
        assert latest["status"] == "insufficient" and latest["feed_related_likelihood"] == "INSUFFICIENT_EVIDENCE"
        assert latest["variance_percent"] is None and latest["confidence_score"] <= 0.2
        assert "not enough evidence" in latest["explanation"] and "not as no change" in latest["explanation"]
        assert not [a for a in _alerts(client) if a["subject_id"] == LAYERS]

    def test_a_milk_record_re_evaluates_the_herd_between_cycles(self, client: TestClient):
        def count() -> int:
            return len(client.get(f"{API}/feed-performance/assessments", params={"subject_id": HERD}, headers=_h(client)).json())

        before = count()
        r = client.post(f"{API}/production/milk", json={"animal_id": CLOVER, "session": "evening", "liters": 10.5}, headers=_h(client))
        assert r.status_code == 201, r.text
        assert count() == before + 1

    def test_monitor_rules(self, client: TestClient):
        r = client.post(f"{API}/feed-performance/monitors", json={"subject_type": "animal", "subject_id": CLOVER, "production_metric_code": "eggs_per_day"}, headers=_h(client))
        assert r.status_code == 422 and "flock" in r.json()["detail"]
        r = client.post(f"{API}/feed-performance/monitors", json={"subject_type": "animal", "subject_id": CLOVER, "baseline_method_code": "guesswork"}, headers=_h(client))
        assert r.status_code == 422
        first = client.post(f"{API}/feed-performance/monitors", json={"subject_type": "animal", "subject_id": CLOVER}, headers=_h(client)).json()
        again = client.post(f"{API}/feed-performance/monitors", json={"subject_type": "animal", "subject_id": CLOVER}, headers=_h(client)).json()
        assert first["id"] == again["id"], "one monitor per subject and metric"
        r = client.patch(f"{API}/feed-performance/monitors/{first['id']}", json={"alert_threshold_percent": 10, "baseline_method_code": "previous_period"}, headers=_h(client))
        assert r.status_code == 200, r.text
        assert r.json()["alert_threshold_percent"] == 10 and r.json()["baseline_method_code"] == "previous_period"


# ------------------------------------------------------- mixes & suppliers
class TestMixAndSupplierScores:
    def test_a_mix_off_its_formula_is_a_manufacturing_deviation_with_its_own_alert(self, client: TestClient):
        done = _complete_second_mix(client, bump=1.12)
        assert done["mix_code"] == "MIX-000002"
        r = client.get(f"{API}/feed-performance/batches/{done['id']}", headers=_h(client))
        assert r.status_code == 200, r.text
        score = r.json()
        assert score["mix_number"] == 2 and score["formula_compliance_score"] < 1
        assert score["evidence"]["worst_component_deviation_pct"] > 5 and "formula_compliance" in score["evidence"]["dimensions_available"]
        assert score["production_response_score"] is None, "a dimension without evidence is null, never scored as perfect"
        assert [a["alert_type"] for a in score["open_alerts"]] == ["FORMULA_COMPLIANCE_DEVIATION"]

        alert = next(a for a in _alerts(client) if a["alert_type"] == "FORMULA_COMPLIANCE_DEVIATION")
        assert alert["mix_code"] == "MIX-000002" and alert["severity"] == "high" and "manufacturing deviation" in alert["explanation"]
        assert alert["evidence"]["tolerance_pct"] == 5
        usage = client.get(f"{API}/feed-mixes/2", headers=_h(client)).json()
        assert usage["performance"]["open_alerts"][0]["alert_type"] == "FORMULA_COMPLIANCE_DEVIATION"
        assert usage["worst_variance_pct"] > 5

        # Closing it by hand needs a reason; the evidence has not changed.
        r = client.post(f"{API}/feed-performance/alerts/{alert['id']}/resolve", json={"note": "  "}, headers=_h(client))
        assert r.status_code == 422
        r = client.post(f"{API}/feed-performance/alerts/{alert['id']}/resolve", json={"note": "Authorised substitution of silage for the day"}, headers=_h(client))
        assert r.status_code == 200, r.text
        assert r.json()["status"] == "resolved" and r.json()["resolution_note"].startswith("Authorised")
        assert client.post(f"{API}/feed-performance/alerts/{alert['id']}/acknowledge", headers=_h(client)).status_code == 422

        _evaluate(client)
        rows = client.get(f"{API}/feed-performance/batches", headers=_h(client)).json()
        assert [x["mix_code"] for x in rows] == ["MIX-000002", "MIX-000001"]
        assert all(0 <= x["confidence_score"] <= 1 for x in rows)

    def test_supplier_rows_are_per_ingredient(self, client: TestClient):
        _evaluate(client)
        r = client.get(f"{API}/feed-performance/suppliers", headers=_h(client))
        assert r.status_code == 200, r.text
        rows = r.json()
        mashreq = [x for x in rows if x["supplier_label"] == "Al Mashreq"]
        assert len(mashreq) == 2 and len({x["product_name"] for x in mashreq}) == 2, "a supplier's two ingredients are two rows"
        barley = next(x for x in rows if x["product_name"] == "Barley")
        assert barley["supplier_label"] == "Bekaa Hay Co." and barley["lot_count"] == 1 and barley["feed_batch_count"] == 1
        assert barley["average_unit_cost"] == 0.36 and barley["unit"] == "kg" and barley["incident_count"] == 0
        assert all(x["methodology_code"] == "deterministic_lot_lineage" and 0 <= x["confidence_score"] <= 1 for x in rows)
        assert all(x["evidence"]["lots"] for x in rows)

    def test_repeated_refusals_raise_an_intake_alert(self, client: TestClient):
        lots = client.get(f"{API}/feed-lots", params={"feed_product_id": DAIRY_MIX}, headers=_h(client)).json()
        lot = max(lots, key=lambda l: l["quantity_on_hand"])
        _feed(client, "group", HERD, DAIRY_MIX, 3, days_ago=1, event_type="refusal", lot_id=lot["id"])
        _feed(client, "group", HERD, DAIRY_MIX, 2, days_ago=0, event_type="refusal", lot_id=lot["id"])
        out = _evaluate(client)
        assert out["intake_alerts"] == 1
        alert = next(a for a in _alerts(client) if a["alert_type"] == "INTAKE_OR_REFUSAL_ANOMALY")
        assert alert["subject_id"] == HERD and "refused feed 2 times" in alert["explanation"]
        herd = next(a for a in client.get(f"{API}/feed-performance/assessments", params={"subject_id": HERD}, headers=_h(client)).json())
        assert herd["confounders"]["refusal_events"] == 2, "refusals are a confounder for the production reading too"


# ------------------------------------------------------------------ summary
class TestSummary:
    def test_summary_counts_what_the_cycle_produced(self, client: TestClient):
        r = client.get(f"{API}/feed-performance/summary", headers=_h(client))
        assert r.status_code == 200, r.text
        s = r.json()
        assert s["monitors"] == 4 and s["batches_scored"] == 1 and s["suppliers_scored"] == 4
        assert s["model_reference"] == "origami.feed_performance.deterministic" and s["last_evaluated_at"]
        out = _evaluate(client)
        assert out["monitors"] == 4 and out["batches_scored"] == 1 and out["suppliers"] == 4 and out["insufficient"] == 3
        assert out["cost_efficiency"]["cost_per_litre_this_week"] is not None
