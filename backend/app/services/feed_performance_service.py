"""Feed Performance Intelligence — the deterministic first increment
(database/FEED-PERFORMANCE-INTELLIGENCE.md; roadmap: "begin with
deterministic baselines / formula deviation / traceability, then add
versioned statistical/AI models").

What it does, and only this:

- connects what was bought (supplier lot), what was mixed (numbered mix,
  actual components), what was fed (feeding events through the output
  lot) and what the animals produced afterwards (milk / eggs);
- compares production in an evaluation window against an **explicit
  baseline** the monitor names, and says how big and how persistent the
  change is;
- lists the feed changes that preceded it, with their lineage, and the
  confounders it could and could not check — missing context lowers the
  confidence, it is never treated as "no change";
- scores mixes and suppliers from the same facts, ingredient by
  ingredient;
- raises persistent, deduplicated alerts that resolve themselves when
  the condition clears.

What it never does: write a milk, feed, stock, health or supplier fact;
change a formula, a program, a lot's status or a supplier's standing;
or call an association a cause. Every assessment carries its model
reference, evidence window, confounders and confidence so a person can
check it.
"""
from __future__ import annotations

import statistics
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.core import permissions as perms
from app.domain import feed_models as fm
from app.domain import models
from app.feeding import uom
from app.repositories.base import ensure_utc, new_id, now, write_event
from app.services import feed_batch_service as batches
from app.services import feed_inventory_service as inv
from app.services import feeding_program_service as programs
from app.services.feed_inventory_service import FeedError

MODEL_REFERENCE = "origami.feed_performance.deterministic"
MODEL_VERSION = "1.0"
METRICS = ("milk_l_per_day", "eggs_per_day")
BASELINE_METHODS = ("rolling_subject", "previous_period")
LIKELIHOODS = ("LOW", "MODERATE", "HIGH", "INSUFFICIENT_EVIDENCE")
ALERT_TYPES = (
    "PRODUCTION_DECLINE_AFTER_FEED_CHANGE", "FEED_BATCH_UNDERPERFORMANCE", "FORMULA_COMPLIANCE_DEVIATION",
    "INGREDIENT_LOT_PERFORMANCE_ANOMALY", "SUPPLIER_LOT_PERFORMANCE_ANOMALY", "INTAKE_OR_REFUSAL_ANOMALY",
    "FEED_COST_PER_OUTPUT_INCREASE", "FEED_PERFORMANCE_IMPROVEMENT",
)
COMPLIANCE_TOLERANCE_PCT = 5.0      # a component more than this off target is a manufacturing deviation
CHANGE_LOOKBACK_DAYS = 7            # a lot introduced this long before the period counts as a feed change
ONGOING_GAP_DAYS = 2                # an exposure with no issue for this long is over
COST_INCREASE_ALERT_PCT = 10.0
REFUSALS_FOR_ALERT = 2
CONTEXT_WE_CANNOT_SEE = ("environment", "milk_components", "weight_change")  # not recorded by this app yet


# ---------------------------------------------------------------- helpers
def _as_date(v) -> date:
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    return date.fromisoformat(str(v)[:10])


def _start_of(d: date) -> datetime:
    return datetime(d.year, d.month, d.day, tzinfo=timezone.utc)


def _clamp(v: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, v))


def _mean(values) -> float | None:
    values = [v for v in values if v is not None]
    return round(sum(values) / len(values), 4) if values else None


def _subject(db: Session, subject_type: str, subject_id: str):
    return db.get(models.Animal, subject_id) if subject_type == "animal" else db.get(models.Flock, subject_id)


def _subject_animals(db: Session, subject_type: str, subject) -> list[models.Animal]:
    if subject is None:
        return []
    if subject_type == "animal":
        return [subject]
    return programs.animals_in_group(db, subject)


def _get_monitor(db: Session, monitor_id: str, farm_id: str) -> fm.FeedPerformanceMonitor:
    m = db.get(fm.FeedPerformanceMonitor, monitor_id)
    if m is None or m.farm_id != farm_id:
        raise FeedError("Monitor not found", 404)
    return m


# ---------------------------------------------------------------- monitors
def create_monitor(db: Session, farm_id: str, *, subject_type: str, subject_id: str, production_metric_code: str = "milk_l_per_day",
                   baseline_method_code: str = "rolling_subject", baseline_window_days: int = 14, evaluation_window_days: int = 3,
                   evaluation_frequency_code: str = "daily", minimum_exposure_days: float = 2.0, minimum_observations: int = 3,
                   alert_threshold_percent: float = 5.0, active: bool = True, configuration: dict | None = None, user_id: str) -> fm.FeedPerformanceMonitor:
    if subject_type not in ("animal", "group"):
        raise FeedError("subject_type must be animal or group")
    subject = _subject(db, subject_type, subject_id)
    if subject is None or subject.farm_id != farm_id:
        raise FeedError("Subject not found", 404)
    if production_metric_code not in METRICS:
        raise FeedError(f"production_metric_code must be one of {list(METRICS)}")
    if baseline_method_code not in BASELINE_METHODS:
        raise FeedError(f"baseline_method_code must be one of {list(BASELINE_METHODS)}")
    if production_metric_code == "eggs_per_day" and subject_type != "group":
        raise FeedError("Eggs are recorded per flock; monitor the group, not an animal.")
    if baseline_window_days < 2 or evaluation_window_days < 1 or alert_threshold_percent <= 0:
        raise FeedError("Windows must be at least a day and the threshold above zero.")
    existing = db.scalar(select(fm.FeedPerformanceMonitor).where(
        fm.FeedPerformanceMonitor.farm_id == farm_id, fm.FeedPerformanceMonitor.subject_type == subject_type,
        fm.FeedPerformanceMonitor.subject_id == subject_id, fm.FeedPerformanceMonitor.production_metric_code == production_metric_code,
    ))
    if existing is not None:
        return existing
    row = fm.FeedPerformanceMonitor(
        id=new_id(), farm_id=farm_id, subject_type=subject_type, subject_id=subject_id, production_metric_code=production_metric_code,
        baseline_method_code=baseline_method_code, baseline_window_days=baseline_window_days, evaluation_window_days=evaluation_window_days,
        evaluation_frequency_code=evaluation_frequency_code, minimum_exposure_days=minimum_exposure_days, minimum_observations=minimum_observations,
        alert_threshold_percent=alert_threshold_percent, active=active, configuration_json=configuration or {}, created_at=now(), updated_at=now(),
    )
    db.add(row)
    db.flush()
    write_event(db, farm_id=farm_id, entity_type=subject_type, entity_id=subject_id, event_type="feed_performance_monitor_created",
                payload={"monitor_id": row.id, "metric": production_metric_code, "baseline": baseline_method_code, "threshold_pct": alert_threshold_percent},
                created_by=user_id)
    return row


def update_monitor(db: Session, monitor: fm.FeedPerformanceMonitor, changes: dict, *, user_id: str) -> fm.FeedPerformanceMonitor:
    allowed = {"baseline_method_code", "baseline_window_days", "evaluation_window_days", "evaluation_frequency_code", "minimum_exposure_days",
               "minimum_observations", "alert_threshold_percent", "active", "configuration_json"}
    for k, v in changes.items():
        if k == "configuration":
            k = "configuration_json"
        if k in allowed and v is not None:
            setattr(monitor, k, v)
    if monitor.baseline_method_code not in BASELINE_METHODS:
        raise FeedError(f"baseline_method_code must be one of {list(BASELINE_METHODS)}")
    monitor.updated_at = now()
    return monitor


def ensure_default_monitors(db: Session, farm_id: str, *, user_id: str) -> list[fm.FeedPerformanceMonitor]:
    """A monitor for every group that produces: milk for herds whose
    members have milk records, eggs for flocks with egg records. Explicit
    per-animal monitors are the farm's to add."""
    created = []
    for group in db.scalars(select(models.Flock).where(models.Flock.farm_id == farm_id)):
        members = programs.animals_in_group(db, group)
        has_milk = bool(members) and db.scalar(select(func.count(models.MilkRecord.id)).where(models.MilkRecord.animal_id.in_([m.id for m in members]))) > 0
        has_eggs = db.scalar(select(func.count(models.EggRecord.id)).where(models.EggRecord.flock_id == group.id)) > 0
        if has_milk:
            created.append(create_monitor(db, farm_id, subject_type="group", subject_id=group.id, production_metric_code="milk_l_per_day", user_id=user_id))
        if has_eggs:
            created.append(create_monitor(db, farm_id, subject_type="group", subject_id=group.id, production_metric_code="eggs_per_day", user_id=user_id))
    return created


# ------------------------------------------------------------- production
def daily_values(db: Session, subject_type: str, subject, metric: str, start: date, end: date) -> dict[date, float]:
    """Production per day between the dates, inclusive. Milk is litres per
    milked head per day (a herd of 3 and a herd of 30 compare on the same
    scale); eggs are the flock's eggs per day. A day with no record is
    absent — missing is not zero."""
    lo, hi = _start_of(start), _start_of(end + timedelta(days=1))
    out: dict[date, float] = {}
    if metric == "milk_l_per_day":
        ids = [a.id for a in _subject_animals(db, subject_type, subject)]
        if not ids:
            return out
        rows = db.execute(
            select(func.date(models.MilkRecord.recorded_at), func.sum(models.MilkRecord.liters), func.count(func.distinct(models.MilkRecord.animal_id)))
            .where(models.MilkRecord.animal_id.in_(ids), models.MilkRecord.recorded_at >= lo, models.MilkRecord.recorded_at < hi)
            .group_by(func.date(models.MilkRecord.recorded_at))
        ).all()
        for d, total, heads in rows:
            if heads:
                out[_as_date(d)] = round(float(total) / int(heads), 3)
    elif metric == "eggs_per_day" and subject_type == "group" and subject is not None:
        rows = db.execute(
            select(func.date(models.EggRecord.recorded_at), func.sum(models.EggRecord.total_eggs))
            .where(models.EggRecord.flock_id == subject.id, models.EggRecord.recorded_at >= lo, models.EggRecord.recorded_at < hi)
            .group_by(func.date(models.EggRecord.recorded_at))
        ).all()
        for d, total in rows:
            out[_as_date(d)] = float(total or 0)
    return out


def _milked_heads(db: Session, subject_type: str, subject, start: date, end: date) -> set[str]:
    ids = [a.id for a in _subject_animals(db, subject_type, subject)]
    if not ids:
        return set()
    return set(db.scalars(select(func.distinct(models.MilkRecord.animal_id)).where(
        models.MilkRecord.animal_id.in_(ids), models.MilkRecord.recorded_at >= _start_of(start), models.MilkRecord.recorded_at < _start_of(end + timedelta(days=1)),
    )))


# --------------------------------------------------------------- exposure
def _lineage(db: Session, lot: fm.FeedLot | None, product: fm.FeedProduct | None) -> dict:
    if lot is None:
        return {"feed_product": product.name if product else None, "lot": None}
    batch = db.get(fm.FeedBatch, lot.feed_batch_id) if lot.feed_batch_id else None
    ingredients = []
    if batch is not None:
        for c in batch.components:
            src = db.get(fm.FeedLot, c.lot_id) if c.lot_id else None
            comp = db.get(fm.FeedProduct, c.feed_product_id)
            ingredients.append({"feed_product_id": c.feed_product_id, "product_name": comp.name if comp else None, "lot_id": c.lot_id,
                                "lot_code": src.lot_code if src else None, "supplier_id": src.supplier_id if src else None,
                                "supplier_label": src.supplier_label if src else None, "actual_quantity": c.actual_quantity, "target_quantity": c.target_quantity})
    return {
        "feed_product": product.name if product else None, "lot_id": lot.id, "lot_code": lot.lot_code, "source_type": lot.source_type,
        "supplier_id": lot.supplier_id, "supplier_label": lot.supplier_label,
        "mix": None if batch is None else {"batch_id": batch.id, "mix_number": batch.mix_number, "mix_code": batch.mix_code,
                                           "formula_version_id": batch.formula_version_id, "production_date": batch.production_date.isoformat() if batch.production_date else None},
        "ingredient_lots": ingredients,
    }


def rebuild_exposures(db: Session, farm_id: str) -> list[fm.FeedExposureWindow]:
    """Projects the feeding events into exposure windows (§4): one per
    subject × product × lot, first issue to last. Rebuilt in full so it can
    never drift from the events it summarises."""
    db.execute(delete(fm.FeedExposureWindow).where(fm.FeedExposureWindow.farm_id == farm_id))
    events = db.scalars(select(fm.FeedingEvent).where(
        fm.FeedingEvent.farm_id == farm_id, fm.FeedingEvent.status == "recorded", fm.FeedingEvent.event_type.in_(("offered", "delivered")),
    ).order_by(fm.FeedingEvent.occurred_at)).all()
    agg: dict[tuple, dict] = {}
    for e in events:
        # Rows loaded from SQLite come back naive while rows created in this
        # session are aware; compare everything in UTC.
        at = ensure_utc(e.occurred_at)
        for c in e.components:
            key = (e.subject_type, e.subject_id, c.feed_product_id, c.lot_id)
            w = agg.setdefault(key, {"start": at, "end": at, "offered": 0.0, "consumed": 0.0, "consumed_known": False,
                                     "count": 0, "batch_id": c.batch_id})
            w["start"] = min(w["start"], at)
            w["end"] = max(w["end"], at)
            w["offered"] += c.quantity_offered
            if c.quantity_consumed is not None:
                w["consumed"] += c.quantity_consumed
                w["consumed_known"] = True
            w["count"] += 1
            w["batch_id"] = w["batch_id"] or c.batch_id
    rows = []
    cutoff = now() - timedelta(days=ONGOING_GAP_DAYS)
    for (stype, sid, pid, lot_id), w in agg.items():
        lot = db.get(fm.FeedLot, lot_id) if lot_id else None
        product = db.get(fm.FeedProduct, pid)
        row = fm.FeedExposureWindow(
            id=new_id(), farm_id=farm_id, subject_type=stype, subject_id=sid, feed_product_id=pid, lot_id=lot_id,
            feed_batch_id=w["batch_id"] or (lot.feed_batch_id if lot else None), exposure_start=w["start"],
            exposure_end=None if w["end"] >= cutoff else w["end"], offered_quantity=round(w["offered"], 3),
            consumed_estimate=round(w["consumed"], 3) if w["consumed_known"] else None, feeding_event_count=w["count"],
            lineage_json=_lineage(db, lot, product), generated_at=now(),
        )
        db.add(row)
        rows.append(row)
    db.flush()
    return rows


def exposures_for(db: Session, farm_id: str, subject_type: str | None = None, subject_id: str | None = None) -> list[fm.FeedExposureWindow]:
    stmt = select(fm.FeedExposureWindow).where(fm.FeedExposureWindow.farm_id == farm_id)
    if subject_type and subject_id:
        stmt = stmt.where(fm.FeedExposureWindow.subject_type == subject_type, fm.FeedExposureWindow.subject_id == subject_id)
    return list(db.scalars(stmt.order_by(fm.FeedExposureWindow.exposure_start.desc())))


def _feed_changes(db: Session, farm_id: str, subject_type: str, subject, group, since: datetime, until: datetime) -> list[dict]:
    """Lots first issued to the subject (or its group) in the lookback: the
    candidate feed changes an assessment lists, with their lineage."""
    keys = [(subject_type, subject.id)] + ([("group", group.id)] if group is not None else [])
    changes = []
    for stype, sid in keys:
        for w in exposures_for(db, farm_id, stype, sid):
            start = ensure_utc(w.exposure_start)
            if start < since or start > until:
                continue
            lineage = w.lineage_json or {}
            mix = lineage.get("mix") or {}
            batch = db.get(fm.FeedBatch, w.feed_batch_id) if w.feed_batch_id else None
            compliance = None
            if batch is not None and batch.status in ("completed", "quarantined"):
                devs = [abs(v["variance_pct"]) for v in batches.batch_variance(batch) if v.get("variance_pct") is not None]
                compliance = round(max(devs), 2) if devs else None
            changes.append({
                "subject_type": stype, "subject_id": sid, "feed_product_id": w.feed_product_id, "product_name": lineage.get("feed_product"),
                "lot_id": w.lot_id, "lot_code": lineage.get("lot_code"), "supplier_label": lineage.get("supplier_label"),
                "mix_code": mix.get("mix_code"), "mix_number": mix.get("mix_number"), "batch_id": w.feed_batch_id,
                "ingredient_lots": [{k: i.get(k) for k in ("product_name", "lot_code", "supplier_label")} for i in lineage.get("ingredient_lots", [])],
                "introduced_at": start.isoformat(), "days_of_exposure": round((min(until, ensure_utc(w.exposure_end) if w.exposure_end else until) - start).total_seconds() / 86400, 1),
                "offered_quantity": w.offered_quantity, "worst_component_deviation_pct": compliance,
            })
    changes.sort(key=lambda c: c["introduced_at"])
    return changes


# ------------------------------------------------------------ confounders
def _confounders(db: Session, subject_type: str, subject, group, period_start: date, period_end: date, baseline_start: date, baseline_end: date,
                 observed: dict[date, float]) -> dict:
    """What else could explain the change, from the facts this app holds
    (§6). Anything it cannot see is named as missing, so the confidence
    can drop for it rather than the gap passing as 'nothing changed'."""
    animals = _subject_animals(db, subject_type, subject)
    ids = [a.id for a in animals]
    lo, hi = _start_of(period_start - timedelta(days=CHANGE_LOOKBACK_DAYS)), _start_of(period_end + timedelta(days=1))
    health = 0
    if ids:
        health += db.scalar(select(func.count(models.Observation.id)).where(
            models.Observation.entity_type == "animal", models.Observation.entity_id.in_(ids),
            models.Observation.observed_at >= lo, models.Observation.observed_at < hi)) or 0
        health += db.scalar(select(func.count(models.Treatment.id)).where(
            models.Treatment.entity_type == "animal", models.Treatment.entity_id.in_(ids),
            models.Treatment.start_at >= lo, models.Treatment.start_at < hi)) or 0
        if subject_type == "group":
            health += db.scalar(select(func.count(models.Observation.id)).where(
                models.Observation.entity_type.in_(("flock", "group")), models.Observation.entity_id == subject.id,
                models.Observation.observed_at >= lo, models.Observation.observed_at < hi)) or 0
    withdrawal = sum(1 for a in animals if a.withdrawal_until and ensure_utc(a.withdrawal_until) >= lo)
    lactating = sum(1 for a in animals if a.lactating)
    pregnant = sum(1 for a in animals if a.pregnant)
    membership = "unavailable"
    if subject_type == "group" and animals:
        before = _milked_heads(db, subject_type, subject, baseline_start, baseline_end)
        after = _milked_heads(db, subject_type, subject, period_start, period_end)
        membership = "changed" if before and after and before != after else ("stable" if before and after else "unavailable")
    refusals = 0
    for stype, sid in [(subject_type, subject.id)] + ([("group", group.id)] if group is not None else []):
        refusals += db.scalar(select(func.count(fm.FeedingEvent.id)).where(
            fm.FeedingEvent.subject_type == stype, fm.FeedingEvent.subject_id == sid, fm.FeedingEvent.event_type == "refusal",
            fm.FeedingEvent.status == "recorded", fm.FeedingEvent.occurred_at >= _start_of(period_start), fm.FeedingEvent.occurred_at < hi)) or 0
    missing = list(CONTEXT_WE_CANNOT_SEE)
    if membership == "unavailable":
        missing.append("group_membership")
    return {
        "health_events": health, "animals_under_withdrawal": withdrawal, "lactating_heads": lactating, "pregnant_heads": pregnant,
        "head_count": len(animals), "milked_heads_change": membership, "refusal_events": refusals,
        "observation_days": len(observed), "missing_context": missing,
    }


# --------------------------------------------------------------- evaluate
def evaluate_monitor(db: Session, monitor: fm.FeedPerformanceMonitor, *, as_of: datetime | None = None, user_id: str = "system") -> fm.FeedPerformanceAssessment:
    """One assessment (§5): explicit baseline window, evaluation window,
    variance, persistence, the feed changes that preceded it, the
    confounders checked, a likelihood label and a confidence. Writes the
    assessment, raises or resolves the matching alert, and nothing else."""
    at = ensure_utc(as_of) if as_of else now()
    end_day = at.date()
    period_start = end_day - timedelta(days=monitor.evaluation_window_days - 1)
    baseline_end = period_start - timedelta(days=1)
    baseline_days = monitor.baseline_window_days if monitor.baseline_method_code == "rolling_subject" else monitor.evaluation_window_days
    baseline_start = baseline_end - timedelta(days=baseline_days - 1)

    subject = _subject(db, monitor.subject_type, monitor.subject_id)
    if subject is None:
        raise FeedError("The monitor's subject no longer exists.", 404)
    group = programs.group_for_animal(db, subject) if monitor.subject_type == "animal" else None
    observed = daily_values(db, monitor.subject_type, subject, monitor.production_metric_code, period_start, end_day)
    baseline = daily_values(db, monitor.subject_type, subject, monitor.production_metric_code, baseline_start, baseline_end)
    changes = _feed_changes(db, monitor.farm_id, monitor.subject_type, subject, group, _start_of(period_start - timedelta(days=CHANGE_LOOKBACK_DAYS)), at)
    confounders = _confounders(db, monitor.subject_type, subject, group, period_start, end_day, baseline_start, baseline_end, observed)
    unit = "L/head/day" if monitor.production_metric_code == "milk_l_per_day" else "eggs/day"
    evidence = {
        "metric": monitor.production_metric_code, "unit": unit, "baseline_method": monitor.baseline_method_code,
        "baseline_window": {"start": baseline_start.isoformat(), "end": baseline_end.isoformat(), "observation_days": len(baseline)},
        "evaluation_window": {"start": period_start.isoformat(), "end": end_day.isoformat(), "observation_days": len(observed)},
        "daily_baseline": {d.isoformat(): v for d, v in sorted(baseline.items())},
        "daily_observed": {d.isoformat(): v for d, v in sorted(observed.items())},
        "feed_changes": changes, "threshold_pct": monitor.alert_threshold_percent, "minimum_observations": monitor.minimum_observations,
    }
    name = subject.name
    min_obs = monitor.minimum_observations
    threshold = monitor.alert_threshold_percent

    if len(observed) < min_obs or len(baseline) < min_obs:
        status, likelihood, confidence = "insufficient", "INSUFFICIENT_EVIDENCE", 0.2
        baseline_value = _mean(baseline.values())
        observed_value = _mean(observed.values())
        variance = pct = None
        explanation = (f"{name}: not enough evidence to assess feed performance — {len(observed)} observation day(s) in the evaluation window "
                       f"and {len(baseline)} in the baseline; at least {min_obs} of each are needed. Missing data is treated as missing, not as no change.")
    else:
        baseline_value = _mean(baseline.values())
        observed_value = _mean(observed.values())
        variance = round(observed_value - baseline_value, 4)
        pct = round(variance / baseline_value * 100, 2) if baseline_value else None
        below = sum(1 for v in observed.values() if baseline_value and v < baseline_value * (1 - threshold / 100))
        above = sum(1 for v in observed.values() if baseline_value and v > baseline_value * (1 + threshold / 100))
        persistent_down = pct is not None and pct <= -threshold and below >= max(2, len(observed) - 1)
        persistent_up = pct is not None and pct >= threshold and above >= max(2, len(observed) - 1)
        anomaly = persistent_down or persistent_up
        exposed_enough = [c for c in changes if c["days_of_exposure"] >= (monitor.minimum_exposure_days or 0)]
        if anomaly and exposed_enough:
            clean = confounders["health_events"] == 0 and confounders["milked_heads_change"] != "changed" and confounders["refusal_events"] == 0
            likelihood = "HIGH" if clean and len(exposed_enough) == 1 else "MODERATE"
        elif anomaly:
            likelihood = "LOW"
        else:
            likelihood = "LOW"
        status = "anomaly" if anomaly else "normal"
        confidence = 0.9
        confidence -= 0.06 * len(confounders["missing_context"])
        if confounders["health_events"]:
            confidence -= 0.1
        if confounders["milked_heads_change"] == "changed":
            confidence -= 0.1
        if len(observed) < 2 * min_obs:
            confidence -= 0.1
        if len(baseline) < 2 * min_obs:
            confidence -= 0.05
        confidence = round(_clamp(confidence, 0.1, 0.95), 2)
        direction = "below" if (pct or 0) < 0 else "above"
        lines = [f"{name}: {monitor.production_metric_code.replace('_', ' ')} is {abs(pct or 0):.1f}% {direction} the {monitor.baseline_method_code.replace('_', ' ')} baseline "
                 f"({observed_value:.2f} vs {baseline_value:.2f} {unit}) over {len(observed)} day(s)" + (", and persistently so." if anomaly else "; within the threshold.")]
        if exposed_enough:
            c = exposed_enough[-1]
            what = c["mix_code"] or c["lot_code"] or c["product_name"]
            lines.append(f"Relevant change: {c['product_name']} {what} introduced {c['days_of_exposure']:.0f} day(s) before the end of the period"
                         + (f" from {c['supplier_label']}" if c.get("supplier_label") else "") + ".")
            if c["ingredient_lots"]:
                lines.append("It contains " + ", ".join(f"{i['product_name']} lot {i['lot_code']}" + (f" ({i['supplier_label']})" if i.get("supplier_label") else "") for i in c["ingredient_lots"] if i.get("lot_code")) + ".")
            if c["worst_component_deviation_pct"] is not None:
                lines.append(f"Formula compliance: largest component deviation {c['worst_component_deviation_pct']:.1f}%" + (" — a manufacturing deviation, to be separated from any ingredient question." if c["worst_component_deviation_pct"] > COMPLIANCE_TOLERANCE_PCT else " (within tolerance)."))
        elif changes:
            lines.append("A feed change exists but the exposure is shorter than the monitor's minimum, so it is not counted as explanatory yet.")
        else:
            lines.append("No feed change recorded in the lookback window.")
        checks = [f"health events among the animals: {confounders['health_events']}", f"milked heads: {confounders['milked_heads_change']}",
                  f"refusals: {confounders['refusal_events']}", f"lactating {confounders['lactating_heads']}/{confounders['head_count']}, pregnant {confounders['pregnant_heads']}"]
        lines.append("Checks: " + "; ".join(checks) + ". Not available: " + ", ".join(confounders["missing_context"]).replace("_", " ") + ".")
        lines.append(f"Feed-related likelihood {likelihood} (an association, not a cause), confidence {confidence:.2f}.")
        explanation = " ".join(lines)

    assessment = fm.FeedPerformanceAssessment(
        id=new_id(), farm_id=monitor.farm_id, monitor_id=monitor.id, evaluated_at=at, period_start=_start_of(period_start), period_end=_start_of(end_day + timedelta(days=1)),
        baseline_value=baseline_value, observed_value=observed_value, variance_value=variance, variance_percent=pct,
        feed_related_likelihood=likelihood, confidence_score=confidence, model_reference=MODEL_REFERENCE, model_version=MODEL_VERSION,
        evidence_json=evidence, confounders_json=confounders, explanation=explanation, status=status,
    )
    db.add(assessment)
    db.flush()
    write_event(db, farm_id=monitor.farm_id, entity_type=monitor.subject_type, entity_id=monitor.subject_id, event_type="feed_performance_evaluated",
                payload={"assessment_id": assessment.id, "monitor_id": monitor.id, "status": status, "variance_pct": pct, "likelihood": likelihood, "confidence": confidence},
                created_by=user_id)

    # Alerts: raised for a persistent change with a feed change behind it,
    # kept while it holds, resolved when it clears.
    decline_key = f"{monitor.id}|PRODUCTION_DECLINE_AFTER_FEED_CHANGE"
    improve_key = f"{monitor.id}|FEED_PERFORMANCE_IMPROVEMENT"
    if status == "anomaly" and likelihood in ("MODERATE", "HIGH"):
        alert_type = "PRODUCTION_DECLINE_AFTER_FEED_CHANGE" if (pct or 0) < 0 else "FEED_PERFORMANCE_IMPROVEMENT"
        key = decline_key if alert_type == "PRODUCTION_DECLINE_AFTER_FEED_CHANGE" else improve_key
        change = next((c for c in reversed(changes) if c["days_of_exposure"] >= (monitor.minimum_exposure_days or 0)), None)
        severity = ("high" if likelihood == "HIGH" else "medium") if alert_type == "PRODUCTION_DECLINE_AFTER_FEED_CHANGE" else "info"
        upsert_alert(
            db, monitor.farm_id, alert_type=alert_type, severity=severity,
            title=f"{'Production decline' if alert_type.startswith('PRODUCTION') else 'Production improvement'} after feed change — {name}",
            explanation=explanation, evidence={"assessment_id": assessment.id, "change": change, "variance_pct": pct}, confidence=confidence,
            dedup_key=key, assessment_id=assessment.id, feed_batch_id=change["batch_id"] if change else None,
            feed_product_id=change["feed_product_id"] if change else None, subject_type=monitor.subject_type, subject_id=monitor.subject_id,
            review_task=(likelihood == "HIGH" and alert_type == "PRODUCTION_DECLINE_AFTER_FEED_CHANGE"), user_id=user_id,
        )
        resolve_alerts(db, monitor.farm_id, dedup_key=improve_key if key == decline_key else decline_key, reason="condition reversed", user_id=user_id)
    elif status == "normal":
        resolve_alerts(db, monitor.farm_id, dedup_key=decline_key, reason="production back within the threshold", user_id=user_id)
        resolve_alerts(db, monitor.farm_id, dedup_key=improve_key, reason="production back within the threshold", user_id=user_id)
    return assessment


# ------------------------------------------------------------------ alerts
def upsert_alert(db: Session, farm_id: str, *, alert_type: str, severity: str, title: str, explanation: str, evidence: dict, confidence: float | None,
                 dedup_key: str, assessment_id: str | None = None, feed_batch_id: str | None = None, feed_product_id: str | None = None,
                 subject_type: str | None = None, subject_id: str | None = None, review_task: bool = False, user_id: str = "system") -> tuple[fm.FeedPerformanceAlert, bool]:
    """One open alert per condition (§11): a repeat evaluation refreshes
    it instead of raising a twin. Returns (alert, created)."""
    if alert_type not in ALERT_TYPES:
        raise FeedError(f"alert_type must be one of {list(ALERT_TYPES)}")
    existing = db.scalar(select(fm.FeedPerformanceAlert).where(
        fm.FeedPerformanceAlert.farm_id == farm_id, fm.FeedPerformanceAlert.deduplication_key == dedup_key, fm.FeedPerformanceAlert.status != "resolved",
    ))
    if existing is not None:
        existing.explanation = explanation
        existing.evidence_json = evidence
        existing.confidence_score = confidence
        existing.severity = severity
        existing.last_seen_at = now()
        existing.assessment_id = assessment_id or existing.assessment_id
        return existing, False
    alert = fm.FeedPerformanceAlert(
        id=new_id(), farm_id=farm_id, assessment_id=assessment_id, feed_batch_id=feed_batch_id, feed_product_id=feed_product_id,
        subject_type=subject_type, subject_id=subject_id, alert_type=alert_type, severity=severity, detected_at=now(), last_seen_at=now(),
        title=title[:200], explanation=explanation, evidence_json=evidence, confidence_score=confidence, status="open", deduplication_key=dedup_key,
    )
    db.add(alert)
    db.flush()
    entity_type, entity_id = _alert_entity(alert)
    write_event(db, farm_id=farm_id, entity_type=entity_type, entity_id=entity_id, event_type="feed_performance_anomaly_detected",
                payload={"alert_id": alert.id, "alert_type": alert_type, "severity": severity, "confidence": confidence}, created_by=user_id)
    if review_task:
        task = models.Task(
            id=new_id(), farm_id=farm_id, title=f"Review feed performance: {title[:160]}", description=explanation[:1500],
            due_at=now() + timedelta(days=1), priority="high", status="open", source_type="feed_performance_review", source_id=alert.id,
        )
        db.add(task)
        write_event(db, farm_id=farm_id, entity_type=entity_type, entity_id=entity_id, event_type="feed_performance_review_required",
                    payload={"alert_id": alert.id, "task_id": task.id}, created_by=user_id)
    return alert, True


def _alert_entity(alert: fm.FeedPerformanceAlert) -> tuple[str, str]:
    if alert.feed_batch_id:
        return "feed_batch", alert.feed_batch_id
    if alert.subject_type and alert.subject_id:
        return alert.subject_type, alert.subject_id
    if alert.feed_product_id:
        return "feed_product", alert.feed_product_id
    return "farm", alert.farm_id


def resolve_alerts(db: Session, farm_id: str, *, dedup_key: str, reason: str, user_id: str = "system") -> list[fm.FeedPerformanceAlert]:
    rows = db.scalars(select(fm.FeedPerformanceAlert).where(
        fm.FeedPerformanceAlert.farm_id == farm_id, fm.FeedPerformanceAlert.deduplication_key == dedup_key, fm.FeedPerformanceAlert.status != "resolved",
    )).all()
    for a in rows:
        a.status = "resolved"
        a.resolved_at = now()
        a.resolution_note = reason
        entity_type, entity_id = _alert_entity(a)
        write_event(db, farm_id=farm_id, entity_type=entity_type, entity_id=entity_id, event_type="feed_performance_recovered",
                    payload={"alert_id": a.id, "alert_type": a.alert_type, "reason": reason}, created_by=user_id)
        for t in db.scalars(select(models.Task).where(models.Task.source_type == "feed_performance_review", models.Task.source_id == a.id, models.Task.status == "open")):
            t.status = "done"
    return rows


def acknowledge_alert(db: Session, alert: fm.FeedPerformanceAlert, *, user_id: str) -> fm.FeedPerformanceAlert:
    """Records that a person saw it. The condition is untouched — the
    alert resolves only when the evidence does (§11)."""
    if alert.status == "resolved":
        raise FeedError("This alert is already resolved.")
    alert.status = "acknowledged"
    alert.acknowledged_by = user_id
    alert.acknowledged_at = now()
    return alert


def resolve_alert_manually(db: Session, alert: fm.FeedPerformanceAlert, *, note: str | None, user_id: str) -> fm.FeedPerformanceAlert:
    if alert.status == "resolved":
        raise FeedError("This alert is already resolved.")
    if not note or not note.strip():
        raise FeedError("Say why this alert is being closed — the evidence has not changed.")
    alert.status = "resolved"
    alert.resolved_at = now()
    alert.resolution_note = note.strip()
    entity_type, entity_id = _alert_entity(alert)
    write_event(db, farm_id=alert.farm_id, entity_type=entity_type, entity_id=entity_id, event_type="feed_performance_recovered",
                payload={"alert_id": alert.id, "alert_type": alert.alert_type, "reason": note, "manual": True}, created_by=user_id)
    return alert


# ---------------------------------------------------------- batch scores
def score_batch(db: Session, batch: fm.FeedBatch, *, user_id: str = "system") -> fm.FeedBatchPerformanceScore | None:
    """The numbered mix's score card (§7, §8): formula compliance from
    actual vs target, intake from refusals, production response from the
    assessments of the animals it was fed to, health signal from their
    health events during the exposure, consistency from the day-to-day
    spread, economics against the farm's other mixes of the same feed.
    A dimension with no evidence is null and lowers the confidence; it is
    never scored as perfect."""
    if batch.status not in ("completed", "quarantined"):
        return None
    usage = batches.mix_usage(db, batch)
    variance = usage["variance"]
    devs = [abs(v["variance_pct"]) for v in variance if v.get("variance_pct") is not None]
    compliance = round(_clamp(1 - (statistics.fmean(devs) / (2 * COMPLIANCE_TOLERANCE_PCT))), 4) if devs else None
    issued, refused = usage["issued_quantity"], usage["refused_quantity"]
    intake = round(_clamp(1 - refused / issued), 4) if issued > 0 else None
    first_use = ensure_utc(usage["first_use_at"]) if usage["first_use_at"] else None
    last_use = ensure_utc(usage["last_use_at"]) if usage["last_use_at"] else None
    exposure_days = usage["days_used"]

    responses, health_events, daily_series, exposed_heads = [], 0, [], 0
    for s in usage["exposed_subjects"]:
        subject = _subject(db, s["subject_type"], s["subject_id"])
        if subject is None:
            continue
        animals = _subject_animals(db, s["subject_type"], subject)
        exposed_heads += len(animals) if animals else (getattr(subject, "count", 1) or 1)
        monitors = db.scalars(select(fm.FeedPerformanceMonitor).where(
            fm.FeedPerformanceMonitor.farm_id == batch.farm_id, fm.FeedPerformanceMonitor.subject_type == s["subject_type"], fm.FeedPerformanceMonitor.subject_id == s["subject_id"],
        )).all()
        for m in monitors:
            latest = db.scalar(select(fm.FeedPerformanceAssessment).where(
                fm.FeedPerformanceAssessment.monitor_id == m.id, fm.FeedPerformanceAssessment.status != "insufficient",
                fm.FeedPerformanceAssessment.period_end >= (first_use or ensure_utc(batch.started_at)),
            ).order_by(fm.FeedPerformanceAssessment.evaluated_at.desc()))
            if latest is not None and latest.variance_percent is not None:
                responses.append(latest.variance_percent)
            if first_use is not None:
                series = daily_values(db, s["subject_type"], subject, m.production_metric_code, first_use.date(), (last_use or now()).date())
                if len(series) >= 3:
                    daily_series.append(list(series.values()))
        if animals and first_use is not None:
            ids = [a.id for a in animals]
            hi = (last_use or now()) + timedelta(days=1)
            health_events += db.scalar(select(func.count(models.Observation.id)).where(
                models.Observation.entity_type == "animal", models.Observation.entity_id.in_(ids), models.Observation.observed_at >= first_use, models.Observation.observed_at < hi)) or 0
            health_events += db.scalar(select(func.count(models.Treatment.id)).where(
                models.Treatment.entity_type == "animal", models.Treatment.entity_id.in_(ids), models.Treatment.start_at >= first_use, models.Treatment.start_at < hi)) or 0
    production = round(_clamp(0.5 + statistics.fmean(responses) / 20), 4) if responses else None
    health = None if not usage["exposed_subjects"] or first_use is None else (1.0 if health_events == 0 else (0.7 if health_events <= 2 else 0.4))
    consistency = None
    cvs = []
    for series in daily_series:
        m = statistics.fmean(series)
        if m:
            cvs.append(statistics.pstdev(series) / m)
    if cvs:
        consistency = round(_clamp(1 - 2 * statistics.fmean(cvs)), 4)
    economic = None
    peers = db.scalars(select(fm.FeedBatch.unit_cost).where(
        fm.FeedBatch.farm_id == batch.farm_id, fm.FeedBatch.feed_product_id == batch.feed_product_id, fm.FeedBatch.status.in_(("completed", "quarantined")),
        fm.FeedBatch.unit_cost.is_not(None), fm.FeedBatch.id != batch.id,
    )).all()
    if batch.unit_cost is not None and peers:
        avg = statistics.fmean(peers)
        economic = round(_clamp(1 - (batch.unit_cost - avg) / avg), 4) if avg else None
    dims = {"formula_compliance": compliance, "intake_response": intake, "production_response": production, "health_signal": health,
            "consistency": consistency, "economic": economic}
    available = [v for v in dims.values() if v is not None]
    overall = round(statistics.fmean(available), 4) if available else None
    confidence = round(_clamp((len(available) / len(dims)) * min(1.0, 0.3 + (exposure_days or 0) / 7)), 2)
    evidence = {
        "mix_code": batch.mix_code, "dimensions_available": [k for k, v in dims.items() if v is not None],
        "component_deviations_pct": {v["feed_product_id"]: v.get("variance_pct") for v in variance}, "worst_component_deviation_pct": max(devs) if devs else None,
        "issued_quantity": issued, "refused_quantity": refused, "production_responses_pct": responses, "health_events_during_exposure": health_events,
        "daily_series_count": len(daily_series), "peer_unit_costs": peers, "unit_cost": batch.unit_cost, "exposed_subjects": [s["subject_id"] for s in usage["exposed_subjects"]],
        "model_reference": MODEL_REFERENCE, "model_version": MODEL_VERSION,
    }
    row = db.get(fm.FeedBatchPerformanceScore, batch.id)
    if row is None:
        row = fm.FeedBatchPerformanceScore(feed_batch_id=batch.id, farm_id=batch.farm_id)
        db.add(row)
    row.evaluated_at = now()
    row.exposed_head_count = exposed_heads or None
    row.exposure_days = float(exposure_days) if exposure_days else None
    row.formula_compliance_score = compliance
    row.intake_response_score = intake
    row.production_response_score = production
    row.health_signal_score = health
    row.consistency_score = consistency
    row.economic_score = economic
    row.overall_score = overall
    row.confidence_score = confidence
    row.evidence_json = evidence
    db.flush()
    write_event(db, farm_id=batch.farm_id, entity_type="feed_batch", entity_id=batch.id, event_type="feed_batch_performance_updated",
                payload={"mix_code": batch.mix_code, "overall_score": overall, "confidence": confidence, "dimensions": [k for k, v in dims.items() if v is not None]},
                created_by=user_id)
    # Manufacturing deviation is its own finding, kept apart from any
    # question about an ingredient's quality (§8).
    worst = max(devs) if devs else None
    key = f"{batch.id}|FORMULA_COMPLIANCE_DEVIATION"
    if worst is not None and worst > COMPLIANCE_TOLERANCE_PCT:
        offenders = [f"{inv.get_product(db, v['feed_product_id'], batch.farm_id).name} {v['variance_pct']:+.1f}%" for v in variance if v.get("variance_pct") is not None and abs(v["variance_pct"]) > COMPLIANCE_TOLERANCE_PCT]
        _, created = upsert_alert(
            db, batch.farm_id, alert_type="FORMULA_COMPLIANCE_DEVIATION", severity="high" if worst > 2 * COMPLIANCE_TOLERANCE_PCT else "medium",
            title=f"Formula deviation in {batch.mix_code}", explanation=f"{batch.mix_code} was mixed off its formula: {', '.join(offenders)} against target "
            f"(tolerance ±{COMPLIANCE_TOLERANCE_PCT:.0f}%). This is a manufacturing deviation; any production change after this mix should be read with it in mind before an ingredient or supplier is questioned.",
            evidence={"component_deviations_pct": evidence["component_deviations_pct"], "tolerance_pct": COMPLIANCE_TOLERANCE_PCT}, confidence=0.95,
            dedup_key=key, feed_batch_id=batch.id, feed_product_id=batch.feed_product_id, user_id=user_id,
        )
        if created:
            write_event(db, farm_id=batch.farm_id, entity_type="feed_batch", entity_id=batch.id, event_type="formula_compliance_deviation_detected",
                        payload={"mix_code": batch.mix_code, "worst_deviation_pct": worst}, created_by=user_id)
    return row


def score_all_batches(db: Session, farm_id: str, *, user_id: str = "system") -> list[fm.FeedBatchPerformanceScore]:
    rows = []
    for b in db.scalars(select(fm.FeedBatch).where(fm.FeedBatch.farm_id == farm_id, fm.FeedBatch.status.in_(("completed", "quarantined")))):
        r = score_batch(db, b, user_id=user_id)
        if r is not None:
            rows.append(r)
    return rows


def batch_score_dict(db: Session, row: fm.FeedBatchPerformanceScore) -> dict:
    batch = db.get(fm.FeedBatch, row.feed_batch_id)
    alerts = db.scalars(select(fm.FeedPerformanceAlert).where(
        fm.FeedPerformanceAlert.feed_batch_id == row.feed_batch_id, fm.FeedPerformanceAlert.status != "resolved")).all()
    return {
        "feed_batch_id": row.feed_batch_id, "mix_number": batch.mix_number if batch else None, "mix_code": batch.mix_code if batch else None,
        "batch_code": batch.batch_code if batch else None, "product_name": inv.get_product(db, batch.feed_product_id, batch.farm_id).name if batch else None,
        "status": batch.status if batch else None, "produced_at": batch.produced_at if batch else None,
        "evaluated_at": row.evaluated_at, "exposed_head_count": row.exposed_head_count, "exposure_days": row.exposure_days,
        "formula_compliance_score": row.formula_compliance_score, "intake_response_score": row.intake_response_score,
        "production_response_score": row.production_response_score, "health_signal_score": row.health_signal_score,
        "consistency_score": row.consistency_score, "economic_score": row.economic_score, "overall_score": row.overall_score,
        "confidence_score": row.confidence_score, "evidence": row.evidence_json,
        "open_alerts": [{"id": a.id, "alert_type": a.alert_type, "severity": a.severity, "status": a.status, "title": a.title} for a in alerts],
    }


def batch_performance_summary(db: Session, batch: fm.FeedBatch) -> dict | None:
    row = db.get(fm.FeedBatchPerformanceScore, batch.id)
    if row is None:
        alerts = db.scalars(select(fm.FeedPerformanceAlert).where(fm.FeedPerformanceAlert.feed_batch_id == batch.id, fm.FeedPerformanceAlert.status != "resolved")).all()
        if not alerts:
            return None
        return {"overall_score": None, "confidence_score": None, "open_alerts": [{"id": a.id, "alert_type": a.alert_type, "severity": a.severity, "title": a.title} for a in alerts]}
    d = batch_score_dict(db, row)
    return {k: d[k] for k in ("overall_score", "confidence_score", "formula_compliance_score", "production_response_score", "intake_response_score",
                              "health_signal_score", "economic_score", "open_alerts", "evaluated_at")}


# --------------------------------------------------------------- suppliers
def supplier_performance(db: Session, farm_id: str, *, days: int = 90, user_id: str = "system") -> list[fm.SupplierFeedPerformance]:
    """Supplier × ingredient from the supplier's lots in the period (§9):
    what was bought and at what cost, how many mixes used it, incidents on
    those lots, and the production response of the mixes downstream of
    them. Rebuilt whole; different ingredients from one supplier stay
    separate rows."""
    since = now() - timedelta(days=days)
    db.execute(delete(fm.SupplierFeedPerformance).where(fm.SupplierFeedPerformance.farm_id == farm_id))
    lots = db.scalars(select(fm.FeedLot).where(fm.FeedLot.farm_id == farm_id, fm.FeedLot.source_type == "purchased", fm.FeedLot.received_at >= since)).all()
    groups: dict[tuple, list[fm.FeedLot]] = {}
    for lot in lots:
        label = lot.supplier_label or (db.get(models.Supplier, lot.supplier_id).name if lot.supplier_id and db.get(models.Supplier, lot.supplier_id) else None)
        if not label:
            continue
        groups.setdefault((lot.supplier_id, label, lot.feed_product_id), []).append(lot)
    rows = []
    for (supplier_id, label, product_id), lot_rows in groups.items():
        product = db.get(fm.FeedProduct, product_id)
        lot_ids = [l.id for l in lot_rows]
        batch_ids = set(db.scalars(select(fm.FeedBatchComponent.batch_id).where(fm.FeedBatchComponent.lot_id.in_(lot_ids))))
        qty = sum(l.accepted_quantity or 0 for l in lot_rows)
        costed = [(l.accepted_quantity or 0, l.unit_cost) for l in lot_rows if l.unit_cost is not None and l.accepted_quantity]
        avg_cost = round(sum(q * c for q, c in costed) / sum(q for q, _ in costed), 4) if costed else None
        incidents = sum(1 for l in lot_rows if l.status in ("quarantined", "blocked", "recalled") or (l.rejected_quantity or 0) > 0)
        scores = [db.get(fm.FeedBatchPerformanceScore, b) for b in batch_ids]
        downstream = _mean(s.production_response_score for s in scores if s is not None)
        overall_mix = _mean(s.overall_score for s in scores if s is not None)
        # Quality consistency from lab profiles on these lots, when there are
        # at least two to compare.
        profiles = db.scalars(select(fm.FeedNutrientProfile).where(
            fm.FeedNutrientProfile.subject_type == "feed_lot", fm.FeedNutrientProfile.subject_id.in_(lot_ids), fm.FeedNutrientProfile.source_type == "lab")).all()
        quality = None
        cp = []
        for p in profiles:
            for v in p.values:
                if v.nutrient_code.upper() in ("CP", "CRUDE_PROTEIN"):
                    cp.append(v.value)
        if len(cp) >= 2 and statistics.fmean(cp):
            quality = round(_clamp(1 - 3 * statistics.pstdev(cp) / statistics.fmean(cp)), 4)
        confidence = round(_clamp(min(1.0, len(lot_rows) / 3) * (0.4 + 0.6 * (1 if downstream is not None else 0))), 2)
        row = fm.SupplierFeedPerformance(
            id=new_id(), farm_id=farm_id, supplier_id=supplier_id, supplier_label=label, inventory_item_id=product.inventory_item_id, feed_product_id=product_id,
            evaluation_start=since, evaluation_end=now(), lot_count=len(lot_rows), feed_batch_count=len(batch_ids), purchase_quantity=round(qty, 3),
            average_unit_cost=avg_cost, quality_consistency_score=quality, downstream_performance_score=downstream, incident_count=incidents,
            confidence_score=confidence, methodology_code="deterministic_lot_lineage", methodology_version=MODEL_VERSION,
            evidence_json={"lots": [{"lot_id": l.id, "lot_code": l.lot_code, "status": l.status, "accepted_quantity": l.accepted_quantity, "rejected_quantity": l.rejected_quantity,
                                     "unit_cost": l.unit_cost, "received_at": l.received_at.isoformat() if l.received_at else None} for l in lot_rows],
                           "batches": sorted(batch_ids), "downstream_overall_score": overall_mix, "lab_profiles": len(profiles), "unit": product.unit},
            generated_at=now(),
        )
        db.add(row)
        rows.append(row)
    db.flush()
    if rows:
        write_event(db, farm_id=farm_id, entity_type="farm", entity_id=farm_id, event_type="supplier_feed_performance_updated",
                    payload={"rows": len(rows), "days": days}, created_by=user_id)
    return rows


def supplier_row_dict(db: Session, r: fm.SupplierFeedPerformance) -> dict:
    product = db.get(fm.FeedProduct, r.feed_product_id)
    return {
        "id": r.id, "supplier_id": r.supplier_id, "supplier_label": r.supplier_label, "feed_product_id": r.feed_product_id, "product_name": product.name if product else None,
        "inventory_item_id": r.inventory_item_id, "evaluation_start": r.evaluation_start, "evaluation_end": r.evaluation_end, "lot_count": r.lot_count,
        "feed_batch_count": r.feed_batch_count, "purchase_quantity": r.purchase_quantity, "unit": (r.evidence_json or {}).get("unit"), "average_unit_cost": r.average_unit_cost,
        "quality_consistency_score": r.quality_consistency_score, "downstream_performance_score": r.downstream_performance_score, "incident_count": r.incident_count,
        "confidence_score": r.confidence_score, "methodology_code": r.methodology_code, "methodology_version": r.methodology_version, "evidence": r.evidence_json, "generated_at": r.generated_at,
    }


# -------------------------------------------------- cost and intake checks
def _cost_per_litre(db: Session, farm_id: str, start: datetime, end: datetime) -> float | None:
    cost = db.scalar(select(func.sum(fm.FeedingEvent.total_cost)).where(
        fm.FeedingEvent.farm_id == farm_id, fm.FeedingEvent.status == "recorded", fm.FeedingEvent.occurred_at >= start, fm.FeedingEvent.occurred_at < end)) or 0
    animal_ids = db.scalars(select(models.Animal.id).where(models.Animal.farm_id == farm_id)).all()
    litres = db.scalar(select(func.sum(models.MilkRecord.liters)).where(
        models.MilkRecord.animal_id.in_(animal_ids), models.MilkRecord.recorded_at >= start, models.MilkRecord.recorded_at < end)) if animal_ids else 0
    if not litres or not cost:
        return None
    return round(float(cost) / float(litres), 4)


def check_cost_efficiency(db: Session, farm_id: str, *, user_id: str = "system") -> dict:
    """Feed cost per litre, this week against last (§10). A rise beyond the
    threshold is an alert with both figures; a fall resolves it."""
    end = now()
    this = _cost_per_litre(db, farm_id, end - timedelta(days=7), end)
    prev = _cost_per_litre(db, farm_id, end - timedelta(days=14), end - timedelta(days=7))
    change = round((this - prev) / prev * 100, 2) if this is not None and prev else None
    key = "farm|FEED_COST_PER_OUTPUT_INCREASE"
    if change is not None and change > COST_INCREASE_ALERT_PCT:
        _, created = upsert_alert(
            db, farm_id, alert_type="FEED_COST_PER_OUTPUT_INCREASE", severity="medium", title="Feed cost per litre is rising",
            explanation=f"Feed cost per litre of milk is ${this:.3f} this week against ${prev:.3f} last week ({change:+.1f}%). Check the mixes and lots introduced this week and the milk recorded against them.",
            evidence={"cost_per_litre_this_week": this, "cost_per_litre_last_week": prev, "change_pct": change}, confidence=0.7, dedup_key=key, user_id=user_id,
        )
        if created:
            write_event(db, farm_id=farm_id, entity_type="farm", entity_id=farm_id, event_type="feed_cost_efficiency_changed",
                        payload={"this_week": this, "last_week": prev, "change_pct": change}, created_by=user_id)
    elif change is not None:
        resolve_alerts(db, farm_id, dedup_key=key, reason="cost per litre back within range", user_id=user_id)
    return {"cost_per_litre_this_week": this, "cost_per_litre_last_week": prev, "change_pct": change}


def check_intake(db: Session, farm_id: str, *, user_id: str = "system") -> list[fm.FeedPerformanceAlert]:
    since = now() - timedelta(days=3)
    rows = db.execute(
        select(fm.FeedingEvent.subject_type, fm.FeedingEvent.subject_id, func.count(fm.FeedingEvent.id))
        .where(fm.FeedingEvent.farm_id == farm_id, fm.FeedingEvent.event_type == "refusal", fm.FeedingEvent.status == "recorded", fm.FeedingEvent.occurred_at >= since)
        .group_by(fm.FeedingEvent.subject_type, fm.FeedingEvent.subject_id)
    ).all()
    out = []
    for stype, sid, count in rows:
        if count < REFUSALS_FOR_ALERT:
            continue
        subject = _subject(db, stype, sid)
        name = getattr(subject, "name", sid)
        alert, _ = upsert_alert(
            db, farm_id, alert_type="INTAKE_OR_REFUSAL_ANOMALY", severity="medium", title=f"Repeated refusals — {name}",
            explanation=f"{name} refused feed {count} times in the last 3 days. Compare offered against eaten and check the lots being issued before reading any production change as feed quality.",
            evidence={"refusals_3d": count}, confidence=0.8, dedup_key=f"{stype}:{sid}|INTAKE_OR_REFUSAL_ANOMALY", subject_type=stype, subject_id=sid, user_id=user_id,
        )
        out.append(alert)
    return out


# ------------------------------------------------------------------ cycle
def run_cycle(db: Session, farm_id: str, *, as_of: datetime | None = None, monitor_id: str | None = None, user_id: str = "system") -> dict:
    """The daily feed-performance cycle (§12): default monitors, fresh
    exposure projection, every active monitor evaluated, mixes and
    suppliers scored, cost and intake checked. Idempotent — alerts are
    deduplicated and projections rebuilt."""
    ensure_default_monitors(db, farm_id, user_id=user_id)
    rebuild_exposures(db, farm_id)
    stmt = select(fm.FeedPerformanceMonitor).where(fm.FeedPerformanceMonitor.farm_id == farm_id, fm.FeedPerformanceMonitor.active.is_(True))
    if monitor_id:
        stmt = stmt.where(fm.FeedPerformanceMonitor.id == monitor_id)
    assessments = [evaluate_monitor(db, m, as_of=as_of, user_id=user_id) for m in db.scalars(stmt)]
    scores = score_all_batches(db, farm_id, user_id=user_id)
    suppliers = supplier_performance(db, farm_id, user_id=user_id)
    cost = check_cost_efficiency(db, farm_id, user_id=user_id)
    intake = check_intake(db, farm_id, user_id=user_id)
    open_alerts = db.scalar(select(func.count(fm.FeedPerformanceAlert.id)).where(fm.FeedPerformanceAlert.farm_id == farm_id, fm.FeedPerformanceAlert.status != "resolved")) or 0
    return {
        "evaluated_at": (ensure_utc(as_of) if as_of else now()), "monitors": len(assessments),
        "assessments": [assessment_dict(db, a) for a in assessments], "anomalies": sum(1 for a in assessments if a.status == "anomaly"),
        "insufficient": sum(1 for a in assessments if a.status == "insufficient"), "batches_scored": len(scores), "suppliers": len(suppliers),
        "cost_efficiency": cost, "intake_alerts": len(intake), "open_alerts": open_alerts,
    }


# ---------------------------------------------------------- hooks & views
def on_batch_completed(db: Session, batch: fm.FeedBatch, *, user_id: str) -> None:
    score_batch(db, batch, user_id=user_id)


def on_production_recorded(db: Session, subject_type: str, subject, *, user_id: str) -> None:
    """After a milk or egg record: re-evaluate the monitors of the subject
    and of its group. Cheap, and it keeps alerts current between cycles."""
    keys = [(subject_type, subject.id)]
    if subject_type == "animal":
        group = programs.group_for_animal(db, subject)
        if group is not None:
            keys.append(("group", group.id))
    monitors = []
    for stype, sid in keys:
        monitors += db.scalars(select(fm.FeedPerformanceMonitor).where(
            fm.FeedPerformanceMonitor.farm_id == subject.farm_id, fm.FeedPerformanceMonitor.subject_type == stype,
            fm.FeedPerformanceMonitor.subject_id == sid, fm.FeedPerformanceMonitor.active.is_(True))).all()
    if not monitors:
        return
    rebuild_exposures(db, subject.farm_id)
    for m in monitors:
        evaluate_monitor(db, m, user_id=user_id)


def monitor_dict(db: Session, m: fm.FeedPerformanceMonitor) -> dict:
    subject = _subject(db, m.subject_type, m.subject_id)
    latest = db.scalar(select(fm.FeedPerformanceAssessment).where(fm.FeedPerformanceAssessment.monitor_id == m.id).order_by(fm.FeedPerformanceAssessment.evaluated_at.desc()))
    return {
        "id": m.id, "farm_id": m.farm_id, "subject_type": m.subject_type, "subject_id": m.subject_id, "subject_name": getattr(subject, "name", None),
        "species": getattr(subject, "species", None), "production_metric_code": m.production_metric_code, "baseline_method_code": m.baseline_method_code,
        "baseline_window_days": m.baseline_window_days, "evaluation_window_days": m.evaluation_window_days, "evaluation_frequency_code": m.evaluation_frequency_code,
        "minimum_exposure_days": m.minimum_exposure_days, "minimum_observations": m.minimum_observations, "alert_threshold_percent": m.alert_threshold_percent,
        "active": m.active, "configuration": m.configuration_json, "created_at": m.created_at, "updated_at": m.updated_at,
        "latest_assessment": assessment_dict(db, latest) if latest else None,
    }


def assessment_dict(db: Session, a: fm.FeedPerformanceAssessment) -> dict:
    monitor = db.get(fm.FeedPerformanceMonitor, a.monitor_id)
    subject = _subject(db, monitor.subject_type, monitor.subject_id) if monitor else None
    return {
        "id": a.id, "monitor_id": a.monitor_id, "subject_type": monitor.subject_type if monitor else None, "subject_id": monitor.subject_id if monitor else None,
        "subject_name": getattr(subject, "name", None), "production_metric_code": monitor.production_metric_code if monitor else None,
        "evaluated_at": a.evaluated_at, "period_start": a.period_start, "period_end": a.period_end, "baseline_value": a.baseline_value,
        "observed_value": a.observed_value, "variance_value": a.variance_value, "variance_percent": a.variance_percent,
        "feed_related_likelihood": a.feed_related_likelihood, "confidence_score": a.confidence_score, "model_reference": a.model_reference,
        "model_version": a.model_version, "evidence": a.evidence_json, "confounders": a.confounders_json, "explanation": a.explanation, "status": a.status,
    }


def alert_dict(db: Session, a: fm.FeedPerformanceAlert) -> dict:
    batch = db.get(fm.FeedBatch, a.feed_batch_id) if a.feed_batch_id else None
    subject = _subject(db, a.subject_type, a.subject_id) if a.subject_type and a.subject_id else None
    product = db.get(fm.FeedProduct, a.feed_product_id) if a.feed_product_id else None
    return {
        "id": a.id, "farm_id": a.farm_id, "assessment_id": a.assessment_id, "feed_batch_id": a.feed_batch_id, "mix_code": batch.mix_code if batch else None,
        "feed_product_id": a.feed_product_id, "product_name": product.name if product else None, "subject_type": a.subject_type, "subject_id": a.subject_id,
        "subject_name": getattr(subject, "name", None), "alert_type": a.alert_type, "severity": a.severity, "detected_at": a.detected_at,
        "last_seen_at": a.last_seen_at, "title": a.title, "explanation": a.explanation, "evidence": a.evidence_json, "confidence_score": a.confidence_score,
        "status": a.status, "deduplication_key": a.deduplication_key, "acknowledged_by": a.acknowledged_by, "acknowledged_at": a.acknowledged_at,
        "resolved_at": a.resolved_at, "resolution_note": a.resolution_note,
    }


def exposure_dict(db: Session, w: fm.FeedExposureWindow) -> dict:
    subject = _subject(db, w.subject_type, w.subject_id)
    return {
        "id": w.id, "subject_type": w.subject_type, "subject_id": w.subject_id, "subject_name": getattr(subject, "name", None),
        "feed_product_id": w.feed_product_id, "lot_id": w.lot_id, "feed_batch_id": w.feed_batch_id, "exposure_start": w.exposure_start,
        "exposure_end": w.exposure_end, "offered_quantity": w.offered_quantity, "consumed_estimate": w.consumed_estimate,
        "feeding_event_count": w.feeding_event_count, "lineage": w.lineage_json, "generated_at": w.generated_at,
    }


def summary(db: Session, farm_id: str) -> dict:
    alerts = db.scalars(select(fm.FeedPerformanceAlert).where(fm.FeedPerformanceAlert.farm_id == farm_id, fm.FeedPerformanceAlert.status != "resolved")).all()
    monitors = db.scalars(select(fm.FeedPerformanceMonitor).where(fm.FeedPerformanceMonitor.farm_id == farm_id, fm.FeedPerformanceMonitor.active.is_(True))).all()
    last = db.scalar(select(func.max(fm.FeedPerformanceAssessment.evaluated_at)).where(fm.FeedPerformanceAssessment.farm_id == farm_id))
    by_type: dict[str, int] = {}
    for a in alerts:
        by_type[a.alert_type] = by_type.get(a.alert_type, 0) + 1
    return {
        "open_alerts": len(alerts), "alerts_by_type": by_type, "monitors": len(monitors), "last_evaluated_at": last,
        "batches_scored": db.scalar(select(func.count(fm.FeedBatchPerformanceScore.feed_batch_id)).where(fm.FeedBatchPerformanceScore.farm_id == farm_id)) or 0,
        "suppliers_scored": db.scalar(select(func.count(fm.SupplierFeedPerformance.id)).where(fm.SupplierFeedPerformance.farm_id == farm_id)) or 0,
        "model_reference": MODEL_REFERENCE, "model_version": MODEL_VERSION,
    }


def performance_signals(db: Session, farm_id: str) -> list:
    """Open feed-performance alerts for the notification bell. Acknowledged
    ones stay out of the bell but open in the list."""
    from app.services.signals_service import Signal  # local import: signals imports this module

    out = []
    for a in db.scalars(select(fm.FeedPerformanceAlert).where(fm.FeedPerformanceAlert.farm_id == farm_id, fm.FeedPerformanceAlert.status == "open")):
        entity_type, entity_id = _alert_entity(a)
        out.append(Signal(
            source_type="feed_performance_alert", source_id=a.id, module_code=perms.FEED_NUTRITION,
            notification_type=f"feed_performance_{a.alert_type.lower()}", title=a.title, description=a.explanation[:300], priority=a.severity,
            entity_type=entity_type, entity_id=entity_id,
            metadata={"alert_id": a.id, "alert_type": a.alert_type, "confidence": a.confidence_score, "feed_batch_id": a.feed_batch_id},
        ))
    return out
