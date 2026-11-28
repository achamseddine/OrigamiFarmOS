"""Feed performance → the manager's action → its measured outcome
(master prompt Package 13; database/FEED-PERFORMANCE-ACTIONS.md).

    Gigi's milk falls a fifth after a goat mix is introduced: the Feed
      Performance Intelligence alerts once, with its evidence and confidence
    → the manager acts on the alert (back to the previous lot), expecting the
      milk back up, measured after 7 days; the alert is acknowledged
    → after 7 days the outcome is measured once from her milk records: the
      week before against the week after, as expected or not, with a
      confidence lowered for each confounder (a health event in between);
      too few records is insufficient data, never "no change"
    → one bell signal for the manager until reviewed
"""
from __future__ import annotations

from datetime import timedelta

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app.domain import feed_action_models as am
from app.domain import models
from app.repositories.base import new_id
from tests.conftest import auth_headers
from tests.test_feed_performance import GIGI, GOAT_MIX, _feed, _milk, _now

API = "/api/v1"
WORKER = "karim.worker@origami.farm"


def _h(client, email="rami@origami.farm"):
    return auth_headers(client, email)


def _decline_alert(client: TestClient, db) -> dict:
    """The FPI's own acceptance case: seven steady days, then a goat mix and a fifth less milk."""
    _milk(db, GIGI, {-d: 3.0 for d in range(3, 10)})
    _milk(db, GIGI, {-2: 2.4, -1: 2.3, 0: 2.5})
    for d in (4, 3, 2, 1, 0):
        _feed(client, "animal", GIGI, GOAT_MIX, 1.2, days_ago=d)
    monitor = client.post(f"{API}/feed-performance/monitors", json={"subject_type": "animal", "subject_id": GIGI, "production_metric_code": "milk_l_per_day"},
                          headers=_h(client)).json()
    a = client.post(f"{API}/feed-performance/monitors/{monitor['id']}/evaluate", headers=_h(client)).json()
    assert a["status"] == "anomaly"
    alerts = [x for x in client.get(f"{API}/feed-performance/alerts", params={"status": "open"}, headers=_h(client)).json() if x["subject_id"] == GIGI]
    assert len(alerts) == 1
    return alerts[0]


def _act(client, alert, **over):
    body = {"action_type": "change_lot", "description": "Back to the previous mix lot; goat mix stopped", "expected_effect": "increase",
            "measure_after_days": 7, "baseline_days": 7, **over}
    return client.post(f"{API}/feed-performance/alerts/{alert['id']}/actions", headers=_h(client), json=body)


def _measure(client, action, days_after: float = 7.5):
    return client.post(f"{API}/feed-performance/actions/{action['id']}/measure", headers=_h(client),
                       params={"as_of": (_now() + timedelta(days=days_after)).isoformat()})


def _bell(client):
    return [n for n in client.get(f"{API}/notifications", headers=_h(client)).json()["notifications"] if n["source_type"] == "feed_action_outcome"]


class TestTheLoop:
    def test_an_action_on_the_alert_measured_once_as_expected_with_its_confidence(self, client, db_session):
        db, _ = db_session
        alert = _decline_alert(client, db)
        r = _act(client, alert)
        assert r.status_code == 201, r.text
        action = r.json()
        assert action["status"] == "measuring" and action["alert_id"] == alert["id"] and action["assessment_id"] == alert["assessment_id"]
        assert action["metric_code"] == "milk_l_per_day" and action["subject_name"] == "Gigi"
        # The action acknowledges the alert; the alert keeps its evidence and stays open in the list.
        assert next(x for x in client.get(f"{API}/feed-performance/alerts", params={"status": "all"}, headers=_h(client)).json()
                    if x["id"] == alert["id"])["status"] == "acknowledged"
        # One action at a time on an alert; not measured before its window has passed.
        assert _act(client, alert).status_code == 409
        early = _measure(client, action, days_after=3)
        assert early.status_code == 409 and "Not yet" in early.json()["detail"]

        # The week after: the milk is back above the old level.
        _milk(db, GIGI, {d: 3.1 for d in range(1, 8)})
        r = _measure(client, action)
        assert r.status_code == 200, r.text
        out = r.json()
        assert out["status"] == "measured" and out["outcome"] == "as_expected"
        baseline = (3.0 * 5 + 2.4 + 2.3) / 7
        assert out["baseline_value"] == round(baseline, 3) and out["outcome_value"] == 3.1
        assert out["change_pct"] == round((3.1 - baseline) / baseline * 100, 1)
        assert out["evidence"]["baseline_window"]["observation_days"] == 7 and out["evidence"]["outcome_window"]["observation_days"] == 7
        # The context the farm does not record lowers the confidence, and says so.
        assert 0.5 <= out["confidence_score"] < 0.8
        assert any(d["confounder"] == "missing_context" for d in out["evidence"]["deductions"])
        assert "not proof that it caused it" in out["explanation"]
        # Measured once.
        assert _measure(client, action).status_code == 409

        # One bell signal for the manager, until reviewed.
        mine = [n for n in _bell(client) if n["source_id"].startswith(action["id"])]
        assert len(mine) == 1 and mine[0]["user_id"] == "user-rami"
        assert client.post(f"{API}/feed-performance/actions/{action['id']}/review", headers=_h(client)).status_code == 200
        assert not [n for n in _bell(client) if n["source_id"].startswith(action["id"])]

    def test_a_health_event_in_the_window_lowers_the_confidence(self, client, db_session):
        db, _ = db_session
        alert = _decline_alert(client, db)
        action = _act(client, alert).json()
        _milk(db, GIGI, {d: 3.1 for d in range(1, 8)})
        db.add(models.Observation(id=new_id(), farm_id="farm-origami", entity_type="animal", entity_id=GIGI, observation_type="lameness",
                                  observed_at=_now() + timedelta(days=3), observer_id="user-worker-1"))
        db.commit()
        out = _measure(client, action).json()
        cut = next(d for d in out["evidence"]["deductions"] if d["confounder"] == "health_events")
        assert cut["count"] >= 1 and cut["minus"] == 0.15
        assert out["confidence_score"] <= 0.8 - 0.15 - 0.02 + 1e-9
        assert "health events" in out["explanation"]

    def test_the_opposite_of_what_was_expected_and_too_few_records(self, client, db_session):
        db, _ = db_session
        alert = _decline_alert(client, db)
        action = _act(client, alert).json()
        _milk(db, GIGI, {d: 2.0 for d in range(1, 8)})
        assert _measure(client, action).json()["outcome"] == "opposite"

    def test_too_few_records_is_insufficient_data_not_no_change(self, client, db_session):
        db, _ = db_session
        alert = _decline_alert(client, db)
        action = _act(client, alert).json()
        _milk(db, GIGI, {1: 3.1, 2: 3.1})
        out = _measure(client, action).json()
        assert out["outcome"] == "insufficient_data" and out["confidence_score"] is None and out["change_pct"] is None
        assert "Not enough records" in out["explanation"]

    def test_the_daily_cycle_measures_what_is_due_once(self, client, db_session):
        db, _ = db_session
        alert = _decline_alert(client, db)
        action = _act(client, alert).json()
        _milk(db, GIGI, {d: 3.1 for d in range(1, 8)})
        as_of = (_now() + timedelta(days=7.5)).isoformat()
        first = client.post(f"{API}/feed-performance/evaluate", params={"as_of": as_of}, headers=_h(client)).json()
        assert first["outcomes_measured"] == 1
        again = client.post(f"{API}/feed-performance/evaluate", params={"as_of": as_of}, headers=_h(client)).json()
        assert again["outcomes_measured"] == 0
        assert client.get(f"{API}/feed-performance/actions/{action['id']}", headers=_h(client)).json()["status"] == "measured"
        assert db.scalar(select(func.count(models.Event.id)).where(models.Event.event_type == "feed_action_outcome_measured")) == 1


class TestRules:
    def test_who_what_and_which_farm(self, client, db_session):
        db, _ = db_session
        from app.core.security import hash_password

        alert = _decline_alert(client, db)
        assert client.post(f"{API}/feed-performance/alerts/{alert['id']}/actions", headers=_h(client, WORKER),
                           json={"action_type": "change_lot", "description": "x"}).status_code == 403
        assert _act(client, alert, action_type="pray").status_code == 422
        assert _act(client, alert, description="  ").status_code == 422
        assert _act(client, alert, decided_at=(_now() + timedelta(days=2)).isoformat()).status_code == 422
        assert _act(client, alert, measure_after_days=1).status_code == 422
        action = _act(client, alert).json()
        assert client.post(f"{API}/feed-performance/actions/{action['id']}/cancel", headers=_h(client), json={"reason": ""}).status_code == 422
        r = client.post(f"{API}/feed-performance/actions/{action['id']}/cancel", headers=_h(client), json={"reason": "Wrong alert"})
        assert r.status_code == 200 and r.json()["status"] == "cancelled"
        assert _measure(client, action).status_code == 409
        # Cancelled, a new action may be recorded.
        assert _act(client, alert).status_code == 201
        db.add(models.Farm(id="farm-other", name="Other", country="Lebanon", region="North", timezone="Asia/Beirut", default_currency="USD"))
        db.add(models.User(id="user-other", farm_id="farm-other", name="Other Manager", email="m@other.farm", password_hash=hash_password("farmos123"),
                           role="manager", language="en"))
        db.commit()
        other = _h(client, "m@other.farm")
        assert client.get(f"{API}/feed-performance/actions/{action['id']}", headers=other).status_code == 404
        assert client.post(f"{API}/feed-performance/alerts/{alert['id']}/actions", headers=other,
                           json={"action_type": "change_lot", "description": "x"}).status_code == 404
        assert client.get(f"{API}/feed-performance/actions", headers=other).json() == []

    def test_an_alert_without_a_subject_or_resolved_takes_no_action(self, client, db_session):
        db, _ = db_session
        from app.domain import feed_models as fm

        alert = _decline_alert(client, db)
        row = db.get(fm.FeedPerformanceAlert, alert["id"])
        row.status = "resolved"
        db.commit()
        assert _act(client, alert).status_code == 409
        loose = fm.FeedPerformanceAlert(id=new_id(), farm_id="farm-origami", alert_type="COST_EFFICIENCY", severity="medium", title="Feed cost per litre up",
                                        explanation="x", evidence_json={}, status="open", deduplication_key="cost-x")
        db.add(loose)
        db.commit()
        r = client.post(f"{API}/feed-performance/alerts/{loose.id}/actions", headers=_h(client), json={"action_type": "other", "description": "Review prices"})
        assert r.status_code == 422 and "cannot be measured" in r.json()["detail"]
        assert db.scalar(select(func.count(am.FeedPerformanceAction.id))) == 0
