"""Evaluates the rule engine (app/recommendations/engine.py) against
current database state and persists fresh [models.Recommendation] rows.

CONSTITUTION.md: "Every recommendation requires evidence." Every draft
produced here is backed by real rows read from the database in this
function — nothing is hand-authored or hardcoded per farm.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from statistics import mean

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import models
from app.recommendations import engine
from app.repositories.base import ensure_utc, new_id


def _pct_change(latest: float, baseline: float) -> float | None:
    if baseline == 0:
        return None
    return (latest - baseline) / baseline * 100


def _animal_milk_change_pct(db: Session, animal_id: str) -> float | None:
    records = db.scalars(
        select(models.MilkRecord)
        .where(models.MilkRecord.animal_id == animal_id)
        .order_by(models.MilkRecord.recorded_at.desc())
        .limit(8)
    ).all()
    if len(records) < 3:
        return None
    latest = records[0].liters
    baseline = mean(r.liters for r in records[1:])
    return _pct_change(latest, baseline)


def _animal_feed_change_pct(db: Session, animal_id: str) -> float | None:
    records = db.scalars(
        select(models.InventoryTransaction)
        .where(
            models.InventoryTransaction.linked_entity_type == "animal",
            models.InventoryTransaction.linked_entity_id == animal_id,
            models.InventoryTransaction.direction == "out",
        )
        .order_by(models.InventoryTransaction.created_at.desc())
        .limit(8)
    ).all()
    if len(records) < 3:
        return None
    latest = records[0].quantity
    baseline = mean(r.quantity for r in records[1:])
    return _pct_change(latest, baseline)


_FEVER_OBSERVATION_TYPES = {"fever", "nasal_discharge", "coughing"}


def _animal_temperature_proxy(db: Session, animal_id: str) -> float | None:
    """The mobile capture flow records qualitative fever signs (Level C
    human observation), not an instrument temperature reading (Level A) —
    see handbook/04.3-Observation-Model.md. When a moderate/severe fever
    sign was logged in the last 3 days we use a representative elevated
    value; instrument-measured readings (once wired) would replace this.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(days=3)
    obs = db.scalars(
        select(models.Observation)
        .where(
            models.Observation.entity_type == "animal",
            models.Observation.entity_id == animal_id,
            models.Observation.observation_type.in_(_FEVER_OBSERVATION_TYPES),
            models.Observation.observed_at >= cutoff,
        )
        .order_by(models.Observation.observed_at.desc())
    ).first()
    if obs is None:
        return None
    if obs.value_numeric is not None:
        return obs.value_numeric
    if obs.severity in {"moderate", "severe"}:
        return 39.6
    return None


def _animal_prior_conditions(db: Session, animal_id: str) -> tuple[int, str | None]:
    cutoff = datetime.now(timezone.utc) - timedelta(days=180)
    treatments = db.scalars(
        select(models.Treatment).where(
            models.Treatment.entity_type == "animal",
            models.Treatment.entity_id == animal_id,
            models.Treatment.start_at >= cutoff,
            models.Treatment.diagnosis.is_not(None),
        )
    ).all()
    if not treatments:
        return 0, None
    label = treatments[0].diagnosis
    return len(treatments), label


def _item_daily_usage(db: Session, item_id: str) -> float | None:
    cutoff = datetime.now(timezone.utc) - timedelta(days=7)
    rows = db.scalars(
        select(models.InventoryTransaction).where(
            models.InventoryTransaction.item_id == item_id,
            models.InventoryTransaction.direction == "out",
            models.InventoryTransaction.created_at >= cutoff,
        )
    ).all()
    if not rows:
        return None
    return sum(r.quantity for r in rows) / 7


def _flock_egg_baseline(db: Session, flock_id: str) -> tuple[int, int] | None:
    records = db.scalars(
        select(models.EggRecord).where(models.EggRecord.flock_id == flock_id).order_by(models.EggRecord.recorded_at.desc()).limit(8)
    ).all()
    if len(records) < 2:
        return None
    latest = records[0].total_eggs
    baseline = round(mean(r.total_eggs for r in records[1:]))
    return latest, baseline


def _persist(db: Session, farm_id: str, draft: engine.RecommendationDraft) -> models.Recommendation:
    rec = models.Recommendation(
        id=new_id(),
        farm_id=farm_id,
        category=draft.category,
        priority=draft.priority,
        title=draft.title,
        entity_type=draft.entity_type,
        entity_id=draft.entity_id,
        entity_label=draft.entity_label,
        confidence=draft.confidence,
        rationale=draft.rationale,
        suggested_action=draft.suggested_action,
        rule_id=draft.rule_id,
        status="generated",
        generated_at=datetime.now(timezone.utc),
    )
    db.add(rec)
    db.flush()
    for item in draft.evidence:
        db.add(models.RecommendationEvidence(id=new_id(), recommendation_id=rec.id, label=item.label, value=item.value))
    return rec


def regenerate_recommendations(db: Session, farm_id: str) -> list[models.Recommendation]:
    # Clear only *undecided* recommendations — decided ones are history and
    # must never be silently deleted (CONSTITUTION.md).
    stale = db.scalars(
        select(models.Recommendation).where(models.Recommendation.farm_id == farm_id, models.Recommendation.status == "generated")
    ).all()
    for rec in stale:
        db.query(models.RecommendationEvidence).filter(models.RecommendationEvidence.recommendation_id == rec.id).delete()
        db.delete(rec)
    db.flush()

    drafts: list[engine.RecommendationDraft] = []
    now = datetime.now(timezone.utc)

    for animal in db.scalars(select(models.Animal).where(models.Animal.farm_id == farm_id, models.Animal.active.is_(True))):
        milk_pct = _animal_milk_change_pct(db, animal.id)
        feed_pct = _animal_feed_change_pct(db, animal.id)
        temp = _animal_temperature_proxy(db, animal.id)
        prior_count, prior_label = _animal_prior_conditions(db, animal.id)
        draft = engine.evaluate_health_risk(
            entity_type="animal",
            entity_id=animal.id,
            entity_label=f"{animal.name} #{animal.tag}",
            milk_change_pct=milk_pct,
            feed_change_pct=feed_pct,
            temperature_c=temp,
            prior_condition_count=prior_count,
            prior_condition_label=prior_label,
        )
        if draft:
            drafts.append(draft)

        if animal.withdrawal_until is not None and ensure_utc(animal.withdrawal_until) > now:
            wd_draft = engine.evaluate_withdrawal_conflict(
                animal_id=animal.id,
                animal_label=f"{animal.name} #{animal.tag}",
                withdrawal_until_label=animal.withdrawal_until.date().isoformat(),
                destination="sold",
            )
            if wd_draft:
                drafts.append(wd_draft)

    for item in db.scalars(select(models.InventoryItem).where(models.InventoryItem.farm_id == farm_id)):
        draft = engine.evaluate_low_feed(
            item_id=item.id,
            item_name=item.name,
            current_qty=item.current_qty,
            reorder_level=item.reorder_level,
            unit=item.unit,
            daily_usage=_item_daily_usage(db, item.id),
        )
        if draft:
            drafts.append(draft)

    for flock in db.scalars(select(models.Flock).where(models.Flock.farm_id == farm_id)):
        baseline = _flock_egg_baseline(db, flock.id)
        if baseline:
            latest, base = baseline
            draft = engine.evaluate_egg_drop(flock_id=flock.id, flock_name=flock.name, current_total=latest, baseline_total=base)
            if draft:
                drafts.append(draft)

    for field in db.scalars(select(models.Field).where(models.Field.farm_id == farm_id)):
        if field.expected_harvest_date is None:
            continue
        hours = (ensure_utc(field.expected_harvest_date) - now).total_seconds() / 3600
        draft = engine.evaluate_harvest_due(
            field_id=field.id, field_name=field.name, crop_type=field.crop_type or field.name, hours_until_harvest=hours, est_yield_kg=field.est_yield_kg
        )
        if draft:
            drafts.append(draft)

    today_start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    expenses_today = db.scalars(select(models.Expense).where(models.Expense.farm_id == farm_id, models.Expense.incurred_at >= today_start)).all()
    if expenses_today:
        total_expense = sum(e.amount for e in expenses_today)
        feed_expense = sum(e.amount for e in expenses_today if e.category == "feed")
        draft = engine.evaluate_feed_cost_insight(feed_expense=feed_expense, total_expense=total_expense)
        if draft:
            drafts.append(draft)

    return [_persist(db, farm_id, d) for d in drafts]
