from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.base import get_db
from app.domain import models
from app.repositories.base import now, write_event
from app.schemas.recommendations import RecommendationDecision, RecommendationOut
from app.services.recommendation_service import regenerate_recommendations

router = APIRouter(prefix="/recommendations", tags=["recommendations"])


@router.get("", response_model=list[RecommendationOut])
def list_recommendations(
    farm_id: str,
    category: str | None = None,
    status_filter: str | None = None,
    refresh: bool = True,
    db: Session = Depends(get_db),
    _user: models.User = Depends(get_current_user),
) -> list[models.Recommendation]:
    """GET /recommendations. By default re-evaluates every rule against
    current farm state first (`refresh=true`) so the list is always
    evidence-fresh, then returns what's stored — never generated without
    persisted evidence (CONSTITUTION.md).
    """
    if refresh:
        regenerate_recommendations(db, farm_id)
        db.commit()

    stmt = select(models.Recommendation).where(models.Recommendation.farm_id == farm_id)
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
    current_user: models.User = Depends(get_current_user),
) -> models.Recommendation:
    """PATCH /recommendations/{id}/decision — accept/reject/postpone.
    Tech spec §15 lifecycle: "Generated -> Reviewed -> Accepted/Rejected/
    Postponed -> Task Created -> Action Taken -> Outcome Recorded ->
    Closed." Every decision is itself an event, so the trail is never lost.
    """
    rec = db.get(models.Recommendation, recommendation_id)
    if rec is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Recommendation not found")
    if payload.decision not in {"accepted", "rejected", "postponed"}:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "decision must be accepted, rejected or postponed")

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
