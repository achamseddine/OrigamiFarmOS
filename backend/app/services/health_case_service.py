"""Health cases, diagnoses, treatment plans, standing conditions and weight
history (database/HEALTH-VETERINARY-SCHEMA.md).

The boundary the schema insists on, enforced here: a worker's observation
never becomes a diagnosis; a diagnosis is recorded by a diagnostic role
(manager, owner, veterinarian) with a certainty; a treatment plan is the
prescription frame; an administration is the pharmacy's fact. A case is
the episode they all hang on — opened by a person or by the emergency
engine, closed with an outcome, never deleted.

Weights are dated records with a method; the animal's `weight_kg` is only
the latest of them. A per-weight protocol dose reads the record and its
age, not the denormalised number.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.domain import health_models as hm
from app.domain import models
from app.repositories.base import ensure_utc, new_id, now, write_event
from app.services.feed_inventory_service import FeedError

DIAGNOSTIC_ROLES = {"owner", "manager", "veterinarian"}
OPEN_STATUSES = ("open", "monitoring")


class HealthError(FeedError):
    """A clinical-boundary rule refused the operation."""


# ---------------------------------------------------------------- helpers
def _subject(db: Session, subject_type: str, subject_id: str, farm_id: str):
    if subject_type not in ("animal", "group"):
        raise HealthError("subject_type must be animal or group")
    row = db.get(models.Animal, subject_id) if subject_type == "animal" else db.get(models.Flock, subject_id)
    if row is None or row.farm_id != farm_id:
        raise HealthError("Subject not found", 404)
    return row


def _require_diagnostic(user: models.User, what: str) -> None:
    if user.role not in DIAGNOSTIC_ROLES:
        raise HealthError(f"Only a veterinarian or farm manager can {what}. Workers record observations.", 403)


def get_case(db: Session, case_id: str, farm_id: str) -> hm.HealthCase:
    c = db.get(hm.HealthCase, case_id)
    if c is None or c.farm_id != farm_id:
        raise HealthError("Health case not found", 404)
    return c


def _subject_filter(subject_type: str, subject_id: str):
    return (hm.HealthCase.animal_id == subject_id) if subject_type == "animal" else (hm.HealthCase.animal_group_id == subject_id)


def current_case(db: Session, subject_type: str, subject_id: str) -> hm.HealthCase | None:
    return db.scalar(select(hm.HealthCase).where(_subject_filter(subject_type, subject_id), hm.HealthCase.status.in_(OPEN_STATUSES))
                     .order_by(hm.HealthCase.opened_at.desc()))


def next_case_code(db: Session, farm_id: str) -> str:
    n = (db.scalar(select(func.count(hm.HealthCase.id)).where(hm.HealthCase.farm_id == farm_id)) or 0) + 1
    while db.scalar(select(hm.HealthCase.id).where(hm.HealthCase.farm_id == farm_id, hm.HealthCase.case_code == f"HC-{n:06d}")):
        n += 1
    return f"HC-{n:06d}"


def _on_case_changed(db: Session, case: hm.HealthCase, *, user_id: str) -> None:
    """A health case opening or closing is a feed-performance confounder
    (FEED-PERFORMANCE-INTELLIGENCE §12 HealthCaseOpened/Closed)."""
    from app.services import feed_performance_service as perf  # local: avoids a cycle through the signals module

    subject_type = "animal" if case.animal_id else "group"
    subject = db.get(models.Animal, case.animal_id) if case.animal_id else db.get(models.Flock, case.animal_group_id)
    if subject is not None:
        perf.on_context_changed(db, subject_type, subject, trigger="health_case", user_id=user_id)


# ------------------------------------------------------------------ cases
def open_case(db: Session, farm_id: str, *, subject_type: str, subject_id: str, severity_code: str | None = None, primary_problem_code: str | None = None,
              responsible_user_id: str | None = None, source_type: str = "manual", source_id: str | None = None, notes: str | None = None,
              opened_at: datetime | None = None, user_id: str) -> hm.HealthCase:
    subject = _subject(db, subject_type, subject_id, farm_id)
    if severity_code is not None and severity_code not in hm.CASE_SEVERITIES:
        raise HealthError(f"severity_code must be one of {list(hm.CASE_SEVERITIES)}")
    case = hm.HealthCase(
        id=new_id(), farm_id=farm_id, animal_id=subject_id if subject_type == "animal" else None, animal_group_id=subject_id if subject_type == "group" else None,
        case_code=next_case_code(db, farm_id), opened_at=ensure_utc(opened_at) if opened_at else now(), status="open", severity_code=severity_code,
        primary_problem_code=primary_problem_code, responsible_user_id=responsible_user_id, source_type=source_type, source_id=source_id, notes=notes,
        created_by=user_id, created_at=now(),
    )
    db.add(case)
    db.flush()
    # Observations of the last day on this subject join the case.
    since = case.opened_at - timedelta(hours=24)
    entity_types = ("animal",) if subject_type == "animal" else ("flock", "group")
    for o in db.scalars(select(models.Observation).where(models.Observation.entity_type.in_(entity_types), models.Observation.entity_id == subject_id,
                                                         models.Observation.observed_at >= since, models.Observation.health_case_id.is_(None))):
        o.health_case_id = case.id
    write_event(db, farm_id=farm_id, entity_type=subject_type if subject_type == "animal" else "flock", entity_id=subject_id, event_type="health_case_opened",
                payload={"case_id": case.id, "case_code": case.case_code, "severity": severity_code, "problem": primary_problem_code, "source": source_type, "source_id": source_id},
                created_by=user_id)
    if getattr(subject, "status", None) == "healthy":
        subject.status = "under_observation"
    _on_case_changed(db, case, user_id=user_id)
    return case


def open_or_current_case(db: Session, farm_id: str, *, subject_type: str, subject_id: str, user_id: str, **fields) -> hm.HealthCase:
    """The open case for the subject, or a new one — the emergency engine
    never opens a twin for the same animal."""
    existing = current_case(db, subject_type, subject_id)
    if existing is not None:
        if fields.get("severity_code") and _severity_rank(fields["severity_code"]) > _severity_rank(existing.severity_code):
            existing.severity_code = fields["severity_code"]
        return existing
    return open_case(db, farm_id, subject_type=subject_type, subject_id=subject_id, user_id=user_id, **fields)


def _severity_rank(code: str | None) -> int:
    return hm.CASE_SEVERITIES.index(code) if code in hm.CASE_SEVERITIES else -1


def update_case(db: Session, case: hm.HealthCase, changes: dict, *, user_id: str) -> hm.HealthCase:
    if case.status in ("resolved", "closed"):
        raise HealthError("This case is closed; reopen it with a new case.")
    for k in ("severity_code", "primary_problem_code", "responsible_user_id", "notes"):
        if k in changes:
            setattr(case, k, changes[k])
    if changes.get("status") in OPEN_STATUSES:
        case.status = changes["status"]
    if case.severity_code is not None and case.severity_code not in hm.CASE_SEVERITIES:
        raise HealthError(f"severity_code must be one of {list(hm.CASE_SEVERITIES)}")
    write_event(db, farm_id=case.farm_id, entity_type="health_case", entity_id=case.id, event_type="health_case_updated",
                payload={"changed": sorted(changes)}, created_by=user_id)
    return case


def close_case(db: Session, case: hm.HealthCase, *, outcome: str, status: str = "resolved", user_id: str) -> hm.HealthCase:
    if case.status in ("resolved", "closed"):
        return case
    if status not in ("resolved", "closed"):
        raise HealthError("A case closes as resolved or closed.")
    if not outcome or not outcome.strip():
        raise HealthError("Say how the case ended.")
    case.status = status
    case.closed_at = now()
    case.outcome = outcome.strip()
    for d in case.diagnoses:
        if d.status == "active":
            d.status = "resolved"
    for p in case.plans:
        if p.status in ("prescribed", "active"):
            p.status = "completed"
            p.completed_at = now()
    subject_type = "animal" if case.animal_id else "flock"
    write_event(db, farm_id=case.farm_id, entity_type=subject_type, entity_id=case.animal_id or case.animal_group_id, event_type="health_case_closed",
                payload={"case_id": case.id, "case_code": case.case_code, "outcome": case.outcome, "status": status}, created_by=user_id)
    _on_case_changed(db, case, user_id=user_id)
    return case


# ------------------------------------------------------------- diagnoses
def record_diagnosis(db: Session, case: hm.HealthCase, *, diagnosis_code: str, diagnosis_text: str | None = None, certainty_code: str = "suspected",
                     supersedes_diagnosis_id: str | None = None, notes: str | None = None, diagnosed_at: datetime | None = None, user: models.User) -> hm.Diagnosis:
    """Diagnosis is clinical (CONSTITUTION: veterinarians diagnose and
    prescribe). The AI never calls this; a person with a diagnostic role
    does, with a certainty."""
    _require_diagnostic(user, "record a diagnosis")
    if case.status in ("resolved", "closed"):
        raise HealthError("This case is closed.")
    if certainty_code not in hm.CERTAINTIES:
        raise HealthError(f"certainty_code must be one of {list(hm.CERTAINTIES)}")
    if not diagnosis_code or not diagnosis_code.strip():
        raise HealthError("A diagnosis code is required.")
    previous = None
    if supersedes_diagnosis_id:
        previous = db.get(hm.Diagnosis, supersedes_diagnosis_id)
        if previous is None or previous.health_case_id != case.id:
            raise HealthError("The superseded diagnosis is not on this case.", 404)
        previous.status = "superseded"
    d = hm.Diagnosis(id=new_id(), health_case_id=case.id, diagnosis_code=diagnosis_code.strip(), diagnosis_text=diagnosis_text, certainty_code=certainty_code,
                     diagnosed_at=ensure_utc(diagnosed_at) if diagnosed_at else now(), diagnosed_by=user.id, status="active" if certainty_code != "ruled_out" else "resolved",
                     supersedes_diagnosis_id=supersedes_diagnosis_id, notes=notes)
    db.add(d)
    db.flush()
    if case.primary_problem_code is None and certainty_code != "ruled_out":
        case.primary_problem_code = d.diagnosis_code
    write_event(db, farm_id=case.farm_id, entity_type="health_case", entity_id=case.id, event_type="diagnosis_recorded",
                payload={"diagnosis_id": d.id, "code": d.diagnosis_code, "certainty": certainty_code, "supersedes": supersedes_diagnosis_id, "by": user.id}, created_by=user.id)
    _on_case_changed(db, case, user_id=user.id)
    return d


def active_diagnosis_codes(db: Session, subject_type: str, subject_id: str) -> list[str]:
    rows = db.scalars(select(hm.Diagnosis).join(hm.HealthCase, hm.HealthCase.id == hm.Diagnosis.health_case_id).where(
        _subject_filter(subject_type, subject_id), hm.HealthCase.status.in_(OPEN_STATUSES), hm.Diagnosis.status == "active")).all()
    return sorted({r.diagnosis_code.lower() for r in rows})


# ----------------------------------------------------------------- plans
def prescribe_plan(db: Session, case: hm.HealthCase, *, instructions: str | None, source_type: str | None = None, source_id: str | None = None,
                   user: models.User) -> hm.TreatmentPlan:
    _require_diagnostic(user, "prescribe a treatment plan")
    if case.status in ("resolved", "closed"):
        raise HealthError("This case is closed.")
    p = hm.TreatmentPlan(id=new_id(), health_case_id=case.id, status="prescribed", prescribed_at=now(), prescribed_by=user.id, instructions=instructions,
                         source_type=source_type, source_id=source_id, created_at=now())
    db.add(p)
    db.flush()
    write_event(db, farm_id=case.farm_id, entity_type="health_case", entity_id=case.id, event_type="treatment_prescribed",
                payload={"plan_id": p.id, "by": user.id, "source": source_type, "source_id": source_id}, created_by=user.id)
    return p


def record_treatment(db: Session, farm_id: str, *, entity_type: str, entity_id: str, medication: str, dose: str, route: str, responsible_user_id: str,
                     diagnosis: str | None = None, medicine_product_id: str | None = None, health_case_id: str | None = None, treatment_plan_id: str | None = None,
                     start_at: datetime | None = None, end_at: datetime | None = None, withdrawal_until: datetime | None = None, vet_id: str | None = None,
                     cost: float | None = None, notes: str | None = None, user: models.User) -> models.Treatment:
    """A prescription / treatment action (the schema's treatment_action).
    When the farm pharmacy stocks the medicine, the treatment names the
    product, and an administration under it must be of that product."""
    _require_diagnostic(user, "record a treatment")
    subject_type = "animal" if entity_type == "animal" else "group"
    subject = _subject(db, subject_type, entity_id, farm_id)
    product = None
    if medicine_product_id:
        from app.domain import pharmacy_models as pm  # local: the pharmacy depends on treatments, not the reverse

        product = db.get(pm.MedicineProduct, medicine_product_id)
        if product is None or product.farm_id != farm_id:
            raise HealthError("Medicine product not found in this farm's pharmacy", 404)
        if product.species_codes and subject.species not in product.species_codes:
            raise HealthError(f"{medication} is not authorised for {subject.species}; it is configured for {', '.join(product.species_codes)}.")
    case = None
    if health_case_id:
        case = get_case(db, health_case_id, farm_id)
        if (case.animal_id or case.animal_group_id) != entity_id:
            raise HealthError("The health case belongs to another subject.")
    else:
        case = current_case(db, subject_type, entity_id)
    plan = None
    if treatment_plan_id:
        plan = db.get(hm.TreatmentPlan, treatment_plan_id)
        if plan is None or (case is not None and plan.health_case_id != case.id):
            raise HealthError("The treatment plan is not on this case.", 404)
        if plan.status == "prescribed":
            plan.status = "active"
    t = models.Treatment(
        id=new_id(), entity_type=entity_type, entity_id=entity_id, diagnosis=diagnosis, medication=medication, medicine_product_id=medicine_product_id,
        health_case_id=case.id if case else None, treatment_plan_id=plan.id if plan else None, dose=dose, route=route, start_at=start_at or now(), end_at=end_at,
        withdrawal_until=withdrawal_until, vet_id=vet_id, responsible_user_id=responsible_user_id, cost=cost, notes=notes, status="active",
    )
    db.add(t)
    if entity_type == "animal":
        if withdrawal_until is not None:
            subject.withdrawal_until = withdrawal_until
            subject.withdrawal_reason = "Medication"
        subject.status = "under_treatment"
    db.flush()
    write_event(db, farm_id=farm_id, entity_type=entity_type, entity_id=entity_id, event_type="treatment_recorded",
                payload={"treatment_id": t.id, "medication": medication, "medicine_product_id": medicine_product_id, "health_case_id": t.health_case_id,
                         "withdrawal_until": withdrawal_until.isoformat() if withdrawal_until else None}, created_by=user.id)
    return t


# ------------------------------------------------------------ conditions
def record_condition(db: Session, farm_id: str, *, animal_id: str, condition_type: str, code: str, label: str, severity: str | None = None,
                     notes: str | None = None, user: models.User) -> hm.AnimalHealthCondition:
    _require_diagnostic(user, "record an allergy or condition")
    _subject(db, "animal", animal_id, farm_id)
    if condition_type not in hm.CONDITION_TYPES:
        raise HealthError(f"condition_type must be one of {list(hm.CONDITION_TYPES)}")
    if not code or not code.strip():
        raise HealthError("A condition names what it refers to (an active ingredient, a medicine product, a diagnosis code).")
    row = hm.AnimalHealthCondition(id=new_id(), farm_id=farm_id, animal_id=animal_id, condition_type=condition_type, code=code.strip().lower(), label=label.strip(),
                                   severity=severity, recorded_at=now(), recorded_by=user.id, active=True, notes=notes)
    db.add(row)
    db.flush()
    write_event(db, farm_id=farm_id, entity_type="animal", entity_id=animal_id, event_type="animal_condition_recorded",
                payload={"condition_id": row.id, "type": condition_type, "code": row.code, "label": row.label, "severity": severity}, created_by=user.id)
    return row


def end_condition(db: Session, condition: hm.AnimalHealthCondition, *, user: models.User) -> hm.AnimalHealthCondition:
    _require_diagnostic(user, "end a recorded condition")
    if not condition.active:
        return condition
    condition.active = False
    condition.ended_at = now()
    write_event(db, farm_id=condition.farm_id, entity_type="animal", entity_id=condition.animal_id, event_type="animal_condition_ended",
                payload={"condition_id": condition.id, "code": condition.code}, created_by=user.id)
    return condition


def active_conditions(db: Session, animal_id: str) -> list[hm.AnimalHealthCondition]:
    return list(db.scalars(select(hm.AnimalHealthCondition).where(hm.AnimalHealthCondition.animal_id == animal_id, hm.AnimalHealthCondition.active.is_(True))))


# ---------------------------------------------------------------- weights
def record_weight(db: Session, farm_id: str, animal: models.Animal, *, weight_kg: float, measured_at: datetime | None = None, method: str = "scale",
                  source_type: str = "manual", source_id: str | None = None, notes: str | None = None, user_id: str) -> hm.AnimalWeightRecord:
    if weight_kg is None or weight_kg <= 0:
        raise HealthError("Weight must be greater than zero.")
    if method not in hm.WEIGHT_METHODS:
        raise HealthError(f"method must be one of {list(hm.WEIGHT_METHODS)}")
    at = ensure_utc(measured_at) if measured_at else now()
    if at > now() + timedelta(minutes=5):
        raise HealthError("A weight cannot be measured in the future.")
    row = hm.AnimalWeightRecord(id=new_id(), farm_id=farm_id, animal_id=animal.id, weight_kg=float(weight_kg), measured_at=at, method=method,
                                recorded_by=user_id, source_type=source_type, source_id=source_id, notes=notes, created_at=now())
    db.add(row)
    db.flush()
    latest = latest_weight(db, animal.id)
    if latest is None or ensure_utc(latest.measured_at) <= at:
        animal.weight_kg = float(weight_kg)
    write_event(db, farm_id=farm_id, entity_type="animal", entity_id=animal.id, event_type="animal_weight_recorded",
                payload={"weight_record_id": row.id, "weight_kg": weight_kg, "measured_at": at.isoformat(), "method": method, "source": source_type}, created_by=user_id)
    from app.services import feed_performance_service as perf  # local import: see _on_case_changed

    perf.on_context_changed(db, "animal", animal, trigger="weight", user_id=user_id)
    return row


def latest_weight(db: Session, animal_id: str) -> hm.AnimalWeightRecord | None:
    return db.scalar(select(hm.AnimalWeightRecord).where(hm.AnimalWeightRecord.animal_id == animal_id).order_by(hm.AnimalWeightRecord.measured_at.desc()))


def weight_history(db: Session, animal_id: str, *, limit: int = 50) -> list[hm.AnimalWeightRecord]:
    return list(db.scalars(select(hm.AnimalWeightRecord).where(hm.AnimalWeightRecord.animal_id == animal_id).order_by(hm.AnimalWeightRecord.measured_at.desc()).limit(limit)))


def weight_age_days(db: Session, animal_id: str) -> tuple[float | None, int | None]:
    """(weight, age in days) of the most recent dated weight, or (None, None)."""
    rec = latest_weight(db, animal_id)
    if rec is None:
        return None, None
    return rec.weight_kg, int((now() - ensure_utc(rec.measured_at)).total_seconds() // 86400)


# ------------------------------------------------------------------ views
def _user_name(db: Session, user_id: str | None) -> str | None:
    u = db.get(models.User, user_id) if user_id else None
    return u.name if u else None


def diagnosis_dict(db: Session, d: hm.Diagnosis) -> dict:
    return {"id": d.id, "health_case_id": d.health_case_id, "diagnosis_code": d.diagnosis_code, "diagnosis_text": d.diagnosis_text, "certainty_code": d.certainty_code,
            "diagnosed_at": d.diagnosed_at, "diagnosed_by": d.diagnosed_by, "diagnosed_by_name": _user_name(db, d.diagnosed_by), "status": d.status,
            "supersedes_diagnosis_id": d.supersedes_diagnosis_id, "notes": d.notes}


def plan_dict(db: Session, p: hm.TreatmentPlan) -> dict:
    treatments = db.scalars(select(models.Treatment).where(models.Treatment.treatment_plan_id == p.id).order_by(models.Treatment.start_at)).all()
    return {"id": p.id, "health_case_id": p.health_case_id, "status": p.status, "prescribed_at": p.prescribed_at, "prescribed_by": p.prescribed_by,
            "prescribed_by_name": _user_name(db, p.prescribed_by), "instructions": p.instructions, "source_type": p.source_type, "source_id": p.source_id,
            "completed_at": p.completed_at, "treatments": [treatment_dict(t) for t in treatments]}


def treatment_dict(t: models.Treatment) -> dict:
    return {"id": t.id, "entity_type": t.entity_type, "entity_id": t.entity_id, "diagnosis": t.diagnosis, "medication": t.medication,
            "medicine_product_id": t.medicine_product_id, "health_case_id": t.health_case_id, "treatment_plan_id": t.treatment_plan_id, "dose": t.dose, "route": t.route,
            "start_at": t.start_at, "end_at": t.end_at, "withdrawal_until": t.withdrawal_until, "vet_id": t.vet_id, "responsible_user_id": t.responsible_user_id,
            "status": t.status, "cost": t.cost, "notes": t.notes}


def condition_dict(db: Session, c: hm.AnimalHealthCondition) -> dict:
    return {"id": c.id, "animal_id": c.animal_id, "condition_type": c.condition_type, "code": c.code, "label": c.label, "severity": c.severity,
            "recorded_at": c.recorded_at, "recorded_by": c.recorded_by, "recorded_by_name": _user_name(db, c.recorded_by), "ended_at": c.ended_at,
            "active": c.active, "notes": c.notes}


def weight_dict(db: Session, w: hm.AnimalWeightRecord) -> dict:
    return {"id": w.id, "animal_id": w.animal_id, "weight_kg": w.weight_kg, "measured_at": w.measured_at, "method": w.method, "recorded_by": w.recorded_by,
            "recorded_by_name": _user_name(db, w.recorded_by), "source_type": w.source_type, "source_id": w.source_id, "notes": w.notes}


def case_dict(db: Session, c: hm.HealthCase, *, with_details: bool = True) -> dict:
    subject_type = "animal" if c.animal_id else "group"
    subject = db.get(models.Animal, c.animal_id) if c.animal_id else db.get(models.Flock, c.animal_group_id)
    out = {
        "id": c.id, "farm_id": c.farm_id, "case_code": c.case_code, "subject_type": subject_type, "subject_id": c.animal_id or c.animal_group_id,
        "subject_name": getattr(subject, "name", None), "species": getattr(subject, "species", None), "opened_at": c.opened_at, "closed_at": c.closed_at,
        "status": c.status, "severity_code": c.severity_code, "primary_problem_code": c.primary_problem_code, "responsible_user_id": c.responsible_user_id,
        "responsible_user_name": _user_name(db, c.responsible_user_id), "source_type": c.source_type, "source_id": c.source_id, "outcome": c.outcome, "notes": c.notes,
        "created_by": c.created_by, "created_at": c.created_at, "active_diagnoses": [d.diagnosis_code for d in c.diagnoses if d.status == "active"],
    }
    if with_details:
        entity_types = ("animal",) if subject_type == "animal" else ("flock", "group")
        observations = db.scalars(select(models.Observation).where(models.Observation.health_case_id == c.id).order_by(models.Observation.observed_at.desc()).limit(30)).all()
        treatments = db.scalars(select(models.Treatment).where(models.Treatment.health_case_id == c.id).order_by(models.Treatment.start_at.desc())).all()
        out.update({
            "diagnoses": [diagnosis_dict(db, d) for d in c.diagnoses], "plans": [plan_dict(db, p) for p in c.plans],
            "treatments": [treatment_dict(t) for t in treatments],
            "observations": [{"id": o.id, "observation_type": o.observation_type, "value_numeric": o.value_numeric, "value_text": o.value_text, "unit": o.unit,
                              "severity": o.severity, "observed_at": o.observed_at, "entity_type": o.entity_type} for o in observations],
            "entity_types": list(entity_types),
        })
    return out
