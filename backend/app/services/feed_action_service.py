"""Feed performance → the manager's action → its measured outcome
(master prompt Package 13; database/FEED-PERFORMANCE-ACTIONS.md).

Built on the Feed Performance Intelligence (feed_performance_service): its
alerts already wait for enough evidence, lower their confidence for every
confounder and never twin. This adds the loop after the alert:

* the manager records an **action** on an alert that is about a subject's
  production (it has an assessment and a monitor): what was done, what is
  expected, and how many days to wait. One action at a time per alert. The
  open alert is acknowledged by it. The action is a decision: the lot, the
  formula or the feeding is changed in its own workflow and only linked;
* the **outcome** is measured once, when its window has passed — by the daily
  cycle or on request — from the canonical daily production values
  (``daily_values``: milk per milked head per day, eggs, growth): the mean
  of the ``baseline_days`` before the decision against the mean of the
  ``measure_after_days`` after it. At least ``MIN_DAYS`` recorded days on
  each side, or it is *insufficient data* (missing is never zero);
* **confidence** starts at ``BASE_CONFIDENCE`` and is lowered for every
  confounder the Feed Performance Intelligence sees in the window — health
  events and cases, withdrawals, calvings and dry-offs, moves, management
  changes, a change of the milked herd, another feed change — and for the
  context the farm does not record. Every reduction is listed;
* the outcome is shown once on the manager's bell until it is reviewed.
  An association, never a cause.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core import permissions as perms
from app.core.record_time import CLOCK_TOLERANCE
from app.domain import feed_action_models as am
from app.domain import feed_models as fm
from app.domain import models
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event
from app.services import feed_performance_service as perf
from app.services import feeding_program_service as programs
from app.services.feed_inventory_service import FeedError

MODULE = "feed_nutrition"
MIN_DAYS = 5
BASE_CONFIDENCE = 0.8
# A change smaller than this (% of the baseline) is no change.
EFFECT_THRESHOLD_PCT = 3.0
WINDOW_DAYS = (3, 60)
# What each confounder in the window takes off the confidence.
DEDUCTIONS = (
    ("health_events", 0.15, "health events in the window"),
    ("active_health_cases", 0.10, "an open health case"),
    ("animals_under_withdrawal", 0.10, "animals under withdrawal"),
    ("recent_calving", 0.15, "a calving"),
    ("recent_dry_off", 0.10, "a dry-off"),
    ("movements", 0.10, "animals moved"),
    ("management_changes", 0.10, "management changes"),
    ("ingredient_lot_changes", 0.05, "another feed or lot change"),
)
MISSING_CONTEXT_EACH = 0.02
MISSING_CONTEXT_MAX = 0.10
MIN_CONFIDENCE = 0.1


class ActionError(FeedError):
    pass


def _alert(db: Session, alert_id: str, farm_id: str) -> fm.FeedPerformanceAlert:
    a = db.get(fm.FeedPerformanceAlert, alert_id)
    if a is None or a.farm_id != farm_id:
        raise ActionError("Alert not found", 404)
    return a


def get_action(db: Session, action_id: str, farm_id: str, *, lock: bool = False) -> am.FeedPerformanceAction:
    stmt = select(am.FeedPerformanceAction).where(am.FeedPerformanceAction.id == action_id)
    if lock:
        stmt = stmt.with_for_update().execution_options(populate_existing=True)
    a = db.scalar(stmt)
    if a is None or a.farm_id != farm_id:
        raise ActionError("Action not found", 404)
    return a


def _window(name: str, days: int | None, default: int) -> int:
    d = default if days is None else int(days)
    if not WINDOW_DAYS[0] <= d <= WINDOW_DAYS[1]:
        raise ActionError(f"{name} is {WINDOW_DAYS[0]}–{WINDOW_DAYS[1]} days.", 422)
    return d


def record_action(db: Session, user: models.User, alert_id: str, *, action_type: str, description: str, expected_effect: str = "increase",
                  measure_after_days: int | None = None, baseline_days: int | None = None, decided_at: datetime | None = None,
                  linked_entity_type: str | None = None, linked_entity_id: str | None = None) -> am.FeedPerformanceAction:
    # The alert is locked and read afresh: two managers acting on it at once record one action.
    alert = db.scalar(select(fm.FeedPerformanceAlert).where(fm.FeedPerformanceAlert.id == alert_id).with_for_update()
                      .execution_options(populate_existing=True))
    if alert is None or alert.farm_id != user.farm_id:
        raise ActionError("Alert not found", 404)
    if action_type not in am.ACTION_TYPES:
        raise ActionError(f"action_type must be one of {', '.join(am.ACTION_TYPES)}.", 422)
    if expected_effect not in am.EXPECTED_EFFECTS:
        raise ActionError(f"expected_effect must be one of {', '.join(am.EXPECTED_EFFECTS)}.", 422)
    if not (description or "").strip():
        raise ActionError("Say what was done.", 422)
    if alert.status == "resolved":
        raise ActionError("This alert is resolved: there is nothing left to act on.", 409)
    assessment = db.get(fm.FeedPerformanceAssessment, alert.assessment_id) if alert.assessment_id else None
    if assessment is None or not alert.subject_type or not alert.subject_id:
        raise ActionError("This alert is not about one herd's or one animal's production, so an outcome cannot be measured for it.", 422)
    current = db.scalar(select(am.FeedPerformanceAction).where(am.FeedPerformanceAction.alert_id == alert.id, am.FeedPerformanceAction.status == "measuring"))
    if current is not None:
        raise ActionError("An action on this alert is already being measured: wait for its outcome, or cancel it.", 409)
    monitor = db.get(fm.FeedPerformanceMonitor, assessment.monitor_id)
    when = ensure_utc(decided_at) if decided_at else now()
    if when > now() + CLOCK_TOLERANCE:
        raise ActionError("An action cannot be dated in the future.", 422)
    if when < ensure_utc(alert.detected_at) - timedelta(days=1):
        raise ActionError("An action on this alert cannot be dated before the alert.", 422)
    a = am.FeedPerformanceAction(
        id=new_id(), farm_id=alert.farm_id, alert_id=alert.id, assessment_id=assessment.id, monitor_id=monitor.id,
        subject_type=alert.subject_type, subject_id=alert.subject_id, metric_code=monitor.production_metric_code, action_type=action_type,
        description=description.strip()[:2000], expected_effect=expected_effect, linked_entity_type=(linked_entity_type or None),
        linked_entity_id=(linked_entity_id or None), decided_by=user.id, decided_at=when,
        baseline_days=_window("The baseline", baseline_days, 14), measure_after_days=_window("The wait before measuring", measure_after_days, 14),
        status="measuring", evidence_json={}, created_at=now())
    db.add(a)
    if alert.status == "open":
        perf.acknowledge_alert(db, alert, user_id=user.id)
    db.flush()
    write_event(db, farm_id=a.farm_id, entity_type="feed_performance_alert", entity_id=alert.id, event_type="feed_action_recorded",
                payload={"action_id": a.id, "action_type": action_type, "expected_effect": expected_effect, "measure_from": due_at(a).isoformat()},
                created_by=user.id)
    write_audit_log(db, farm_id=a.farm_id, user_id=user.id, action="feed_action_recorded", entity_type="feed_performance_action", entity_id=a.id,
                    module_code=MODULE, summary=f"{alert.title}: {action_type.replace('_', ' ')} — {a.description}"[:500])
    return a


def due_at(a: am.FeedPerformanceAction) -> datetime:
    return ensure_utc(a.decided_at) + timedelta(days=a.measure_after_days)


def _day(d: datetime) -> date:
    return ensure_utc(d).date()


def measure(db: Session, a: am.FeedPerformanceAction, *, as_of: datetime | None = None, user_id: str = "system") -> am.FeedPerformanceAction:
    """The outcome, once: the baseline before the decision against the window after it."""
    a = get_action(db, a.id, a.farm_id, lock=True)
    if a.status != "measuring":
        raise ActionError("This action's outcome was already measured." if a.status == "measured" else "This action was cancelled.", 409)
    at = ensure_utc(as_of) if as_of else now()
    if at < due_at(a):
        raise ActionError(f"Not yet: the outcome is measured from {due_at(a).date().isoformat()}.", 409)
    subject = perf._subject(db, a.subject_type, a.subject_id)
    monitor = db.get(fm.FeedPerformanceMonitor, a.monitor_id)
    decided = _day(a.decided_at)
    base_start, base_end = decided - timedelta(days=a.baseline_days), decided - timedelta(days=1)
    out_start, out_end = decided + timedelta(days=1), decided + timedelta(days=a.measure_after_days)
    baseline = perf.daily_values(db, a.subject_type, subject, a.metric_code, base_start, base_end)
    observed = perf.daily_values(db, a.subject_type, subject, a.metric_code, out_start, out_end)
    group = programs.group_for_animal(db, subject) if a.subject_type == "animal" else None
    confounders = perf._confounders(db, monitor, a.subject_type, subject, group, out_start, out_end, base_start, base_end, observed, [])
    evidence = {"baseline_window": {"start": base_start.isoformat(), "end": base_end.isoformat(), "observation_days": len(baseline)},
                "outcome_window": {"start": out_start.isoformat(), "end": out_end.isoformat(), "observation_days": len(observed)},
                "daily_baseline": {d.isoformat(): v for d, v in sorted(baseline.items())},
                "daily_outcome": {d.isoformat(): v for d, v in sorted(observed.items())},
                "confounders": confounders, "deductions": []}
    a.measured_at = at
    a.status = "measured"
    if len(baseline) < MIN_DAYS or len(observed) < MIN_DAYS:
        a.outcome = "insufficient_data"
        a.confidence_score = None
        a.explanation = (f"Not enough records to measure: {len(baseline)} day(s) before and {len(observed)} after, at least {MIN_DAYS} of each are needed. "
                         "Missing days are not read as no change.")
    else:
        b = sum(baseline.values()) / len(baseline)
        o = sum(observed.values()) / len(observed)
        pct = (o - b) / b * 100 if b else None
        a.baseline_value, a.outcome_value, a.change_pct = round(b, 3), round(o, 3), (round(pct, 1) if pct is not None else None)
        if pct is None:
            a.outcome = "insufficient_data"
        elif abs(pct) < EFFECT_THRESHOLD_PCT:
            a.outcome = "as_expected" if a.expected_effect == "no_change" else "no_change"
        elif (pct > 0) == (a.expected_effect == "increase"):
            a.outcome = "as_expected"
        else:
            a.outcome = "opposite" if a.expected_effect != "no_change" else "no_change"
        confidence = BASE_CONFIDENCE
        for key, cut, label in DEDUCTIONS:
            value = confounders.get(key)
            if key == "ingredient_lot_changes":
                value = _other_feed_changes(db, a, subject, group, out_start, out_end)
            if value:
                confidence -= cut
                evidence["deductions"].append({"confounder": key, "label": label, "count": value, "minus": cut})
        if confounders.get("milked_heads_change") == "changed":
            confidence -= 0.10
            evidence["deductions"].append({"confounder": "milked_heads_change", "label": "the milked herd changed", "count": 1, "minus": 0.10})
        missing = confounders.get("missing_context") or []
        cut = min(MISSING_CONTEXT_MAX, MISSING_CONTEXT_EACH * len(missing))
        if cut:
            confidence -= cut
            evidence["deductions"].append({"confounder": "missing_context", "label": "context the farm does not record", "count": len(missing), "minus": round(cut, 2)})
        a.confidence_score = round(max(MIN_CONFIDENCE, confidence), 2)
        unit = "L per head per day" if a.metric_code == "milk_l_per_day" else a.metric_code.replace("_", " ")
        word = {"as_expected": "as expected", "no_change": "no clear change", "opposite": "the opposite of what was expected"}[a.outcome]
        why = "; ".join(d["label"] for d in evidence["deductions"]) or "no confounder seen"
        a.explanation = (f"{b:.2f} → {o:.2f} {unit} ({pct:+.1f} %) over {len(observed)} recorded days after the action, against {len(baseline)} before: {word}. "
                         f"Confidence {a.confidence_score:.2f} ({why}). An association with the action, not proof that it caused it.")
    a.evidence_json = evidence
    db.flush()
    write_event(db, farm_id=a.farm_id, entity_type="feed_performance_alert", entity_id=a.alert_id, event_type="feed_action_outcome_measured",
                payload={"action_id": a.id, "outcome": a.outcome, "change_pct": a.change_pct, "confidence": a.confidence_score}, created_by=user_id)
    write_audit_log(db, farm_id=a.farm_id, user_id=user_id, action="feed_action_outcome_measured",
                    entity_type="feed_performance_action", entity_id=a.id, module_code=MODULE, summary=(a.explanation or "")[:500])
    return a


def _other_feed_changes(db: Session, a: am.FeedPerformanceAction, subject, group, start: date, end: date) -> int:
    """Feed changes in the outcome window other than the one this action is about."""
    changes = perf._feed_changes(db, a.farm_id, a.subject_type, subject, group, perf._start_of(start), perf._start_of(end + timedelta(days=1)))
    if a.action_type in ("change_lot", "change_supplier", "revise_formula", "adjust_feeding"):
        # The action's own change is the first one after it; the others confound.
        return max(0, len(changes) - 1)
    return len(changes)


def measure_due(db: Session, farm_id: str, *, as_of: datetime | None = None) -> list[am.FeedPerformanceAction]:
    """Every action whose window has passed, measured (the daily cycle calls this)."""
    at = ensure_utc(as_of) if as_of else now()
    out = []
    for a in db.scalars(select(am.FeedPerformanceAction).where(am.FeedPerformanceAction.farm_id == farm_id, am.FeedPerformanceAction.status == "measuring")):
        if due_at(a) <= at:
            out.append(measure(db, a, as_of=at))
    return out


def review(db: Session, user: models.User, a: am.FeedPerformanceAction) -> am.FeedPerformanceAction:
    a = get_action(db, a.id, a.farm_id, lock=True)
    if a.status != "measured":
        raise ActionError("Only a measured outcome is reviewed.", 409)
    if a.reviewed_at is None:
        a.reviewed_by, a.reviewed_at = user.id, now()
        write_event(db, farm_id=a.farm_id, entity_type="feed_performance_alert", entity_id=a.alert_id, event_type="feed_action_outcome_reviewed",
                    payload={"action_id": a.id}, created_by=user.id)
    return a


def cancel(db: Session, user: models.User, a: am.FeedPerformanceAction, *, reason: str) -> am.FeedPerformanceAction:
    a = get_action(db, a.id, a.farm_id, lock=True)
    if a.status != "measuring":
        raise ActionError("Only an action still being measured is cancelled.", 409)
    if not (reason or "").strip():
        raise ActionError("Say why the action is cancelled.", 422)
    a.status, a.cancel_reason = "cancelled", reason.strip()[:1000]
    write_event(db, farm_id=a.farm_id, entity_type="feed_performance_alert", entity_id=a.alert_id, event_type="feed_action_cancelled",
                payload={"action_id": a.id, "reason": a.cancel_reason}, created_by=user.id)
    write_audit_log(db, farm_id=a.farm_id, user_id=user.id, action="feed_action_cancelled", entity_type="feed_performance_action", entity_id=a.id,
                    module_code=MODULE, summary=f"Action cancelled: {a.cancel_reason}"[:500])
    return a


def list_actions(db: Session, farm_id: str, *, alert_id: str | None = None, status: str | None = None) -> list[am.FeedPerformanceAction]:
    stmt = select(am.FeedPerformanceAction).where(am.FeedPerformanceAction.farm_id == farm_id)
    if alert_id:
        stmt = stmt.where(am.FeedPerformanceAction.alert_id == alert_id)
    if status:
        stmt = stmt.where(am.FeedPerformanceAction.status == status)
    return list(db.scalars(stmt.order_by(am.FeedPerformanceAction.decided_at.desc())))


def action_dict(db: Session, a: am.FeedPerformanceAction) -> dict:
    alert = db.get(fm.FeedPerformanceAlert, a.alert_id)
    who = db.get(models.User, a.decided_by)
    subject = perf._subject(db, a.subject_type, a.subject_id)
    return {"id": a.id, "alert_id": a.alert_id, "alert_title": alert.title if alert else None, "alert_type": alert.alert_type if alert else None,
            "assessment_id": a.assessment_id, "monitor_id": a.monitor_id, "subject_type": a.subject_type, "subject_id": a.subject_id,
            "subject_name": getattr(subject, "name", None), "metric_code": a.metric_code, "action_type": a.action_type, "description": a.description,
            "expected_effect": a.expected_effect, "linked_entity_type": a.linked_entity_type, "linked_entity_id": a.linked_entity_id,
            "decided_by": a.decided_by, "decided_by_name": who.name if who else None, "decided_at": ensure_utc(a.decided_at).isoformat(),
            "baseline_days": a.baseline_days, "measure_after_days": a.measure_after_days, "measure_from": due_at(a).isoformat(), "status": a.status,
            "measured_at": ensure_utc(a.measured_at).isoformat() if a.measured_at else None, "baseline_value": a.baseline_value,
            "outcome_value": a.outcome_value, "change_pct": a.change_pct, "outcome": a.outcome, "confidence_score": a.confidence_score,
            "evidence": a.evidence_json, "explanation": a.explanation, "reviewed_at": ensure_utc(a.reviewed_at).isoformat() if a.reviewed_at else None,
            "cancel_reason": a.cancel_reason}


def outcome_signals(db: Session, farm_id: str) -> list:
    """One bell signal per measured outcome until a manager reviews it (never twice)."""
    from app.services.signals_service import Signal, routed  # local import: signals imports the feed services

    out = []
    for a in db.scalars(select(am.FeedPerformanceAction).where(am.FeedPerformanceAction.farm_id == farm_id, am.FeedPerformanceAction.status == "measured",
                                                               am.FeedPerformanceAction.reviewed_at.is_(None))):
        alert = db.get(fm.FeedPerformanceAlert, a.alert_id)
        base = Signal(source_type="feed_action_outcome", source_id=a.id, module_code=perms.FEED_NUTRITION, notification_type="feed_action_outcome",
                      title=f"Outcome measured: {alert.title if alert else a.action_type}"[:200], description=(a.explanation or "")[:300],
                      priority="medium" if a.outcome == "as_expected" else "high", entity_type=a.subject_type, entity_id=a.subject_id,
                      metadata={"action_id": a.id, "alert_id": a.alert_id, "outcome": a.outcome, "confidence": a.confidence_score})
        out.extend(routed(db, farm_id, "feed_performance", base))
    return out
