"""Employee work waiting for the farm manager (approval_service.py).

Anyone who may create in the request's module sends one; the list shows a
manager everything waiting on the modules they approve, and an employee
their own requests with how each was decided. Approving needs *approve*
on the module and runs the change as the manager.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, user_can
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import approval_models as am
from app.domain import models
from app.schemas.approvals import ApprovalDecisionIn, ApprovalRequestIn
from app.services import approval_service as approvals

router = APIRouter(prefix="/approval-requests", tags=["approvals"])


@router.get("")
def list_requests(req_status: str | None = Query(None, alias="status"), mine: bool = False, limit: int = Query(100, ge=1, le=500),
                  db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> list[dict]:
    """[status] pending | approved | rejected | cancelled (all when unset).
    A manager sees the requests of every module they approve (and their
    own); anyone else sees only their own. [mine] limits to one's own."""
    stmt = select(am.ApprovalRequest).where(am.ApprovalRequest.farm_id == user.farm_id)
    if req_status:
        stmt = stmt.where(am.ApprovalRequest.status == req_status)
    decides = [m for m in sorted(set(approvals.KIND_MODULE.values())) if user_can(db, user, m, perms.APPROVE)]
    if mine or not decides:
        stmt = stmt.where(am.ApprovalRequest.requested_by == user.id)
    else:
        stmt = stmt.where(or_(am.ApprovalRequest.module_code.in_(decides), am.ApprovalRequest.requested_by == user.id))
    rows = db.scalars(stmt.order_by(am.ApprovalRequest.requested_at.desc()).limit(limit))
    return [approvals.to_dict(db, r) for r in rows]


@router.post("", status_code=status.HTTP_201_CREATED)
def create_request(payload: ApprovalRequestIn, db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> dict:
    req = approvals.create(db, user, kind=payload.kind, payload=payload.payload, reason=payload.reason, target_id=payload.target_id)
    db.commit()
    return approvals.to_dict(db, req)


@router.get("/{request_id}")
def get_request(request_id: str, db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> dict:
    req = approvals.get(db, request_id, user.farm_id)
    if req.requested_by != user.id and not approvals.can_decide(db, user, req):
        raise approvals.ApprovalError("Request not found", 404)
    return approvals.to_dict(db, req)


@router.post("/{request_id}/approve")
def approve_request(request_id: str, payload: ApprovalDecisionIn | None = None, db: Session = Depends(get_db),
                    user: models.User = Depends(get_current_user)) -> dict:
    body = payload or ApprovalDecisionIn()
    req = approvals.approve(db, approvals.get(db, request_id, user.farm_id), user, note=body.note, allow_negative=body.allow_negative,
                            confirm_duplicate=body.confirm_duplicate)
    db.commit()
    return approvals.to_dict(db, req)


@router.post("/{request_id}/reject")
def reject_request(request_id: str, payload: ApprovalDecisionIn, db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> dict:
    req = approvals.reject(db, approvals.get(db, request_id, user.farm_id), user, note=payload.note)
    db.commit()
    return approvals.to_dict(db, req)


@router.post("/{request_id}/cancel")
def cancel_request(request_id: str, db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> dict:
    req = approvals.cancel(db, approvals.get(db, request_id, user.farm_id), user)
    db.commit()
    return approvals.to_dict(db, req)
