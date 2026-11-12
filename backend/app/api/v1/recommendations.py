from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import owned_or_404, require_any_permission, require_farm_access
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.repositories.base import now, write_event
from app.schemas.recommendations import RecommendationDecision, RecommendationOut
from app.services.recommendation_service import regenerate_recommendations

router = APIRouter(prefix="/recommendations", tags=["recommendations"])

_AI_VIEW = require_farm_access(perms.AI_INTELLIGENCE)
# CONSTITUTION: "Farm managers decide." Approve is a manager's by default
# and an employee's only when a manager grants it.
_AI_DECIDE = require_any_permission(perms.AI_INTELLIGENCE, action=perms.APPROVE)


@router.get("", response_model=list[RecommendationOut])
def list_recommendations(
    category: str | None = None,
    status_filter: str | None = None,
    refresh: bool = True,
    db: Session = Depends(get_db),
    user: models.User = Depends(_AI_VIEW),
) -> list[models.Recommendation]:
    """GET /recommendations. By default re-evaluates every rule against
    current farm state first (`refresh=true`) so the list is always
    evidence-fresh, then returns what's stored — never generated without
    persisted evidence (CONSTITUTION.md).
    """
    if refresh:
        regenerate_recommendations(db, user.farm_id)
        db.commit()

    stmt = select(models.Recommendation).where(models.Recommendation.farm_id == user.farm_id)
    if category:
        stmt = stmt.where(models.Recommendation.category == category)
    if status_filter:
        stmt = stmt.where(models.Recommendation.status == status_filter)
    return list(db.scalars(stmt.order_by(models.Recommendation.generated_at.desc())))


@router.patch("/{recommendation_id}/decision", response_model=RecommendationOut)
def decide_recommendation(
    recommendation_id: str,
    payload: RecommendationDecision,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(_AI_DECIDE),
) -> models.Recommendation:
    """PATCH /recommendations/{id}/decision — accept/reject/postpone.
    Tech spec §15 lifecycle: "Generated -> Reviewed -> Accepted/Rejected/
    Postponed -> Task Created -> Action Taken -> Outcome Recorded ->
    Closed." Every decision is itself an event, so the trail is never lost.
    """
    rec = owned_or_404(db, models.Recommendation, recommendation_id, current_user, "Recommendation")
    if payload.decision not in {"accepted", "rejected", "postponed"}:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "decision must be accepted, rejected or postponed")
    # Every decision is logged against the person who made it (knowledge
    # lifecycle §7), so the record names the caller, not a body field.
    if payload.decided_by != current_user.id:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "A decision is recorded in the name of the person who makes it.")

    rec.status = payload.decision
    rec.decided_by = payload.decided_by
    rec.decided_at = now()
    write_event(
        db,
        farm_id=rec.farm_id,
        entity_type="recommendation",
        entity_id=rec.id,
        event_type="recommendation_decided",
        payload={"decision": payload.decision, "note": payload.note},
        created_by=current_user.id,
    )
    db.commit()
    db.refresh(rec)
    return rec
