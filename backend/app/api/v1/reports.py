from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.deps import require_farm_access
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.services.recommendation_service import regenerate_recommendations
from app.services.reports_service import build_daily_summary, build_morning_briefing

router = APIRouter(tags=["reports"])

_MORNING_VIEW = require_farm_access(perms.MORNING_OPERATIONS)
# The daily summary is sales and expense totals: the tablet's Sales &
# Finance screen loads it for whoever holds Finance.
_SUMMARY_VIEW = require_farm_access(perms.REPORTS, perms.FINANCE)


@router.get("/morning-briefing")
def morning_briefing(db: Session = Depends(get_db), current_user: models.User = Depends(_MORNING_VIEW)) -> dict:
    """Tech spec §16: "Morning Briefing ... Local cache refresh on app open
    and after sync." Refreshing recommendations here (not just from
    GET /recommendations) means the briefing's priorities are current even
    if nothing else has called the recommendations endpoint yet today.
    """
    regenerate_recommendations(db, current_user.farm_id)
    db.commit()
    return build_morning_briefing(db, current_user.farm_id, viewer_name=current_user.name)


@router.get("/reports/daily-summary")
def daily_summary(db: Session = Depends(get_db), user: models.User = Depends(_SUMMARY_VIEW)) -> dict:
    return build_daily_summary(db, user.farm_id)
