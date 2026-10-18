"""Health cases, diagnoses, treatment plans, standing conditions and
weight records (database/HEALTH-VETERINARY-SCHEMA.md).

Anyone with animal-health view reads. Opening, updating and closing a
case needs animal-health create / edit. A diagnosis, a plan and a
recorded allergy or condition are clinical: a veterinarian or manager
(CONSTITUTION: veterinarians diagnose and prescribe). A weight is an
animal fact anyone who edits animals or records health may enter.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_diagnostic_role, require_permission, user_can
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import health_models as hm
from app.domain import models
from app.schemas.health_cases import ConditionIn, DiagnosisIn, HealthCaseClose, HealthCaseIn, HealthCasePatch, TreatmentPlanIn, WeightIn
from app.services import health_case_service as cases

router = APIRouter(tags=["health-cases"])

_view = require_permission(perms.ANIMAL_HEALTH, perms.VIEW)
_create = require_permission(perms.ANIMAL_HEALTH, perms.CREATE)
_edit = require_permission(perms.ANIMAL_HEALTH, perms.EDIT)


def _weight_writer(db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> models.User:
    if user_can(db, user, perms.ANIMALS, perms.EDIT) or user_can(db, user, perms.ANIMAL_HEALTH, perms.CREATE):
        return user
    raise HTTPException(status.HTTP_403_FORBIDDEN, "Recording a weight needs Animals edit or Animal Health create.")


def _animal(db: Session, animal_id: str, farm_id: str) -> models.Animal:
    a = db.get(models.Animal, animal_id)
    if a is None or a.farm_id != farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Animal not found")
    return a


# ---------------------------------------------------------------- cases
@router.get("/health/cases")
def list_cases(case_status: str | None = Query("active", alias="status"), subject_id: str | None = None, limit: int = Query(100, ge=1, le=500),
               db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    """`status=active` (default) is open and monitoring; `all` includes
    closed cases."""
    stmt = select(hm.HealthCase).where(hm.HealthCase.farm_id == user.farm_id)
    if case_status == "active":
        stmt = stmt.where(hm.HealthCase.status.in_(cases.OPEN_STATUSES))
    elif case_status and case_status != "all":
        stmt = stmt.where(hm.HealthCase.status == case_status)
    if subject_id:
        stmt = stmt.where((hm.HealthCase.animal_id == subject_id) | (hm.HealthCase.animal_group_id == subject_id))
    return [cases.case_dict(db, c, with_details=False) for c in db.scalars(stmt.order_by(hm.HealthCase.opened_at.desc()).limit(limit))]


@router.post("/health/cases", status_code=status.HTTP_201_CREATED)
def open_case(payload: HealthCaseIn, db: Session = Depends(get_db), user: models.User = Depends(_create)) -> dict:
    c = cases.open_case(db, user.farm_id, user_id=user.id, source_type="manual", **payload.model_dump())
    db.commit()
    return cases.case_dict(db, c)


@router.get("/health/cases/{case_id}")
def get_case(case_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return cases.case_dict(db, cases.get_case(db, case_id, user.farm_id))


@router.patch("/health/cases/{case_id}")
def update_case(case_id: str, payload: HealthCasePatch, db: Session = Depends(get_db), user: models.User = Depends(_edit)) -> dict:
    c = cases.update_case(db, cases.get_case(db, case_id, user.farm_id), payload.model_dump(exclude_unset=True), user_id=user.id)
    db.commit()
    return cases.case_dict(db, c)


@router.post("/health/cases/{case_id}/close")
def close_case(case_id: str, payload: HealthCaseClose, db: Session = Depends(get_db), user: models.User = Depends(_edit)) -> dict:
    c = cases.close_case(db, cases.get_case(db, case_id, user.farm_id), outcome=payload.outcome, status=payload.status, user_id=user.id)
    db.commit()
    return cases.case_dict(db, c)


@router.post("/health/cases/{case_id}/diagnoses", status_code=status.HTTP_201_CREATED)
def record_diagnosis(case_id: str, payload: DiagnosisIn, db: Session = Depends(get_db), user: models.User = Depends(require_diagnostic_role)) -> dict:
    """A diagnosis with its certainty, by a diagnostic role. The AI never
    writes one."""
    c = cases.get_case(db, case_id, user.farm_id)
    d = cases.record_diagnosis(db, c, user=user, **payload.model_dump())
    db.commit()
    return cases.diagnosis_dict(db, d)


@router.post("/health/cases/{case_id}/plans", status_code=status.HTTP_201_CREATED)
def prescribe_plan(case_id: str, payload: TreatmentPlanIn, db: Session = Depends(get_db), user: models.User = Depends(require_diagnostic_role)) -> dict:
    c = cases.get_case(db, case_id, user.farm_id)
    p = cases.prescribe_plan(db, c, instructions=payload.instructions, user=user)
    db.commit()
    return cases.plan_dict(db, p)


# ------------------------------------------------------------ conditions
@router.get("/animals/{animal_id}/conditions")
def list_conditions(animal_id: str, include_ended: bool = False, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    _animal(db, animal_id, user.farm_id)
    stmt = select(hm.AnimalHealthCondition).where(hm.AnimalHealthCondition.animal_id == animal_id)
    if not include_ended:
        stmt = stmt.where(hm.AnimalHealthCondition.active.is_(True))
    return [cases.condition_dict(db, c) for c in db.scalars(stmt.order_by(hm.AnimalHealthCondition.recorded_at.desc()))]


@router.post("/animals/{animal_id}/conditions", status_code=status.HTTP_201_CREATED)
def record_condition(animal_id: str, payload: ConditionIn, db: Session = Depends(get_db), user: models.User = Depends(require_diagnostic_role)) -> dict:
    """An allergy, adverse reaction, chronic condition or contraindication
    the veterinarian puts on the animal's record. The emergency engine's
    eligibility rules read it as an authoritative fact."""
    _animal(db, animal_id, user.farm_id)
    c = cases.record_condition(db, user.farm_id, animal_id=animal_id, user=user, **payload.model_dump())
    db.commit()
    return cases.condition_dict(db, c)


@router.delete("/animals/{animal_id}/conditions/{condition_id}")
def end_condition(animal_id: str, condition_id: str, db: Session = Depends(get_db), user: models.User = Depends(require_diagnostic_role)) -> dict:
    c = db.get(hm.AnimalHealthCondition, condition_id)
    if c is None or c.animal_id != animal_id or c.farm_id != user.farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Condition not found")
    cases.end_condition(db, c, user=user)
    db.commit()
    return cases.condition_dict(db, c)


# --------------------------------------------------------------- weights
@router.get("/animals/{animal_id}/weights")
def list_weights(animal_id: str, limit: int = Query(50, ge=1, le=500), db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> list[dict]:
    _animal(db, animal_id, user.farm_id)
    return [cases.weight_dict(db, w) for w in cases.weight_history(db, animal_id, limit=limit)]


@router.post("/animals/{animal_id}/weights", status_code=status.HTTP_201_CREATED)
def record_weight(animal_id: str, payload: WeightIn, db: Session = Depends(get_db), user: models.User = Depends(_weight_writer)) -> dict:
    """A dated weight with its method; the animal's `weight_kg` becomes
    the latest of them."""
    animal = _animal(db, animal_id, user.farm_id)
    w = cases.record_weight(db, user.farm_id, animal, user_id=user.id, source_type="manual", **payload.model_dump())
    db.commit()
    return cases.weight_dict(db, w)
