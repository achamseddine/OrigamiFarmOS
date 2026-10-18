"""Feed Performance Intelligence (database/FEED-PERFORMANCE-INTELLIGENCE.md),
deterministic increment two.

What it does, and only this:

- connects what was bought (supplier lot), what was mixed (numbered mix,
  actual components), what was fed (feeding events through the output
  lot) and what the animals produced afterwards (milk / eggs / growth);
- compares production in an evaluation window against an **explicit
  baseline** the monitor names — rolling subject, comparable previous
  period, lactation-stage-adjusted, matched peer group or an approved
  expected production curve — and says how big and how persistent the
  change is;
- lists the feed changes that preceded it, with their lineage, and the
  confounders it could and could not check (§6): health cases, lactation
  stage, parity, recent calving / dry-off, membership and movement,
  feeding timing, formula version, actual-vs-target, ingredient lot
  changes, lab analysis, environment, milking anomalies, weight change —
  missing context lowers the confidence, it is never read as "no change";
- scores mixes and suppliers from the same facts, ingredient by
  ingredient, and asks whether an ingredient lot or a supplier's lots are
  associated with weaker performance downstream (§8, §9, §11);
- puts an effective-value frame on the money (§10): cost per litre, cost
  per head per day, milk revenue less feed cost, dry-matter-adjusted cost;
- raises persistent, deduplicated alerts with a structured list of
  suggested actions, and resolves them when the condition clears;
- is re-run by the events §12 names and by the daily scheduled cycle.

What it never does: write a milk, feed, stock, health or supplier fact;
change a formula, a program, a lot's status or a supplier's standing;
or call an association a cause. Every assessment carries its model
reference, evidence window, baseline method actually applied, confounders
and confidence so a person can check it.
"""
from __future__ import annotations

import math
import statistics
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.core import permissions as perms
from app.domain import feed_models as fm
from app.domain import health_models as hm
from app.domain import models
from app.feeding import uom
from app.repositories.base import ensure_utc, new_id, now, write_event
from app.services import feed_batch_service as batches
from app.services import feed_inventory_service as inv
from app.services import feeding_program_service as programs
from app.services.feed_inventory_service import FeedError

MODEL_REFERENCE = "origami.feed_performance.deterministic"
MODEL_VERSION = "2.0"
METRICS = ("milk_l_per_day", "eggs_per_day", "weight_gain_kg_per_day")
METRIC_UNITS = {"milk_l_per_day": "L/head/day", "eggs_per_day": "eggs/day", "weight_gain_kg_per_day": "kg/head/day"}
BASELINE_METHODS = ("rolling_subject", "previous_period", "lactation_adjusted", "peer_group", "production_curve")
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
RECENT_CALVING_DAYS = 21
RECENT_DRY_OFF_DAYS = 14
HEAT_STRESS_C = 30.0
UNDERPERFORMANCE_SCORE = 0.4        # production response below this is weak (0.5 = no change)
MIN_CONFIDENCE_FOR_ALERT = 0.5
# Relative lactation-curve shape (Wood: t^b · e^(−c·t)); the scale cancels
# because only the ratio between two days in milk is used.
LACTATION_CURVE_DEFAULTS = {"cow": (0.19, 0.0036), "goat": (0.15, 0.005), "sheep": (0.12, 0.008), "buffalo": (0.19, 0.0036)}
ENVIRONMENT_OBSERVATIONS = ("ambient_temperature_c", "ambient_temperature", "temperature_ambient", "heat_stress", "thi", "barn_temperature_c")
MOVEMENT_EVENTS = ("animal_moved", "group_moved", "animal_group_changed")
MANAGEMENT_EVENTS = ("feeding_program_assigned", "feeding_program_changed", "group_updated", "feed_formula_version_activated")


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


def _validate_monitor(db: Session, subject_type: str, subject, *, metric: str, method: str, configuration: dict | None) -> None:
    if metric not in METRICS:
        raise FeedError(f"production_metric_code must be one of {list(METRICS)}")
    if method not in BASELINE_METHODS:
        raise FeedError(f"baseline_method_code must be one of {list(BASELINE_METHODS)}")
    if metric == "eggs_per_day" and subject_type != "group":
        raise FeedError("Eggs are recorded per flock; monitor the group, not an animal.")
    if method == "lactation_adjusted" and metric != "milk_l_per_day":
        raise FeedError("A lactation-adjusted baseline applies to milk.")
    if method == "production_curve":
        curve = (configuration or {}).get("expected_curve")
        if not isinstance(curve, list) or not curve:
            raise FeedError("A production-curve baseline needs configuration.expected_curve: a list of {from_day, to_day, value} bands over days in milk (or age in days).")
        for band in curve:
            if not isinstance(band, dict) or band.get("value") is None or band.get("from_day") is None:
                raise FeedError("Each expected_curve band needs from_day, to_day and value.")


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
    _validate_monitor(db, subject_type, subject, metric=production_metric_code, method=baseline_method_code, configuration=configuration)
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
    subject = _subject(db, monitor.subject_type, monitor.subject_id)
    _validate_monitor(db, monitor.subject_type, subject, metric=monitor.production_metric_code, method=monitor.baseline_method_code, configuration=monitor.configuration_json)
    monitor.updated_at = now()
    return monitor


def ensure_default_monitors(db: Session, farm_id: str, *, user_id: str) -> list[fm.FeedPerformanceMonitor]:
    """A monitor for every group that produces: milk for herds whose
    members have milk records, eggs for flocks with egg records. Explicit
    per-animal and growth monitors are the farm's to add."""
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
    scale); eggs are the flock's eggs per day; growth is the average daily
    gain between consecutive dated weights, on the day of the later
    weight. A day with no record is absent — missing is not zero."""
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
    elif metric == "weight_gain_kg_per_day":
        per_day: dict[date, list[float]] = {}
        for a in _subject_animals(db, subject_type, subject):
            records = db.scalars(select(hm.AnimalWeightRecord).where(hm.AnimalWeightRecord.animal_id == a.id, hm.AnimalWeightRecord.measured_at < hi)
                                 .order_by(hm.AnimalWeightRecord.measured_at)).all()
            for prev, cur in zip(records, records[1:]):
                day = ensure_utc(cur.measured_at).date()
                if day < start:
                    continue
                span = (ensure_utc(cur.measured_at) - ensure_utc(prev.measured_at)).total_seconds() / 86400
                if span <= 0:
                    continue
                per_day.setdefault(day, []).append((cur.weight_kg - prev.weight_kg) / span)
        for day, gains in per_day.items():
            out[day] = round(statistics.fmean(gains), 4)
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
                                           "formula_version_id": batch.formula_version_id, "production_date": batch.production_date.isoformat() if batch.production_date else None,
                                           "operator_id": batch.operator_id or batch.mixed_by, "mixer_asset_id": batch.mixer_asset_id},
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
                "mix_code": mix.get("mix_code"), "mix_number": mix.get("mix_number"), "batch_id": w.feed_batch_id, "formula_version_id": mix.get("formula_version_id"),
                "ingredient_lots": [{k: i.get(k) for k in ("product_name", "lot_id", "lot_code", "supplier_label")} for i in lineage.get("ingredient_lots", [])],
                "introduced_at": start.isoformat(), "days_of_exposure": round((min(until, ensure_utc(w.exposure_end) if w.exposure_end else until) - start).total_seconds() / 86400, 1),
                "offered_quantity": w.offered_quantity, "worst_component_deviation_pct": compliance,
            })
    changes.sort(key=lambda c: c["introduced_at"])
    return changes


# --------------------------------------------------------------- baselines
def _days_in_milk(animals: list[models.Animal], at: datetime) -> float | None:
    dims = [(at - ensure_utc(a.lactation_started_at)).total_seconds() / 86400 for a in animals if a.lactating and a.lactation_started_at]
    return round(statistics.fmean(dims), 1) if dims else None


def _age_days(animals: list[models.Animal], at: datetime) -> float | None:
    ages = [(at - ensure_utc(a.birth_date)).total_seconds() / 86400 for a in animals if a.birth_date]
    return round(statistics.fmean(ages), 1) if ages else None


def _wood(t: float, b: float, c: float) -> float:
    return max(t, 1.0) ** b * math.exp(-c * max(t, 1.0))


def _curve_value(curve: list[dict], day: float) -> float | None:
    for band in curve:
        lo, hi = float(band.get("from_day", 0)), band.get("to_day")
        if day >= lo and (hi is None or day <= float(hi)):
            return float(band["value"])
    return None


def _peers(db: Session, monitor: fm.FeedPerformanceMonitor, subject):
    """Matched peers: same farm, species, management profile and kind of
    subject; for animals, the same lactation state."""
    if monitor.subject_type == "animal":
        rows = db.scalars(select(models.Animal).where(
            models.Animal.farm_id == monitor.farm_id, models.Animal.active.is_(True), models.Animal.species == subject.species, models.Animal.id != subject.id,
            models.Animal.management_profile == subject.management_profile, models.Animal.lactating == subject.lactating)).all()
        return [("animal", a) for a in rows]
    rows = db.scalars(select(models.Flock).where(models.Flock.farm_id == monitor.farm_id, models.Flock.species == subject.species, models.Flock.id != subject.id,
                                                 models.Flock.management_profile == subject.management_profile)).all()
    return [("group", g) for g in rows]


def _baseline(db: Session, monitor: fm.FeedPerformanceMonitor, subject, animals: list[models.Animal], observed: dict[date, float],
              period_start: date, end_day: date, baseline_start: date, baseline_end: date, at: datetime) -> tuple[dict[date, float], dict]:
    """The explicit baseline series (§13) and how it was built. A method
    whose inputs are missing falls back to the rolling subject baseline
    and says so — the fallback is recorded, never silent."""
    method = monitor.baseline_method_code
    rolling = daily_values(db, monitor.subject_type, subject, monitor.production_metric_code, baseline_start, baseline_end)
    details: dict = {"method_requested": method, "method_applied": method, "window": {"start": baseline_start.isoformat(), "end": baseline_end.isoformat()}}
    if method in ("rolling_subject", "previous_period"):
        return rolling, details
    if method == "lactation_adjusted":
        dim_eval = _days_in_milk(animals, _start_of(end_day) - timedelta(days=(end_day - period_start).days / 2))
        if dim_eval is None or not rolling:
            details.update({"method_applied": "rolling_subject", "fallback_reason": "days in milk unknown (no lactation_started_at on the animals)"})
            return rolling, details
        shift = ((period_start - baseline_start).days + (end_day - baseline_end).days) / 2
        dim_base = max(dim_eval - shift, 1.0)
        b, c = tuple((monitor.configuration_json or {}).get("lactation_curve", {}).get(k, d) for k, d in zip(("b", "c"), LACTATION_CURVE_DEFAULTS.get(subject.species, (0.15, 0.005))))
        ratio = _wood(dim_eval, b, c) / _wood(dim_base, b, c)
        details.update({"days_in_milk_evaluation": dim_eval, "days_in_milk_baseline": round(dim_base, 1), "curve": {"b": b, "c": c}, "expected_ratio": round(ratio, 4)})
        return {d: round(v * ratio, 4) for d, v in rolling.items()}, details
    if method == "peer_group":
        peers = _peers(db, monitor, subject)
        series: dict[date, list[float]] = {}
        for stype, peer in peers:
            for d, v in daily_values(db, stype, peer, monitor.production_metric_code, period_start, end_day).items():
                series.setdefault(d, []).append(v)
        usable = {d: round(statistics.fmean(vs), 4) for d, vs in series.items() if len(vs) >= 2}
        if len(usable) < monitor.minimum_observations:
            details.update({"method_applied": "rolling_subject", "fallback_reason": f"fewer than two matched peers reporting on {monitor.minimum_observations} day(s)",
                            "peers_considered": len(peers)})
            return rolling, details
        details.update({"peers": [{"subject_type": st, "subject_id": p.id, "name": p.name} for st, p in peers], "window": {"start": period_start.isoformat(), "end": end_day.isoformat()},
                        "note": "the peers' production over the same days; farm-wide effects (weather, milking) cancel"})
        return usable, details
    if method == "production_curve":
        curve = (monitor.configuration_json or {}).get("expected_curve") or []
        day = _days_in_milk(animals, at) if monitor.production_metric_code == "milk_l_per_day" else _age_days(animals, at)
        value = _curve_value(curve, day) if day is not None else None
        if value is None:
            details.update({"method_applied": "rolling_subject", "fallback_reason": "no expected value: days in milk / age unknown or outside the approved curve"})
            return rolling, details
        details.update({"curve_day": day, "expected_value": value, "basis": "days_in_milk" if monitor.production_metric_code == "milk_l_per_day" else "age_days",
                        "window": {"start": period_start.isoformat(), "end": end_day.isoformat()}})
        return {period_start + timedelta(days=i): value for i in range((end_day - period_start).days + 1)}, details
    return rolling, details


# ------------------------------------------------------------ confounders
def _count_events(db: Session, entity_type: str, entity_ids: list[str], types: tuple[str, ...], lo: datetime, hi: datetime) -> int:
    if not entity_ids:
        return 0
    return db.scalar(select(func.count(models.Event.id)).where(
        models.Event.entity_type == entity_type, models.Event.entity_id.in_(entity_ids), models.Event.event_type.in_(types),
        models.Event.created_at >= lo, models.Event.created_at < hi)) or 0


def _feedings_per_day(db: Session, keys: list[tuple[str, str]], start: date, end: date) -> float | None:
    """Feedings per fed day: the pattern of the days the subject was fed
    (two meals or one), not whether a new feed started — that is the
    feed change itself, listed separately."""
    total = 0
    days: set[date] = set()
    for stype, sid in keys:
        for (occurred,) in db.execute(select(fm.FeedingEvent.occurred_at).where(
                fm.FeedingEvent.subject_type == stype, fm.FeedingEvent.subject_id == sid, fm.FeedingEvent.status == "recorded",
                fm.FeedingEvent.event_type.in_(("offered", "delivered")), fm.FeedingEvent.occurred_at >= _start_of(start),
                fm.FeedingEvent.occurred_at < _start_of(end + timedelta(days=1)))).all():
            total += 1
            days.add(ensure_utc(occurred).date())
    return round(total / len(days), 2) if days else None


def _confounders(db: Session, monitor: fm.FeedPerformanceMonitor, subject_type: str, subject, group, period_start: date, period_end: date,
                 baseline_start: date, baseline_end: date, observed: dict[date, float], changes: list[dict]) -> dict:
    """What else could explain the change, from the facts this app holds
    (§6). Anything it cannot see is named as missing, so the confidence
    can drop for it rather than the gap passing as 'nothing changed'."""
    animals = _subject_animals(db, subject_type, subject)
    ids = [a.id for a in animals]
    lo, hi = _start_of(period_start - timedelta(days=CHANGE_LOOKBACK_DAYS)), _start_of(period_end + timedelta(days=1))
    at = _start_of(period_end)
    keys = [(subject_type, subject.id)] + ([("group", group.id)] if group is not None else [])
    milk = monitor.production_metric_code == "milk_l_per_day"

    health = 0
    cases = 0
    if ids:
        health += db.scalar(select(func.count(models.Observation.id)).where(
            models.Observation.entity_type == "animal", models.Observation.entity_id.in_(ids),
            models.Observation.observed_at >= lo, models.Observation.observed_at < hi)) or 0
        health += db.scalar(select(func.count(models.Treatment.id)).where(
            models.Treatment.entity_type == "animal", models.Treatment.entity_id.in_(ids),
            models.Treatment.start_at >= lo, models.Treatment.start_at < hi)) or 0
        cases += db.scalar(select(func.count(hm.HealthCase.id)).where(hm.HealthCase.animal_id.in_(ids), hm.HealthCase.status.in_(("open", "monitoring")))) or 0
    if subject_type == "group":
        health += db.scalar(select(func.count(models.Observation.id)).where(
            models.Observation.entity_type.in_(("flock", "group")), models.Observation.entity_id == subject.id,
            models.Observation.observed_at >= lo, models.Observation.observed_at < hi)) or 0
        cases += db.scalar(select(func.count(hm.HealthCase.id)).where(hm.HealthCase.animal_group_id == subject.id, hm.HealthCase.status.in_(("open", "monitoring")))) or 0
    withdrawal = sum(1 for a in animals if a.withdrawal_until and ensure_utc(a.withdrawal_until) >= lo)
    lactating = sum(1 for a in animals if a.lactating)
    pregnant = sum(1 for a in animals if a.pregnant)
    membership = "unavailable"
    if subject_type == "group" and animals:
        before = _milked_heads(db, subject_type, subject, baseline_start, baseline_end)
        after = _milked_heads(db, subject_type, subject, period_start, period_end)
        membership = "changed" if before and after and before != after else ("stable" if before and after else "unavailable")
    refusals = 0
    for stype, sid in keys:
        refusals += db.scalar(select(func.count(fm.FeedingEvent.id)).where(
            fm.FeedingEvent.subject_type == stype, fm.FeedingEvent.subject_id == sid, fm.FeedingEvent.event_type == "refusal",
            fm.FeedingEvent.status == "recorded", fm.FeedingEvent.occurred_at >= _start_of(period_start), fm.FeedingEvent.occurred_at < hi)) or 0

    # Lactation stage and reproductive context
    days_in_milk = _days_in_milk(animals, at) if milk else None
    parities = [a.lactation_cycle for a in animals if a.lactation_cycle]
    parity = round(statistics.fmean(parities), 1) if parities else None
    recent_calving = sum(1 for a in animals if a.lactation_started_at and lo <= ensure_utc(a.lactation_started_at) < hi) if milk else 0
    recent_dry_off = sum(1 for a in animals if a.dried_off_at and _start_of(period_start - timedelta(days=RECENT_DRY_OFF_DAYS)) <= ensure_utc(a.dried_off_at) < hi)
    # Movement and management
    movements = _count_events(db, "animal", ids, MOVEMENT_EVENTS, lo, hi)
    for e in db.scalars(select(models.Event).where(models.Event.entity_type == "animal", models.Event.entity_id.in_(ids), models.Event.event_type == "animal_updated",
                                                    models.Event.created_at >= lo, models.Event.created_at < hi)) if ids else []:
        if {"group_name", "location_label"} & set((e.payload_json or {}).get("fields", [])):
            movements += 1
    management = _count_events(db, subject_type, [subject.id], MANAGEMENT_EVENTS, lo, hi) + (_count_events(db, "group", [group.id], MANAGEMENT_EVENTS, lo, hi) if group is not None else 0)
    # Feeding timing / frequency
    eval_fpd = _feedings_per_day(db, keys, period_start, period_end)
    base_fpd = _feedings_per_day(db, keys, baseline_start, baseline_end)
    timing_changed = eval_fpd is not None and base_fpd is not None and abs(eval_fpd - base_fpd) >= 0.5
    # Formula version in use and ingredient lot changes
    versions_now = sorted({c["formula_version_id"] for c in changes if c.get("formula_version_id")})
    earlier_versions: set[str] = set()
    for stype, sid in keys:
        for w in exposures_for(db, monitor.farm_id, stype, sid):
            if ensure_utc(w.exposure_start) < lo and (w.lineage_json or {}).get("mix"):
                earlier_versions.add(w.lineage_json["mix"].get("formula_version_id"))
    formula_version_changed = bool(versions_now) and bool(earlier_versions) and set(versions_now) != earlier_versions
    worst_deviation = max((c["worst_component_deviation_pct"] for c in changes if c.get("worst_component_deviation_pct") is not None), default=None)
    # Laboratory analysis on the lots / mixes introduced
    lot_ids = [c["lot_id"] for c in changes if c.get("lot_id")] + [i["lot_id"] for c in changes for i in c.get("ingredient_lots", []) if i.get("lot_id")]
    batch_ids = [c["batch_id"] for c in changes if c.get("batch_id")]
    lab = None
    if lot_ids or batch_ids:
        lab = db.scalar(select(func.count(fm.FeedNutrientProfile.id)).where(
            fm.FeedNutrientProfile.source_type == "lab",
            ((fm.FeedNutrientProfile.subject_type == "feed_lot") & fm.FeedNutrientProfile.subject_id.in_(lot_ids or ["-"]))
            | ((fm.FeedNutrientProfile.subject_type == "feed_batch") & fm.FeedNutrientProfile.subject_id.in_(batch_ids or ["-"])))) or 0
        lab = lab or None
    # Environment: ambient temperature / heat-stress observations recorded on the farm
    env_rows = db.scalars(select(models.Observation).where(
        models.Observation.farm_id == monitor.farm_id, models.Observation.observation_type.in_(ENVIRONMENT_OBSERVATIONS),
        models.Observation.observed_at >= _start_of(period_start), models.Observation.observed_at < hi)).all()
    env_max = max((o.value_numeric for o in env_rows if o.value_numeric is not None), default=None)
    environment = None if not env_rows else {"observations": len(env_rows), "max_temperature_c": env_max, "heat_stress": bool(env_max is not None and env_max >= HEAT_STRESS_C)}
    # Milking-system / measurement anomalies
    milking_anomalies = 0
    if milk and ids:
        milking_anomalies = db.scalar(select(func.count(models.MilkRecord.id)).where(
            models.MilkRecord.animal_id.in_(ids), models.MilkRecord.recorded_at >= _start_of(period_start), models.MilkRecord.recorded_at < hi,
            models.MilkRecord.quality_status != "normal")) or 0
        sessions_eval = db.scalar(select(func.count(func.distinct(models.MilkRecord.session))).where(
            models.MilkRecord.animal_id.in_(ids), models.MilkRecord.recorded_at >= _start_of(period_start), models.MilkRecord.recorded_at < hi)) or 0
        sessions_base = db.scalar(select(func.count(func.distinct(models.MilkRecord.session))).where(
            models.MilkRecord.animal_id.in_(ids), models.MilkRecord.recorded_at >= _start_of(baseline_start), models.MilkRecord.recorded_at < _start_of(baseline_end + timedelta(days=1)))) or 0
        if sessions_eval and sessions_base and sessions_eval != sessions_base:
            milking_anomalies += 1
    # Live weight change across the baseline + evaluation span
    weight_change = None
    if ids:
        deltas = []
        for aid in ids:
            recs = db.scalars(select(hm.AnimalWeightRecord).where(hm.AnimalWeightRecord.animal_id == aid, hm.AnimalWeightRecord.measured_at >= _start_of(baseline_start),
                                                                   hm.AnimalWeightRecord.measured_at < hi).order_by(hm.AnimalWeightRecord.measured_at)).all()
            if len(recs) >= 2:
                deltas.append(recs[-1].weight_kg - recs[0].weight_kg)
        weight_change = round(statistics.fmean(deltas), 2) if deltas else None

    missing = []
    if milk:
        if days_in_milk is None:
            missing.append("days_in_milk")
        if parity is None:
            missing.append("parity")
    if environment is None:
        missing.append("environment")
    if lab is None:
        missing.append("lab_analysis")
    if weight_change is None:
        missing.append("weight_change")
    missing += ["body_condition", "milk_components"]
    if membership == "unavailable":
        missing.append("group_membership")
    return {
        "health_events": health, "active_health_cases": cases, "animals_under_withdrawal": withdrawal, "lactating_heads": lactating, "pregnant_heads": pregnant,
        "head_count": len(animals), "milked_heads_change": membership, "refusal_events": refusals, "observation_days": len(observed),
        "days_in_milk": days_in_milk, "parity": parity, "recent_calving": recent_calving, "recent_dry_off": recent_dry_off,
        "movements": movements, "management_changes": management,
        "feeding_timing": {"evaluation_per_day": eval_fpd, "baseline_per_day": base_fpd, "changed": timing_changed},
        "formula_version_changed": formula_version_changed, "formula_versions_in_use": versions_now, "worst_component_deviation_pct": worst_deviation,
        "ingredient_lot_changes": len(changes), "lab_analyses_on_changes": lab, "environment": environment, "milking_anomalies": milking_anomalies,
        "weight_change_kg": weight_change, "missing_context": missing,
    }


# ------------------------------------------------------- suggested actions
def _suggested_actions(status: str, likelihood: str, pct: float | None, changes: list[dict], confounders: dict, subject_type: str, subject_id: str) -> list[dict]:
    """§15: a structured list the manager can act on, each pointing at
    the record it concerns. Recommendations only — nothing here changes a
    formula, a program, a lot or a supplier."""
    actions: list[dict] = []
    if status == "insufficient":
        return [{"code": "record_more_observations", "label": "Record production daily so the baseline and the evaluation window both have enough days.",
                 "target_type": subject_type, "target_id": subject_id}]
    if status == "anomaly" and (pct or 0) < 0:
        for c in changes:
            if c.get("batch_id"):
                actions.append({"code": "inspect_mix", "label": f"Inspect {c.get('mix_code') or c.get('product_name')} (smell, moisture, mould, mixing)", "target_type": "feed_batch", "target_id": c["batch_id"]})
            elif c.get("lot_id"):
                actions.append({"code": "inspect_lot", "label": f"Inspect lot {c.get('lot_code')} of {c.get('product_name')}", "target_type": "feed_lot", "target_id": c["lot_id"]})
            for i in c.get("ingredient_lots", []):
                if i.get("lot_id"):
                    actions.append({"code": "inspect_ingredient_lot", "label": f"Inspect {i.get('product_name')} lot {i.get('lot_code')}" + (f" from {i['supplier_label']}" if i.get("supplier_label") else ""),
                                    "target_type": "feed_lot", "target_id": i["lot_id"]})
        actions.append({"code": "compare_intake", "label": "Compare feed offered against eaten and record refusals", "target_type": subject_type, "target_id": subject_id})
        if confounders.get("worst_component_deviation_pct") and confounders["worst_component_deviation_pct"] > COMPLIANCE_TOLERANCE_PCT:
            actions.append({"code": "review_formula_compliance", "label": "A mix was off its formula: separate the mixing deviation from any ingredient question", "target_type": "feed_batch",
                            "target_id": next((c["batch_id"] for c in changes if c.get("batch_id")), None)})
        if likelihood in ("MODERATE", "HIGH") and changes:
            target = next((c for c in reversed(changes) if c.get("batch_id") or c.get("lot_id")), None)
            actions.append({"code": "sample_lab_analysis", "label": "Sample for laboratory analysis if the decline persists", "target_type": "feed_batch" if target and target.get("batch_id") else "feed_lot",
                            "target_id": (target.get("batch_id") or target.get("lot_id")) if target else None})
        if confounders.get("health_events") or confounders.get("active_health_cases"):
            actions.append({"code": "check_health", "label": "Check the animals with health events or open cases before reading the change as feed", "target_type": subject_type, "target_id": subject_id})
        if confounders.get("milking_anomalies"):
            actions.append({"code": "check_milking_system", "label": "Check the milking records and equipment: abnormal milk or a changed session pattern was recorded", "target_type": subject_type, "target_id": subject_id})
        if (confounders.get("environment") or {}).get("heat_stress"):
            actions.append({"code": "mitigate_heat_stress", "label": "Heat stress was recorded: shade, water and ventilation before any ration change", "target_type": subject_type, "target_id": subject_id})
        actions.append({"code": "review_ration", "label": "Review the ration with the responsible nutrition / veterinary professional — nothing changes until a person decides",
                        "target_type": subject_type, "target_id": subject_id})
    elif status == "anomaly":
        actions.append({"code": "document_change", "label": "Production improved after a feed change: note what changed so it can be repeated deliberately", "target_type": subject_type, "target_id": subject_id})
    seen: set[tuple] = set()
    out = []
    for a in actions:
        key = (a["code"], a.get("target_id"))
        if key not in seen:
            seen.add(key)
            out.append(a)
    return out


# --------------------------------------------------------------- evaluate
def evaluate_monitor(db: Session, monitor: fm.FeedPerformanceMonitor, *, as_of: datetime | None = None, user_id: str = "system",
                     trigger: str = "cycle") -> fm.FeedPerformanceAssessment:
    """One assessment (§5): explicit baseline window and method, evaluation
    window, variance, persistence, the feed changes that preceded it, the
    confounders checked, suggested actions, a likelihood label and a
    confidence. Writes the assessment, raises or resolves the matching
    alert, and nothing else."""
    at = ensure_utc(as_of) if as_of else now()
    end_day = at.date()
    period_start = end_day - timedelta(days=monitor.evaluation_window_days - 1)
    baseline_end = period_start - timedelta(days=1)
    baseline_days = monitor.evaluation_window_days if monitor.baseline_method_code == "previous_period" else monitor.baseline_window_days
    baseline_start = baseline_end - timedelta(days=baseline_days - 1)

    subject = _subject(db, monitor.subject_type, monitor.subject_id)
    if subject is None:
        raise FeedError("The monitor's subject no longer exists.", 404)
    group = programs.group_for_animal(db, subject) if monitor.subject_type == "animal" else None
    animals = _subject_animals(db, monitor.subject_type, subject)
    observed = daily_values(db, monitor.subject_type, subject, monitor.production_metric_code, period_start, end_day)
    baseline, baseline_details = _baseline(db, monitor, subject, animals, observed, period_start, end_day, baseline_start, baseline_end, at)
    changes = _feed_changes(db, monitor.farm_id, monitor.subject_type, subject, group, _start_of(period_start - timedelta(days=CHANGE_LOOKBACK_DAYS)), at)
    confounders = _confounders(db, monitor, monitor.subject_type, subject, group, period_start, end_day, baseline_start, baseline_end, observed, changes)
    unit = METRIC_UNITS[monitor.production_metric_code]
    method_applied = baseline_details["method_applied"]
    evidence = {
        "metric": monitor.production_metric_code, "unit": unit, "baseline_method": monitor.baseline_method_code, "baseline_method_applied": method_applied,
        "baseline_details": baseline_details, "trigger": trigger,
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
        clean = (confounders["health_events"] == 0 and confounders["active_health_cases"] == 0 and confounders["milked_heads_change"] != "changed"
                 and confounders["refusal_events"] == 0 and confounders["recent_calving"] == 0 and confounders["recent_dry_off"] == 0
                 and confounders["milking_anomalies"] == 0 and not confounders["feeding_timing"]["changed"])
        if anomaly and exposed_enough:
            likelihood = "HIGH" if clean and len(exposed_enough) == 1 else "MODERATE"
        else:
            likelihood = "LOW"
        status = "anomaly" if anomaly else "normal"
        confidence = 0.95
        confidence -= min(0.3, 0.04 * len(confounders["missing_context"]))
        if confounders["health_events"] or confounders["active_health_cases"]:
            confidence -= 0.1
        if confounders["milked_heads_change"] == "changed":
            confidence -= 0.1
        if confounders["recent_calving"] or confounders["recent_dry_off"]:
            confidence -= 0.08
        if confounders["movements"]:
            confidence -= 0.05
        if confounders["feeding_timing"]["changed"]:
            confidence -= 0.05
        if confounders["milking_anomalies"]:
            confidence -= 0.05
        if method_applied != monitor.baseline_method_code:
            confidence -= 0.05
        if len(observed) < 2 * min_obs:
            confidence -= 0.1
        if len(baseline) < 2 * min_obs:
            confidence -= 0.05
        confidence = round(_clamp(confidence, 0.1, 0.95), 2)
        direction = "below" if (pct or 0) < 0 else "above"
        method_text = method_applied.replace("_", " ")
        lines = [f"{name}: {monitor.production_metric_code.replace('_', ' ')} is {abs(pct or 0):.1f}% {direction} the {method_text} baseline "
                 f"({observed_value:.2f} vs {baseline_value:.2f} {unit}) over {len(observed)} day(s)" + (", and persistently so." if anomaly else "; within the threshold.")]
        if method_applied != monitor.baseline_method_code:
            lines.append(f"The {monitor.baseline_method_code.replace('_', ' ')} baseline could not be built ({baseline_details.get('fallback_reason')}); the rolling subject baseline was used instead.")
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
        checks = [f"health events among the animals: {confounders['health_events']}", f"open health cases: {confounders['active_health_cases']}",
                  f"milked heads: {confounders['milked_heads_change']}", f"refusals: {confounders['refusal_events']}",
                  f"lactating {confounders['lactating_heads']}/{confounders['head_count']}, pregnant {confounders['pregnant_heads']}"]
        if confounders["days_in_milk"] is not None:
            checks.append(f"days in milk {confounders['days_in_milk']:.0f}" + (f", parity {confounders['parity']:g}" if confounders["parity"] is not None else ""))
        if confounders["recent_calving"] or confounders["recent_dry_off"]:
            checks.append(f"recent calving {confounders['recent_calving']}, recent dry-off {confounders['recent_dry_off']}")
        checks.append(f"movements: {confounders['movements']}")
        ft = confounders["feeding_timing"]
        checks.append("feeding frequency: " + ("changed" if ft["changed"] else "stable") + (f" ({ft['baseline_per_day']} → {ft['evaluation_per_day']} per day)" if ft["evaluation_per_day"] and ft["baseline_per_day"] else ""))
        if confounders["formula_version_changed"]:
            checks.append("formula version: changed")
        if confounders["lab_analyses_on_changes"]:
            checks.append(f"lab analyses on the lots introduced: {confounders['lab_analyses_on_changes']}")
        if confounders["environment"]:
            checks.append(f"environment: max {confounders['environment']['max_temperature_c']} °C" + (" (heat stress)" if confounders["environment"]["heat_stress"] else ""))
        if confounders["milking_anomalies"]:
            checks.append(f"milking anomalies: {confounders['milking_anomalies']}")
        if confounders["weight_change_kg"] is not None:
            checks.append(f"weight change {confounders['weight_change_kg']:+.1f} kg")
        lines.append("Checks: " + "; ".join(checks) + ". Not available: " + ", ".join(confounders["missing_context"]).replace("_", " ") + ".")
        lines.append(f"Feed-related likelihood {likelihood} (an association, not a cause), confidence {confidence:.2f}.")
        explanation = " ".join(lines)

    actions = _suggested_actions(status, likelihood, pct, changes, confounders, monitor.subject_type, monitor.subject_id)
    evidence["suggested_actions"] = actions
    assessment = fm.FeedPerformanceAssessment(
        id=new_id(), farm_id=monitor.farm_id, monitor_id=monitor.id, evaluated_at=at, period_start=_start_of(period_start), period_end=_start_of(end_day + timedelta(days=1)),
        baseline_value=baseline_value, observed_value=observed_value, variance_value=variance, variance_percent=pct,
        feed_related_likelihood=likelihood, confidence_score=confidence, model_reference=MODEL_REFERENCE, model_version=MODEL_VERSION,
        evidence_json=evidence, confounders_json=confounders, explanation=explanation, status=status,
    )
    db.add(assessment)
    db.flush()
    write_event(db, farm_id=monitor.farm_id, entity_type=monitor.subject_type, entity_id=monitor.subject_id, event_type="feed_performance_evaluated",
                payload={"assessment_id": assessment.id, "monitor_id": monitor.id, "status": status, "variance_pct": pct, "likelihood": likelihood, "confidence": confidence,
                         "baseline_method": method_applied, "trigger": trigger},
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
            explanation=explanation, evidence={"assessment_id": assessment.id, "change": change, "variance_pct": pct, "suggested_actions": actions, "confounders": confounders},
            confidence=confidence, dedup_key=key, assessment_id=assessment.id, feed_batch_id=change["batch_id"] if change else None,
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
                 subject_type: str | None = None, subject_id: str | None = None, review_task: bool = False, user_id: str = "system",
                 event_type: str = "feed_performance_anomaly_detected") -> tuple[fm.FeedPerformanceAlert, bool]:
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
    write_event(db, farm_id=farm_id, entity_type=entity_type, entity_id=entity_id, event_type=event_type,
                payload={"alert_id": alert.id, "alert_type": alert_type, "severity": severity, "confidence": confidence}, created_by=user_id)
    if review_task:
        from app.services import routing_service  # local import: routing is a leaf, but keep perf importable standalone

        reviewer = routing_service.primary_recipient(db, farm_id, "feed_performance")
        task = models.Task(
            id=new_id(), farm_id=farm_id, title=f"Review feed performance: {title[:160]}", description=explanation[:1500], assigned_to=reviewer.id if reviewer else None,
            due_at=now() + timedelta(days=1), priority="high", status="open", source_type="feed_performance_review", source_id=alert.id,
        )
        db.add(task)
        write_event(db, farm_id=farm_id, entity_type=entity_type, entity_id=entity_id, event_type="feed_performance_review_required",
                    payload={"alert_id": alert.id, "task_id": task.id, "assigned_to": task.assigned_to}, created_by=user_id)
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
    never scored as perfect. A weak, confident card raises
    FEED_BATCH_UNDERPERFORMANCE; a manufacturing deviation raises its own
    alert, kept apart from any ingredient question."""
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
    dm_cost = _cost_per_kg_dm(db, batch)
    evidence = {
        "mix_code": batch.mix_code, "dimensions_available": [k for k, v in dims.items() if v is not None],
        "component_deviations_pct": {v["feed_product_id"]: v.get("variance_pct") for v in variance}, "worst_component_deviation_pct": max(devs) if devs else None,
        "issued_quantity": issued, "refused_quantity": refused, "production_responses_pct": responses, "health_events_during_exposure": health_events,
        "daily_series_count": len(daily_series), "peer_unit_costs": peers, "unit_cost": batch.unit_cost, "cost_per_kg_dm": dm_cost,
        "exposed_subjects": [s["subject_id"] for s in usage["exposed_subjects"]], "operator_id": batch.operator_id or batch.mixed_by, "mixer_asset_id": batch.mixer_asset_id,
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
            evidence={"component_deviations_pct": evidence["component_deviations_pct"], "tolerance_pct": COMPLIANCE_TOLERANCE_PCT,
                      "suggested_actions": [{"code": "review_formula_compliance", "label": "Check the weighing and mixing record of this mix", "target_type": "feed_batch", "target_id": batch.id}]},
            confidence=0.95, dedup_key=key, feed_batch_id=batch.id, feed_product_id=batch.feed_product_id, user_id=user_id,
        )
        if created:
            write_event(db, farm_id=batch.farm_id, entity_type="feed_batch", entity_id=batch.id, event_type="formula_compliance_deviation_detected",
                        payload={"mix_code": batch.mix_code, "worst_deviation_pct": worst}, created_by=user_id)
    # A weak, confident card: the mix itself is associated with weaker
    # production downstream (§11 FEED_BATCH_UNDERPERFORMANCE).
    under_key = f"{batch.id}|FEED_BATCH_UNDERPERFORMANCE"
    if (production is not None and production < UNDERPERFORMANCE_SCORE and overall is not None and overall < 0.5 and confidence >= MIN_CONFIDENCE_FOR_ALERT
            and (exposure_days or 0) >= 2):
        mean_resp = statistics.fmean(responses)
        caveat = (" The mix was also off its formula, so manufacturing is a candidate explanation before any ingredient." if compliance is not None and compliance < 0.5 else "")
        upsert_alert(
            db, batch.farm_id, alert_type="FEED_BATCH_UNDERPERFORMANCE", severity="high" if production < 0.3 else "medium",
            title=f"{batch.mix_code} is associated with weaker production",
            explanation=(f"Animals fed {batch.mix_code} show a production response of {mean_resp:+.1f}% against their baselines over {exposure_days} day(s) of use "
                         f"(overall score {overall:.2f}, confidence {confidence:.2f}). Health events during the exposure: {health_events}.{caveat} "
                         "An association, not a cause: inspect the mix and its ingredient lots, compare intake, and review the ration with the responsible professional."),
            evidence={"score": {k: v for k, v in dims.items()}, "production_responses_pct": responses, "exposure_days": exposure_days,
                      "suggested_actions": [{"code": "inspect_mix", "label": f"Inspect {batch.mix_code}", "target_type": "feed_batch", "target_id": batch.id},
                                            {"code": "compare_intake", "label": "Compare offered against eaten on the exposed animals", "target_type": "feed_batch", "target_id": batch.id},
                                            {"code": "sample_lab_analysis", "label": "Sample the mix for laboratory analysis", "target_type": "feed_batch", "target_id": batch.id}]},
            confidence=confidence, dedup_key=under_key, feed_batch_id=batch.id, feed_product_id=batch.feed_product_id, user_id=user_id,
        )
    else:
        resolve_alerts(db, batch.farm_id, dedup_key=under_key, reason="the mix's production response is no longer weak", user_id=user_id)
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


# ---------------------------------------------------- ingredient lots (§8)
def ingredient_lot_performance(db: Session, farm_id: str, *, user_id: str = "system", write_alerts: bool = True) -> list[dict]:
    """Does one purchased ingredient lot travel with weaker production
    through the mixes that used it, compared with the farm's other mixes
    of the same feed that did not? Drill-down to the mixes is kept; a
    manufacturing deviation on those mixes is stated, not hidden (§8).
    The cycle raises and resolves the alerts (`write_alerts`); a read of
    the findings does not."""
    scores = {s.feed_batch_id: s for s in db.scalars(select(fm.FeedBatchPerformanceScore).where(fm.FeedBatchPerformanceScore.farm_id == farm_id))}
    if not scores:
        return []
    batch_by_id = {b.id: b for b in db.scalars(select(fm.FeedBatch).where(fm.FeedBatch.id.in_(list(scores))))}
    using: dict[str, set[str]] = {}
    for comp in db.scalars(select(fm.FeedBatchComponent).where(fm.FeedBatchComponent.batch_id.in_(list(scores)), fm.FeedBatchComponent.lot_id.is_not(None))):
        using.setdefault(comp.lot_id, set()).add(comp.batch_id)
    findings = []
    for lot_id, batch_ids in using.items():
        lot = db.get(fm.FeedLot, lot_id)
        if lot is None or lot.source_type != "purchased":
            continue
        resp = [scores[b].production_response_score for b in batch_ids if scores[b].production_response_score is not None]
        key = f"{lot.id}|INGREDIENT_LOT_PERFORMANCE_ANOMALY"
        if not resp:
            if write_alerts:
                resolve_alerts(db, farm_id, dedup_key=key, reason="no production evidence on the mixes", user_id=user_id)
            continue
        lot_mean = statistics.fmean(resp)
        products = {batch_by_id[b].feed_product_id for b in batch_ids if b in batch_by_id}
        others = [s.production_response_score for bid, s in scores.items() if bid not in batch_ids and s.production_response_score is not None
                  and batch_by_id.get(bid) is not None and batch_by_id[bid].feed_product_id in products]
        others_mean = statistics.fmean(others) if others else None
        compliance = [scores[b].formula_compliance_score for b in batch_ids if scores[b].formula_compliance_score is not None]
        deviated = bool(compliance) and min(compliance) < 0.5
        weak = lot_mean < UNDERPERFORMANCE_SCORE and (others_mean is None or others_mean >= lot_mean + 0.1)
        finding = {"lot_id": lot.id, "lot_code": lot.lot_code, "feed_product_id": lot.feed_product_id, "supplier_label": lot.supplier_label,
                   "mixes": [batch_by_id[b].mix_code for b in batch_ids if b in batch_by_id], "production_response_score": round(lot_mean, 4),
                   "other_mixes_score": round(others_mean, 4) if others_mean is not None else None, "manufacturing_deviation": deviated, "weak": weak}
        findings.append(finding)
        if not write_alerts:
            continue
        if weak:
            product = db.get(fm.FeedProduct, lot.feed_product_id)
            confidence = round(_clamp(0.4 + 0.15 * min(len(batch_ids), 3) - (0.2 if deviated else 0) + (0.1 if others_mean is not None else 0)), 2)
            mixes = ", ".join(finding["mixes"])
            _, created = upsert_alert(
                db, farm_id, alert_type="INGREDIENT_LOT_PERFORMANCE_ANOMALY", severity="medium",
                title=f"{product.name if product else 'Ingredient'} lot {lot.lot_code} travels with weaker production",
                explanation=(f"The mixes containing {product.name if product else 'this ingredient'} lot {lot.lot_code}" + (f" from {lot.supplier_label}" if lot.supplier_label else "")
                             + f" ({mixes}) score {lot_mean:.2f} on production response" + (f" against {others_mean:.2f} for mixes of the same feed without it" if others_mean is not None else "")
                             + "." + (" Those mixes were also off their formula, so manufacturing must be ruled out first; this is not clean evidence against the ingredient." if deviated else "")
                             + " An association, not a cause: inspect the lot, check its declared and laboratory analysis, and compare the supplier's other lots."),
                evidence={"finding": finding, "suggested_actions": [
                    {"code": "inspect_ingredient_lot", "label": f"Inspect lot {lot.lot_code}", "target_type": "feed_lot", "target_id": lot.id},
                    {"code": "sample_lab_analysis", "label": "Send a sample of the lot for laboratory analysis", "target_type": "feed_lot", "target_id": lot.id},
                    {"code": "compare_supplier_lots", "label": "Compare with the supplier's other lots of the same ingredient", "target_type": "feed_product", "target_id": lot.feed_product_id}]},
                confidence=confidence, dedup_key=key, feed_product_id=lot.feed_product_id, user_id=user_id, event_type="ingredient_lot_performance_anomaly_detected",
            )
        else:
            resolve_alerts(db, farm_id, dedup_key=key, reason="the lot's mixes no longer stand out", user_id=user_id)
    return findings


# --------------------------------------------------------------- suppliers
def _declared_dm(db: Session, product: fm.FeedProduct | None) -> float | None:
    if product is None:
        return None
    profile = batches.latest_profile(db, "feed_product", product.id, basis="as_fed")
    if profile is None:
        return None
    for v in profile.values:
        if v.nutrient_code.upper() == "DM" and v.value:
            return float(v.value)
    return None


def _cost_per_kg_dm(db: Session, batch: fm.FeedBatch) -> float | None:
    """Dry-matter-adjusted cost of a mix (§10): the unit cost over the
    formula's calculated dry matter, when the components declare one."""
    if batch.unit_cost is None or not batch.formula_version_id:
        return None
    version = db.get(fm.FeedFormulaVersion, batch.formula_version_id)
    if version is None:
        return None
    calc = batches.formula_nutrients(db, version, basis="as_fed")
    dm = next((v["value"] for v in calc["values"] if v["nutrient_code"].upper() == "DM"), None)
    if not dm:
        return None
    return round(batch.unit_cost / (dm / 100), 6)


def supplier_performance(db: Session, farm_id: str, *, days: int = 90, user_id: str = "system") -> list[fm.SupplierFeedPerformance]:
    """Supplier × ingredient from the supplier's lots in the period (§9):
    what was bought and at what cost, how many mixes used it, incidents on
    those lots, and the production response of the mixes downstream of
    them, with a dry-matter-adjusted cost and an effective-value frame
    (§10). Rebuilt whole; different ingredients from one supplier stay
    separate rows. Weak, confident downstream evidence raises
    SUPPLIER_LOT_PERFORMANCE_ANOMALY."""
    since = now() - timedelta(days=days)
    db.execute(delete(fm.SupplierFeedPerformance).where(fm.SupplierFeedPerformance.farm_id == farm_id))
    lots = db.scalars(select(fm.FeedLot).where(fm.FeedLot.farm_id == farm_id, fm.FeedLot.source_type == "purchased", fm.FeedLot.received_at >= since)).all()
    groups: dict[tuple, list[fm.FeedLot]] = {}
    for lot in lots:
        label = lot.supplier_label or (db.get(models.Supplier, lot.supplier_id).name if lot.supplier_id and db.get(models.Supplier, lot.supplier_id) else None)
        if not label:
            continue
        groups.setdefault((lot.supplier_id, label, lot.feed_product_id), []).append(lot)
    # Cost context per ingredient: the farm's average across suppliers.
    cost_by_product: dict[str, list[float]] = {}
    for (_, _, product_id), lot_rows in groups.items():
        for l in lot_rows:
            if l.unit_cost is not None:
                cost_by_product.setdefault(product_id, []).append(l.unit_cost)
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
        dm = _declared_dm(db, product)
        cost_per_kg_dm = round(avg_cost / (dm / 100), 6) if avg_cost is not None and dm else None
        # Effective value (§10): cheaper than the farm's average for the
        # ingredient is only half the story; the other half is what the
        # mixes made from it did downstream.
        farm_avg = statistics.fmean(cost_by_product[product_id]) if cost_by_product.get(product_id) else None
        price_score = round(_clamp(0.5 + (farm_avg - avg_cost) / farm_avg), 4) if avg_cost is not None and farm_avg else None
        effective = round(_clamp(0.5 * price_score + 0.5 * downstream), 4) if price_score is not None and downstream is not None else None
        row = fm.SupplierFeedPerformance(
            id=new_id(), farm_id=farm_id, supplier_id=supplier_id, supplier_label=label, inventory_item_id=product.inventory_item_id, feed_product_id=product_id,
            evaluation_start=since, evaluation_end=now(), lot_count=len(lot_rows), feed_batch_count=len(batch_ids), purchase_quantity=round(qty, 3),
            average_unit_cost=avg_cost, quality_consistency_score=quality, downstream_performance_score=downstream, incident_count=incidents,
            confidence_score=confidence, methodology_code="deterministic_lot_lineage", methodology_version=MODEL_VERSION,
            evidence_json={"lots": [{"lot_id": l.id, "lot_code": l.lot_code, "status": l.status, "accepted_quantity": l.accepted_quantity, "rejected_quantity": l.rejected_quantity,
                                     "unit_cost": l.unit_cost, "received_at": l.received_at.isoformat() if l.received_at else None} for l in lot_rows],
                           "batches": sorted(batch_ids), "downstream_overall_score": overall_mix, "lab_profiles": len(profiles), "unit": product.unit,
                           "declared_dm_pct": dm, "cost_per_kg_dm": cost_per_kg_dm, "farm_average_unit_cost": round(farm_avg, 4) if farm_avg else None,
                           "price_score": price_score, "effective_value_score": effective},
            generated_at=now(),
        )
        db.add(row)
        rows.append(row)
        key = f"supplier:{supplier_id or label}:{product_id}|SUPPLIER_LOT_PERFORMANCE_ANOMALY"
        if downstream is not None and downstream < UNDERPERFORMANCE_SCORE and len(batch_ids) >= 2 and confidence >= MIN_CONFIDENCE_FOR_ALERT:
            upsert_alert(
                db, farm_id, alert_type="SUPPLIER_LOT_PERFORMANCE_ANOMALY", severity="medium",
                title=f"{label}'s {product.name} lots travel with weaker production",
                explanation=(f"{len(lot_rows)} lot(s) of {product.name} from {label} went into {len(batch_ids)} mix(es) whose production response averages {downstream:.2f} "
                             f"(0.5 is no change), at {avg_cost if avg_cost is not None else '—'} per {product.unit}"
                             + (f", {cost_per_kg_dm} per kg DM" if cost_per_kg_dm else "") + f". Confidence {confidence:.2f}. An association, not a cause, and never by itself a reason "
                             "to block the supplier: inspect the lots, check analyses and compare with the farm's other sources before any purchasing decision."),
                evidence={"supplier_row_id": row.id, "lots": [l.lot_code for l in lot_rows], "batches": sorted(batch_ids), "downstream_performance_score": downstream,
                          "effective_value_score": effective, "suggested_actions": [
                              {"code": "compare_supplier_lots", "label": f"Compare {label}'s lots with other sources of {product.name}", "target_type": "feed_product", "target_id": product_id},
                              {"code": "sample_lab_analysis", "label": "Send the supplier's current lot for laboratory analysis", "target_type": "feed_product", "target_id": product_id},
                              {"code": "review_purchasing", "label": "Review purchasing with the manager — an analytical score never blocks a supplier by itself", "target_type": "feed_product", "target_id": product_id}]},
                confidence=confidence, dedup_key=key, feed_product_id=product_id, user_id=user_id,
            )
        else:
            resolve_alerts(db, farm_id, dedup_key=key, reason="the supplier's lots no longer stand out downstream", user_id=user_id)
    db.flush()
    if rows:
        write_event(db, farm_id=farm_id, entity_type="farm", entity_id=farm_id, event_type="supplier_feed_performance_updated",
                    payload={"rows": len(rows), "days": days}, created_by=user_id)
    return rows


def supplier_row_dict(db: Session, r: fm.SupplierFeedPerformance) -> dict:
    product = db.get(fm.FeedProduct, r.feed_product_id)
    ev = r.evidence_json or {}
    return {
        "id": r.id, "supplier_id": r.supplier_id, "supplier_label": r.supplier_label, "feed_product_id": r.feed_product_id, "product_name": product.name if product else None,
        "inventory_item_id": r.inventory_item_id, "evaluation_start": r.evaluation_start, "evaluation_end": r.evaluation_end, "lot_count": r.lot_count,
        "feed_batch_count": r.feed_batch_count, "purchase_quantity": r.purchase_quantity, "unit": ev.get("unit"), "average_unit_cost": r.average_unit_cost,
        "cost_per_kg_dm": ev.get("cost_per_kg_dm"), "effective_value_score": ev.get("effective_value_score"),
        "quality_consistency_score": r.quality_consistency_score, "downstream_performance_score": r.downstream_performance_score, "incident_count": r.incident_count,
        "confidence_score": r.confidence_score, "methodology_code": r.methodology_code, "methodology_version": r.methodology_version, "evidence": r.evidence_json, "generated_at": r.generated_at,
    }


# ------------------------------------------- cost, value and intake checks
def _cost_per_litre(db: Session, farm_id: str, start: datetime, end: datetime) -> float | None:
    cost = db.scalar(select(func.sum(fm.FeedingEvent.total_cost)).where(
        fm.FeedingEvent.farm_id == farm_id, fm.FeedingEvent.status == "recorded", fm.FeedingEvent.occurred_at >= start, fm.FeedingEvent.occurred_at < end)) or 0
    animal_ids = db.scalars(select(models.Animal.id).where(models.Animal.farm_id == farm_id)).all()
    litres = db.scalar(select(func.sum(models.MilkRecord.liters)).where(
        models.MilkRecord.animal_id.in_(animal_ids), models.MilkRecord.recorded_at >= start, models.MilkRecord.recorded_at < end)) if animal_ids else 0
    if not litres or not cost:
        return None
    return round(float(cost) / float(litres), 4)


def effective_feed_value(db: Session, farm_id: str, *, days: int = 7) -> dict:
    """§10: purchase price alone is insufficient. For the last `days`:
    feed cost, cost per litre, cost per head per day, milk revenue (at the
    farm's own recent selling price) less feed cost, and the dry-matter-
    adjusted cost of the mixes in use. Every figure names what it lacks."""
    end = now()
    start = end - timedelta(days=days)
    events = db.scalars(select(fm.FeedingEvent).where(fm.FeedingEvent.farm_id == farm_id, fm.FeedingEvent.status == "recorded",
                                                      fm.FeedingEvent.event_type.in_(("offered", "delivered")), fm.FeedingEvent.occurred_at >= start, fm.FeedingEvent.occurred_at < end)).all()
    cost = round(sum(e.total_cost or 0 for e in events), 4)
    head_days: dict[tuple, int] = {}
    for e in events:
        key = (ensure_utc(e.occurred_at).date(), e.subject_type, e.subject_id)
        head_days[key] = max(head_days.get(key, 0), e.head_count or 1)
    hd = sum(head_days.values())
    animal_ids = db.scalars(select(models.Animal.id).where(models.Animal.farm_id == farm_id)).all()
    litres = float(db.scalar(select(func.sum(models.MilkRecord.liters)).where(models.MilkRecord.animal_id.in_(animal_ids), models.MilkRecord.recorded_at >= start,
                                                                              models.MilkRecord.recorded_at < end)) or 0) if animal_ids else 0.0
    sales = db.scalars(select(models.Sale).where(models.Sale.farm_id == farm_id, models.Sale.product_type == "milk", models.Sale.sold_at >= end - timedelta(days=90),
                                                 models.Sale.quantity.is_not(None), models.Sale.quantity > 0)).all()
    price = round(sum(s.amount for s in sales) / sum(s.quantity for s in sales), 4) if sales else None
    revenue = round(litres * price, 2) if price is not None and litres else None
    mixes = []
    for b in db.scalars(select(fm.FeedBatch).where(fm.FeedBatch.farm_id == farm_id, fm.FeedBatch.status.in_(("completed", "quarantined")), fm.FeedBatch.unit_cost.is_not(None))
                        .order_by(fm.FeedBatch.mix_number.desc()).limit(10)):
        mixes.append({"batch_id": b.id, "mix_code": b.mix_code, "unit_cost": b.unit_cost, "unit": b.unit, "cost_per_kg_dm": _cost_per_kg_dm(db, b)})
    missing = []
    if not litres:
        missing.append("milk volume")
    if price is None:
        missing.append("milk selling price (no milk sale with a quantity in the last 90 days)")
    if not hd:
        missing.append("head-days (no feeding events with head counts)")
    if not any(m["cost_per_kg_dm"] for m in mixes):
        missing.append("dry matter of the mixes (declare DM on the ingredients)")
    return {
        "window_days": days, "feed_cost": cost, "milk_litres": round(litres, 3), "cost_per_litre": round(cost / litres, 4) if litres and cost else None,
        "head_days": hd, "cost_per_head_day": round(cost / hd, 4) if hd and cost else None, "milk_price_per_litre": price, "milk_revenue": revenue,
        "revenue_less_feed_cost": round(revenue - cost, 2) if revenue is not None else None, "mixes": mixes, "missing": missing,
        "note": "Effective value combines commercial cost with downstream performance; see the supplier rows' effective_value_score. Nutrient-adjusted cost needs laboratory analyses.",
    }


def check_cost_efficiency(db: Session, farm_id: str, *, user_id: str = "system") -> dict:
    """Feed cost per litre, this week against last (§10). A rise beyond the
    threshold is an alert with both figures; a fall resolves it."""
    end = now()
    this = _cost_per_litre(db, farm_id, end - timedelta(days=7), end)
    prev = _cost_per_litre(db, farm_id, end - timedelta(days=14), end - timedelta(days=7))
    change = round((this - prev) / prev * 100, 2) if this is not None and prev else None
    value = effective_feed_value(db, farm_id)
    key = "farm|FEED_COST_PER_OUTPUT_INCREASE"
    if change is not None and change > COST_INCREASE_ALERT_PCT:
        _, created = upsert_alert(
            db, farm_id, alert_type="FEED_COST_PER_OUTPUT_INCREASE", severity="medium", title="Feed cost per litre is rising",
            explanation=f"Feed cost per litre of milk is ${this:.3f} this week against ${prev:.3f} last week ({change:+.1f}%). Check the mixes and lots introduced this week and the milk recorded against them.",
            evidence={"cost_per_litre_this_week": this, "cost_per_litre_last_week": prev, "change_pct": change, "effective_feed_value": value,
                      "suggested_actions": [{"code": "review_mix_costs", "label": "Compare the unit cost and DM-adjusted cost of this week's mixes", "target_type": "farm", "target_id": farm_id},
                                            {"code": "review_production", "label": "Check whether milk fell or feed cost rose", "target_type": "farm", "target_id": farm_id}]},
            confidence=0.7, dedup_key=key, user_id=user_id,
        )
        if created:
            write_event(db, farm_id=farm_id, entity_type="farm", entity_id=farm_id, event_type="feed_cost_efficiency_changed",
                        payload={"this_week": this, "last_week": prev, "change_pct": change}, created_by=user_id)
    elif change is not None:
        resolve_alerts(db, farm_id, dedup_key=key, reason="cost per litre back within range", user_id=user_id)
    return {"cost_per_litre_this_week": this, "cost_per_litre_last_week": prev, "change_pct": change, "effective_feed_value": value}


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
            evidence={"refusals_3d": count, "suggested_actions": [{"code": "compare_intake", "label": "Compare offered against eaten", "target_type": stype, "target_id": sid},
                                                                   {"code": "inspect_lot", "label": "Inspect the lots being issued", "target_type": stype, "target_id": sid}]},
            confidence=0.8, dedup_key=f"{stype}:{sid}|INTAKE_OR_REFUSAL_ANOMALY", subject_type=stype, subject_id=sid, user_id=user_id,
        )
        out.append(alert)
    return out


# ------------------------------------------------------------------ cycle
def run_cycle(db: Session, farm_id: str, *, as_of: datetime | None = None, monitor_id: str | None = None, user_id: str = "system") -> dict:
    """The daily feed-performance cycle (§12): default monitors, fresh
    exposure projection, every active monitor evaluated, mixes, ingredient
    lots and suppliers scored, cost and intake checked. Idempotent —
    alerts are deduplicated and projections rebuilt."""
    ensure_default_monitors(db, farm_id, user_id=user_id)
    rebuild_exposures(db, farm_id)
    stmt = select(fm.FeedPerformanceMonitor).where(fm.FeedPerformanceMonitor.farm_id == farm_id, fm.FeedPerformanceMonitor.active.is_(True))
    if monitor_id:
        stmt = stmt.where(fm.FeedPerformanceMonitor.id == monitor_id)
    assessments = [evaluate_monitor(db, m, as_of=as_of, user_id=user_id, trigger="cycle") for m in db.scalars(stmt)]
    scores = score_all_batches(db, farm_id, user_id=user_id)
    lots = ingredient_lot_performance(db, farm_id, user_id=user_id)
    suppliers = supplier_performance(db, farm_id, user_id=user_id)
    cost = check_cost_efficiency(db, farm_id, user_id=user_id)
    intake = check_intake(db, farm_id, user_id=user_id)
    open_alerts = db.scalar(select(func.count(fm.FeedPerformanceAlert.id)).where(fm.FeedPerformanceAlert.farm_id == farm_id, fm.FeedPerformanceAlert.status != "resolved")) or 0
    return {
        "evaluated_at": (ensure_utc(as_of) if as_of else now()), "monitors": len(assessments),
        "assessments": [assessment_dict(db, a) for a in assessments], "anomalies": sum(1 for a in assessments if a.status == "anomaly"),
        "insufficient": sum(1 for a in assessments if a.status == "insufficient"), "batches_scored": len(scores), "ingredient_lots_evaluated": len(lots),
        "ingredient_lot_anomalies": sum(1 for f in lots if f["weak"]), "suppliers": len(suppliers),
        "cost_efficiency": cost, "intake_alerts": len(intake), "open_alerts": open_alerts,
    }


# ---------------------------------------------------------- hooks & views
def _monitors_for(db: Session, subject_type: str, subject) -> list[fm.FeedPerformanceMonitor]:
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
    return monitors


def _reevaluate(db: Session, subject_type: str, subject, *, trigger: str, user_id: str) -> int:
    monitors = _monitors_for(db, subject_type, subject)
    if not monitors:
        return 0
    rebuild_exposures(db, subject.farm_id)
    for m in monitors:
        evaluate_monitor(db, m, user_id=user_id, trigger=trigger)
    return len(monitors)


def on_batch_completed(db: Session, batch: fm.FeedBatch, *, user_id: str) -> None:
    score_batch(db, batch, user_id=user_id)


def on_production_recorded(db: Session, subject_type: str, subject, *, user_id: str) -> None:
    """After a milk or egg record: re-evaluate the monitors of the subject
    and of its group. Cheap, and it keeps alerts current between cycles."""
    _reevaluate(db, subject_type, subject, trigger="production_recorded", user_id=user_id)


def on_feeding_recorded(db: Session, subject_type: str, subject, *, user_id: str) -> None:
    """§12 FeedingEventRecorded: a new issue (or a refusal) re-evaluates
    the subject's monitors, so a feed change is on record the day it starts."""
    _reevaluate(db, subject_type, subject, trigger="feeding_recorded", user_id=user_id)


def on_context_changed(db: Session, subject_type: str, subject, *, trigger: str, user_id: str) -> None:
    """§12 FeedingProgramAssigned/changed, HealthCaseOpened/Closed and
    lifecycle / group / weight changes: the confounders moved, so the
    reading is taken again."""
    _reevaluate(db, subject_type, subject, trigger=trigger, user_id=user_id)


def on_lot_status_changed(db: Session, lot: fm.FeedLot, *, user_id: str) -> None:
    """§12 ingredient / output lot change: re-score the mixes that used
    the lot (or came out of it) and re-evaluate the subjects that
    received those mixes — the lot's standing is a supplier incident and
    an exposure fact at once."""
    batch_ids = set(db.scalars(select(fm.FeedBatchComponent.batch_id).where(fm.FeedBatchComponent.lot_id == lot.id)))
    if lot.feed_batch_id:
        batch_ids.add(lot.feed_batch_id)
    output_lots = [lot.id]
    for bid in batch_ids:
        batch = db.get(fm.FeedBatch, bid)
        if batch is None:
            continue
        if batch.status in ("completed", "quarantined"):
            score_batch(db, batch, user_id=user_id)
        if batch.output_lot_id:
            output_lots.append(batch.output_lot_id)
    subjects = set(db.execute(select(fm.FeedingEvent.subject_type, fm.FeedingEvent.subject_id).join(fm.FeedingEventComponent, fm.FeedingEventComponent.event_id == fm.FeedingEvent.id)
                              .where(fm.FeedingEventComponent.lot_id.in_(output_lots), fm.FeedingEvent.status == "recorded")).all())
    rebuilt = False
    for stype, sid in subjects:
        subject = _subject(db, stype, sid)
        if subject is None:
            continue
        monitors = _monitors_for(db, stype, subject)
        if not monitors:
            continue
        if not rebuilt:
            rebuild_exposures(db, lot.farm_id)
            rebuilt = True
        for m in monitors:
            evaluate_monitor(db, m, user_id=user_id, trigger="lot_status_changed")
    if lot.source_type == "purchased":
        supplier_performance(db, lot.farm_id, user_id=user_id)


def on_receipt(db: Session, farm_id: str, *, user_id: str) -> None:
    """§12 supplier receipt or cost update: the supplier rows and the cost
    picture are refreshed."""
    supplier_performance(db, farm_id, user_id=user_id)
    check_cost_efficiency(db, farm_id, user_id=user_id)


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
        "baseline_method_applied": (a.evidence_json or {}).get("baseline_method_applied"), "suggested_actions": (a.evidence_json or {}).get("suggested_actions", []),
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
        "suggested_actions": (a.evidence_json or {}).get("suggested_actions", []),
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
        "effective_feed_value": effective_feed_value(db, farm_id), "baseline_methods": list(BASELINE_METHODS), "metrics": list(METRICS),
        "model_reference": MODEL_REFERENCE, "model_version": MODEL_VERSION,
    }


def performance_signals(db: Session, farm_id: str) -> list:
    """Open feed-performance alerts for the notification bell, addressed
    to the people the farm routes them to. Acknowledged ones stay out of
    the bell but open in the list."""
    from app.services.signals_service import Signal, routed  # local import: signals imports this module

    out = []
    for a in db.scalars(select(fm.FeedPerformanceAlert).where(fm.FeedPerformanceAlert.farm_id == farm_id, fm.FeedPerformanceAlert.status == "open")):
        entity_type, entity_id = _alert_entity(a)
        base = Signal(
            source_type="feed_performance_alert", source_id=a.id, module_code=perms.FEED_NUTRITION,
            notification_type=f"feed_performance_{a.alert_type.lower()}", title=a.title, description=a.explanation[:300], priority=a.severity,
            entity_type=entity_type, entity_id=entity_id,
            metadata={"alert_id": a.id, "alert_type": a.alert_type, "confidence": a.confidence_score, "feed_batch_id": a.feed_batch_id},
        )
        out.extend(routed(db, farm_id, "feed_performance", base))
    return out
