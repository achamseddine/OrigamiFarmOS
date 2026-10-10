"""Emergency protocol API (database/CLINICAL-DECISION-SUPPORT-EMERGENCY-PROTOCOLS.md).

Anyone with animal-health view reads; anyone with animal-health create
can assess, start an approved protocol, prepare and confirm its steps,
reassess and escalate — that is the point of care. Drafting protocols
needs animal-health configure (or edit). Approving a version is clinical:
a veterinarian only, with a reference.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_diagnostic_role, require_permission, user_can
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import emergency_models as em
from app.domain import models
from app.schemas.emergency import (
    ApproveVersionIn, AssessmentIn, ConfirmStepIn, EscalateIn, PrepareStepIn, ProtocolIn, ProtocolVersionIn, ReassessIn, ResolveRunIn, SkipStepIn, StartRunIn, WithdrawVersionIn,
)
from app.services import emergency_service as es

router = APIRouter(prefix="/emergency", tags=["emergency"])


def _either(*checks: tuple[str, str]):
    def _dep(db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> models.User:
        for module, action in checks:
            if user_can(db, user, module, action):
                return user
        raise HTTPException(status.HTTP_403_FORBIDDEN, "You do not have permission to configure emergency protocols. Ask a farm manager.")

    return _dep


_view = require_permission(perms.ANIMAL_HEALTH, perms.VIEW)
_act = require_permission(perms.ANIMAL_HEALTH, perms.CREATE)
_configure = _either((perms.ANIMAL_HEALTH, perms.CONFIGURE), (perms.ANIMAL_HEALTH, perms.EDIT))


def _keep_escalation(db: Session, call):
    """An engine refusal that escalated first (a withdrawn version, a
    blocked dose) must keep that escalation: commit what was written,
    then answer with the refusal."""
    try:
        return call()
    except es.EmergencyError:
        db.commit()
        raise


@router.get("/summary")
def emergency_summary(db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return es.summary(db, user.farm_id)


@router.get("/sign-codes")
def list_sign_codes(db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    """The sign vocabulary the tablet offers: the standard list plus any
    code a current approved protocol triggers on."""
    return es.sign_codes(db, user.farm_id)


@router.get("/offline-package")
def offline_package(db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    """Only offline-eligible approved versions, signed by content (§14)."""
    return es.offline_package(db, user.farm_id)


# -------------------------------------------------------------- protocols
@router.get("/protocols")
def list_protocols(include_withdrawn: bool = False, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    stmt = select(em.EmergencyProtocol).where(em.EmergencyProtocol.farm_id == user.farm_id)
    if not include_withdrawn:
        stmt = stmt.where(em.EmergencyProtocol.status != "withdrawn")
    return [es.protocol_dict(db, p) for p in db.scalars(stmt.order_by(em.EmergencyProtocol.title))]


@router.post("/protocols", status_code=status.HTTP_201_CREATED)
def create_protocol(payload: ProtocolIn, db: Session = Depends(get_db), user: models.User = Depends(_configure)) -> dict:
    """A protocol with its first draft version. Nothing is operational
    until a veterinarian approves the version."""
    p = es.create_protocol(db, user.farm_id, code=payload.code, title=payload.title, condition_family_code=payload.condition_family_code, species_code=payload.species_code,
                           subject_scope=payload.subject_scope, version=payload.version.model_dump(), user_id=user.id)
    db.commit()
    return es.protocol_dict(db, p)


@router.get("/protocols/{protocol_id}")
def get_protocol(protocol_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return es.protocol_dict(db, es.get_protocol(db, protocol_id, user.farm_id))


@router.post("/protocols/{protocol_id}/versions", status_code=status.HTTP_201_CREATED)
def add_version(protocol_id: str, payload: ProtocolVersionIn, db: Session = Depends(get_db), user: models.User = Depends(_configure)) -> dict:
    p = es.get_protocol(db, protocol_id, user.farm_id)
    v = es.add_version(db, p, user_id=user.id, **payload.model_dump())
    db.commit()
    return es.version_dict(db, v)


@router.post("/protocols/{protocol_id}/versions/{version_id}/approve")
def approve_version(protocol_id: str, version_id: str, payload: ApproveVersionIn, db: Session = Depends(get_db), user: models.User = Depends(require_diagnostic_role)) -> dict:
    """Veterinary approval (§3). The service refuses anyone but a
    veterinarian; the approval is written once."""
    v = es.get_version(db, version_id, user.farm_id)
    if v.emergency_protocol_id != protocol_id:
        raise es.EmergencyError("Version does not belong to this protocol", 404)
    es.approve_version(db, v, approver=user, approval_reference=payload.approval_reference, effective_from=payload.effective_from)
    db.commit()
    return es.protocol_dict(db, v.protocol)


@router.post("/protocols/{protocol_id}/versions/{version_id}/withdraw")
def withdraw_version(protocol_id: str, version_id: str, payload: WithdrawVersionIn, db: Session = Depends(get_db), user: models.User = Depends(_configure)) -> dict:
    v = es.get_version(db, version_id, user.farm_id)
    if v.emergency_protocol_id != protocol_id:
        raise es.EmergencyError("Version does not belong to this protocol", 404)
    es.withdraw_version(db, v, reason=payload.reason, user_id=user.id)
    db.commit()
    return es.protocol_dict(db, v.protocol)


# ------------------------------------------------------------ assessments
@router.get("/assessments")
def list_assessments(assessment_status: str | None = Query(None, alias="status"), subject_id: str | None = None, limit: int = Query(100, ge=1, le=500),
                     db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    stmt = select(em.EmergencyAssessment).where(em.EmergencyAssessment.farm_id == user.farm_id)
    if assessment_status == "active":
        stmt = stmt.where(em.EmergencyAssessment.status.in_(("open", "protocol_started", "escalated")))
    elif assessment_status:
        stmt = stmt.where(em.EmergencyAssessment.status == assessment_status)
    if subject_id:
        stmt = stmt.where((em.EmergencyAssessment.animal_id == subject_id) | (em.EmergencyAssessment.animal_group_id == subject_id))
    return [es.assessment_dict(db, a) for a in db.scalars(stmt.order_by(em.EmergencyAssessment.started_at.desc()).limit(limit))]


@router.post("/assessments", status_code=status.HTTP_201_CREATED)
def create_assessment(payload: AssessmentIn, db: Session = Depends(get_db), user: models.User = Depends(_act)) -> dict:
    """Triage from the worker's signs (§12): matches current approved
    protocols, checks the animal's facts, ranks urgency, selects or
    escalates — and explains itself."""
    a = es.assess(db, user.farm_id, subject_type=payload.subject_type, subject_id=payload.subject_id, signs=[s.model_dump() for s in payload.signs],
                  source=payload.source, notes=payload.notes, user_id=user.id)
    db.commit()
    return es.assessment_dict(db, a)


@router.get("/assessments/{assessment_id}")
def get_assessment(assessment_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return es.assessment_dict(db, es.get_assessment(db, assessment_id, user.farm_id))


@router.post("/assessments/{assessment_id}/start", status_code=status.HTTP_201_CREATED)
def start_run(assessment_id: str, payload: StartRunIn | None = None, db: Session = Depends(get_db), user: models.User = Depends(_act)) -> dict:
    """Starts the matched approved protocol after the person confirms;
    notifies the manager / veterinarian as the version requires."""
    a = es.get_assessment(db, assessment_id, user.farm_id)
    run = _keep_escalation(db, lambda: es.start_run(db, a, match_id=payload.match_id if payload else None, confirmed=payload.confirmed if payload else True, user_id=user.id))
    db.commit()
    return es.run_dict(db, run)


@router.post("/assessments/{assessment_id}/close")
def close_assessment(assessment_id: str, payload: ResolveRunIn, db: Session = Depends(get_db), user: models.User = Depends(_act)) -> dict:
    a = es.close_assessment(db, es.get_assessment(db, assessment_id, user.farm_id), outcome=payload.outcome, user_id=user.id)
    db.commit()
    return es.assessment_dict(db, a)


# ------------------------------------------------------------------- runs
@router.get("/runs")
def list_runs(run_status: str | None = Query(None, alias="status"), subject_id: str | None = None, limit: int = Query(100, ge=1, le=500),
              db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    stmt = select(em.EmergencyProtocolRun).where(em.EmergencyProtocolRun.farm_id == user.farm_id)
    if run_status == "active":
        stmt = stmt.where(em.EmergencyProtocolRun.status.in_(("in_progress", "awaiting_reassessment")))
    elif run_status:
        stmt = stmt.where(em.EmergencyProtocolRun.status == run_status)
    if subject_id:
        stmt = stmt.where((em.EmergencyProtocolRun.animal_id == subject_id) | (em.EmergencyProtocolRun.animal_group_id == subject_id))
    return [es.run_dict(db, r) for r in db.scalars(stmt.order_by(em.EmergencyProtocolRun.started_at.desc()).limit(limit))]


@router.get("/runs/{run_id}")
def get_run(run_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return es.run_dict(db, es.get_run(db, run_id, user.farm_id))


@router.post("/runs/{run_id}/steps/{step_id}/prepare")
def prepare_step(run_id: str, step_id: str, payload: PrepareStepIn | None = None, db: Session = Depends(get_db), user: models.User = Depends(_act)) -> dict:
    """Presents the step. A medication step shows the approved dose from
    the approved rule and the exact eligible lot, or blocks and escalates."""
    run = es.get_run(db, run_id, user.farm_id)
    es.prepare_step(db, run, step_id, weight_kg=payload.weight_kg if payload else None, head_count=payload.head_count if payload else None, user_id=user.id)
    db.commit()
    return es.run_dict(db, run)


@router.post("/runs/{run_id}/steps/{step_id}/confirm")
def confirm_step(run_id: str, step_id: str, payload: ConfirmStepIn | None = None, db: Session = Depends(get_db), user: models.User = Depends(_act)) -> dict:
    """The person confirms the actual action; a medication step consumes
    the exact lot through the pharmacy and records the prescription's
    provenance."""
    run = es.get_run(db, run_id, user.farm_id)
    p = payload or ConfirmStepIn()
    _keep_escalation(db, lambda: es.confirm_step(db, run, step_id, weight_kg=p.weight_kg, head_count=p.head_count, lot_id=p.lot_id, result=p.result, notes=p.notes, user_id=user.id))
    db.commit()
    return es.run_dict(db, run)


@router.post("/runs/{run_id}/steps/{step_id}/skip")
def skip_step(run_id: str, step_id: str, payload: SkipStepIn, db: Session = Depends(get_db), user: models.User = Depends(_act)) -> dict:
    run = es.get_run(db, run_id, user.farm_id)
    es.skip_step(db, run, step_id, reason=payload.reason, user_id=user.id)
    db.commit()
    return es.run_dict(db, run)


@router.post("/runs/{run_id}/reassess", status_code=status.HTTP_201_CREATED)
def reassess(run_id: str, payload: ReassessIn, db: Session = Depends(get_db), user: models.User = Depends(_act)) -> dict:
    run = es.get_run(db, run_id, user.farm_id)
    follow, run = es.reassess_run(db, run, signs=[s.model_dump() for s in payload.signs], notes=payload.notes, user_id=user.id)
    db.commit()
    return {"assessment": es.assessment_dict(db, follow), "run": es.run_dict(db, run)}


@router.post("/runs/{run_id}/escalate")
def escalate(run_id: str, payload: EscalateIn, db: Session = Depends(get_db), user: models.User = Depends(_act)) -> dict:
    run = es.escalate_run(db, es.get_run(db, run_id, user.farm_id), reason=payload.reason, user_id=user.id)
    db.commit()
    return es.run_dict(db, run)


@router.post("/runs/{run_id}/resolve")
def resolve(run_id: str, payload: ResolveRunIn, db: Session = Depends(get_db), user: models.User = Depends(_act)) -> dict:
    run = es.resolve_run(db, es.get_run(db, run_id, user.farm_id), outcome=payload.outcome, user_id=user.id)
    db.commit()
    return es.run_dict(db, run)
