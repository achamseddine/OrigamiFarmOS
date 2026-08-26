from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.base import get_db
from app.domain import models
from app.services.recommendation_service import regenerate_recommendations
from app.services.reports_service import build_daily_summary, build_morning_briefing

router = APIRouter(tags=["reports"])


@router.get("/morning-briefing")
def morning_briefing(farm_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> dict:
    """Tech spec §16: "Morning Briefing ... Local cache refresh on app open
    and after sync." Refreshing recommendations here (not just from
    GET /recommendations) means the briefing's priorities are current even
    if nothing else has called the recommendations endpoint yet today.
    """
    regenerate_recommendations(db, farm_id)
    db.commit()
    return build_morning_briefing(db, farm_id, viewer_name=current_user.name)


@router.get("/reports/daily-summary")
def daily_summary(farm_id: str, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)) -> dict:
    return build_daily_summary(db, farm_id)
