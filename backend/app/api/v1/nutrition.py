"""Nutrient requirements and formula assessments (master prompt Package 11;
database/NUTRITION-ASSESSMENT.md).

    GET  /nutrition/requirement-sets                  the farm's requirement sets (current; ?include_retired)
    POST /nutrition/requirement-sets                  a new set, with its source (Feed approve)
    GET  /nutrition/requirement-sets/{id}
    POST /nutrition/requirement-sets/{id}/versions    a revision: a new version, the old one retired (Feed approve)
    GET  /nutrition/assessments                       the assessments (?formula_version_id)
    POST /nutrition/assessments                       assess a formula version (and its ration) against a set (Feed create)
    GET  /nutrition/assessments/{id}                  as it was computed
    GET  /nutrition/least-cost                        the least-cost runs (Package 12)
    POST /nutrition/least-cost                        up to three drafts at today's prices (Feed create)
    GET  /nutrition/least-cost/{id}
    POST /nutrition/least-cost/{id}/approve           one draft → a new draft formula version (Feed approve)

Whoever sees the feed reads them; an assessment never changes a formula,
a batch or a feeding program.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_permission, user_can
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.schemas.nutrition import AssessmentCreate, LeastCostApprove, LeastCostCreate, RequirementSetCreate, RequirementSetRevise
from app.services import least_cost_service as lcf
from app.services import nutrition_service as nut

router = APIRouter(tags=["nutrition"])

_view = require_permission(perms.FEED_NUTRITION, perms.VIEW)
_approve = require_permission(perms.FEED_NUTRITION, perms.APPROVE)


def _assess(db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> models.User:
    """Whoever makes feed (Feed create) or approves it runs an assessment."""
    if not (user_can(db, user, perms.FEED_NUTRITION, perms.CREATE) or user_can(db, user, perms.FEED_NUTRITION, perms.APPROVE)):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Assessing a formula needs Feed create or approve.")
    return user


@router.get("/nutrition/requirement-sets")
def list_requirement_sets(include_retired: bool = False, species_code: str | None = None, db: Session = Depends(get_db),
                          user: models.User = Depends(_view)) -> list[dict]:
    return [nut.set_dict(db, s) for s in nut.list_sets(db, user.farm_id, include_retired=include_retired, species_code=species_code)]


@router.post("/nutrition/requirement-sets", status_code=status.HTTP_201_CREATED)
def create_requirement_set(payload: RequirementSetCreate, db: Session = Depends(get_db), user: models.User = Depends(_approve)) -> dict:
    data = payload.model_dump()
    s = nut.create_set(db, user, **data)
    db.commit()
    return nut.set_dict(db, s)


@router.get("/nutrition/requirement-sets/{set_id}")
def get_requirement_set(set_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return nut.set_dict(db, nut.get_set(db, set_id, user.farm_id))


@router.post("/nutrition/requirement-sets/{set_id}/versions", status_code=status.HTTP_201_CREATED)
def revise_requirement_set(set_id: str, payload: RequirementSetRevise, db: Session = Depends(get_db), user: models.User = Depends(_approve)) -> dict:
    current = nut.get_set(db, set_id, user.farm_id)
    data = payload.model_dump()
    values = data.pop("values")
    s = nut.new_version(db, user, current, values=values, **data)
    db.commit()
    return nut.set_dict(db, s)


@router.get("/nutrition/assessments")
def list_assessments(formula_version_id: str | None = None, limit: int = Query(50, ge=1, le=200), db: Session = Depends(get_db),
                     user: models.User = Depends(_view)) -> list[dict]:
    return [nut.assessment_dict(db, a) for a in nut.list_assessments(db, user.farm_id, formula_version_id=formula_version_id, limit=limit)]


@router.post("/nutrition/assessments", status_code=status.HTTP_201_CREATED)
def create_assessment(payload: AssessmentCreate, db: Session = Depends(get_db), user: models.User = Depends(_assess)) -> dict:
    data = payload.model_dump()
    a = nut.assess(db, user, **data)
    db.commit()
    return nut.assessment_dict(db, a)


@router.get("/nutrition/assessments/{assessment_id}")
def get_assessment(assessment_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return nut.assessment_dict(db, nut.get_assessment(db, assessment_id, user.farm_id))


@router.get("/nutrition/least-cost")
def list_least_cost(limit: int = Query(30, ge=1, le=200), db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    return [lcf.run_dict(db, r) for r in lcf.list_runs(db, user.farm_id, limit=limit)]


@router.post("/nutrition/least-cost", status_code=status.HTTP_201_CREATED)
def create_least_cost(payload: LeastCostCreate, db: Session = Depends(get_db), user: models.User = Depends(_assess)) -> dict:
    data = payload.model_dump()
    r = lcf.run(db, user, **data)
    db.commit()
    return lcf.run_dict(db, r)


@router.get("/nutrition/least-cost/{run_id}")
def get_least_cost(run_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return lcf.run_dict(db, lcf.get_run(db, run_id, user.farm_id))


@router.post("/nutrition/least-cost/{run_id}/approve")
def approve_least_cost(run_id: str, payload: LeastCostApprove, db: Session = Depends(get_db), user: models.User = Depends(_approve)) -> dict:
    r = lcf.get_run(db, run_id, user.farm_id)
    version = lcf.approve(db, user, r, draft_key=payload.draft, note=payload.note, formula_id=payload.formula_id)
    db.commit()
    return {**lcf.run_dict(db, lcf.get_run(db, run_id, user.farm_id)),
            "formula_version": {"id": version.id, "formula_id": version.formula_id, "version": version.version, "status": version.status,
                                "batch_size": version.batch_size}}
