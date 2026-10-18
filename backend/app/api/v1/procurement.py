"""Purchase requisitions (database/PROCUREMENT-SCHEMA.md §5–§6).

Anyone with inventory view reads; inventory create opens and submits a
draft; approval and rejection need a manager, the owner, or inventory
approve — the service snapshots the authority on the decision. Nothing
here orders or receives stock.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_permission
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.domain import procurement_models as prm
from app.schemas.procurement import RequisitionCancel, RequisitionDecision, RequisitionIn
from app.services import procurement_service as procurement

router = APIRouter(prefix="/procurement", tags=["procurement"])

_view = require_permission(perms.INVENTORY, perms.VIEW)
_create = require_permission(perms.INVENTORY, perms.CREATE)
_edit = require_permission(perms.INVENTORY, perms.EDIT)


@router.get("/requisitions")
def list_requisitions(req_status: str | None = Query(None, alias="status"), inventory_item_id: str | None = None, limit: int = Query(100, ge=1, le=500),
                      db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    stmt = select(prm.PurchaseRequisition).where(prm.PurchaseRequisition.farm_id == user.farm_id)
    if req_status == "open":
        stmt = stmt.where(prm.PurchaseRequisition.status.in_(("draft", "submitted", "approved", "ordered")))
    elif req_status:
        stmt = stmt.where(prm.PurchaseRequisition.status == req_status)
    rows = list(db.scalars(stmt.order_by(prm.PurchaseRequisition.requested_at.desc()).limit(limit)))
    if inventory_item_id:
        rows = [r for r in rows if any(l.inventory_item_id == inventory_item_id for l in r.lines)]
    return [procurement.requisition_dict(db, r) for r in rows]


@router.post("/requisitions", status_code=status.HTTP_201_CREATED)
def create_requisition(payload: RequisitionIn, db: Session = Depends(get_db), user: models.User = Depends(_create)) -> dict:
    """A manual DRAFT requisition. Submitting and approving are separate
    steps; an approved requisition is not a purchase."""
    req = procurement.create_requisition(db, user.farm_id, lines=[l.model_dump() for l in payload.lines], requested_by=user.id, purpose_code=payload.purpose_code or "manual",
                                         needed_by=payload.needed_by, justification=payload.justification, source_type="manual", currency=payload.currency, user_id=user.id)
    db.commit()
    return procurement.requisition_dict(db, req)


@router.get("/requisitions/{requisition_id}")
def get_requisition(requisition_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return procurement.requisition_dict(db, procurement.get_requisition(db, requisition_id, user.farm_id))


@router.post("/requisitions/{requisition_id}/submit")
def submit_requisition(requisition_id: str, db: Session = Depends(get_db), user: models.User = Depends(_create)) -> dict:
    req = procurement.submit(db, procurement.get_requisition(db, requisition_id, user.farm_id), user_id=user.id)
    db.commit()
    return procurement.requisition_dict(db, req)


@router.post("/requisitions/{requisition_id}/approve")
def approve_requisition(requisition_id: str, payload: RequisitionDecision | None = None, db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> dict:
    """Approval with the deciding authority snapshotted (§6). Refused for
    anyone without it."""
    req = procurement.decide(db, procurement.get_requisition(db, requisition_id, user.farm_id), decision="approved", user=user, comments=payload.comments if payload else None)
    db.commit()
    return procurement.requisition_dict(db, req)


@router.post("/requisitions/{requisition_id}/reject")
def reject_requisition(requisition_id: str, payload: RequisitionDecision, db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> dict:
    req = procurement.decide(db, procurement.get_requisition(db, requisition_id, user.farm_id), decision="rejected", user=user, comments=payload.comments)
    db.commit()
    return procurement.requisition_dict(db, req)


@router.post("/requisitions/{requisition_id}/cancel")
def cancel_requisition(requisition_id: str, payload: RequisitionCancel, db: Session = Depends(get_db), user: models.User = Depends(_edit)) -> dict:
    req = procurement.cancel(db, procurement.get_requisition(db, requisition_id, user.farm_id), reason=payload.reason, user_id=user.id)
    db.commit()
    return procurement.requisition_dict(db, req)
