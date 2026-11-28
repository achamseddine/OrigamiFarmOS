from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_farm_access, user_can
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.services.recommendation_service import regenerate_recommendations
from app.services import animal_profitability_service as animal_profitability
from app.services import farm_reports_service as farm_reports
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


# Who reads each report: Reports holders read them all; otherwise the
# report's own area. Money (milk sales in the milk report, the finance
# report) is shown only to someone who may see sales or finance.
_REPORT_MODULES = {
    "milk": (perms.MILK_PRODUCTION,),
    "feed": (perms.FEED_NUTRITION, perms.INVENTORY),
    "herd": (perms.ANIMALS, perms.ANIMAL_HEALTH),
    "finance": (perms.FINANCE, perms.SALES),
    "sales": (perms.SALES, perms.FINANCE),
    "stock": (perms.INVENTORY, perms.FEED_NUTRITION, perms.MOUNEH_INVENTORY, perms.ANIMAL_HEALTH, perms.MILK_PRODUCTION),
}
_MONEY_MODULES = (perms.REPORTS, perms.FINANCE, perms.SALES)
# The stock report shows each part to whoever works in that area.
_STOCK_SECTION_MODULES = {
    "feed": (perms.FEED_NUTRITION, perms.INVENTORY),
    "medicine": (perms.ANIMAL_HEALTH, perms.INVENTORY),
    "mouneh_goods": (perms.MOUNEH_INVENTORY, perms.MOUNEH_PRODUCTION, perms.INVENTORY),
    "mouneh_materials": (perms.MOUNEH_INVENTORY, perms.MOUNEH_PRODUCTION, perms.INVENTORY),
    "milk": (perms.MILK_PRODUCTION,),
    "other": (perms.INVENTORY,),
}


def _farm_report(kind: str, start: date | None, end: date | None, db: Session, user: models.User) -> dict:
    """The farm's report for a period — milk, feed, herd or finance — from
    [start] to [end] (farm days, inclusive; default the last 30 days).
    Read from the canonical records every time."""
    modules = (perms.REPORTS, *_REPORT_MODULES[kind])
    if not any(user_can(db, user, m, perms.VIEW) for m in modules):
        names = " or ".join(perms.MODULES_BY_CODE[m].label_en for m in modules)
        raise HTTPException(status.HTTP_403_FORBIDDEN, f"This report needs {names}. Ask a farm manager to grant it.")
    money = any(user_can(db, user, m, perms.VIEW) for m in _MONEY_MODULES)
    sections = None
    if kind == "stock" and not user_can(db, user, perms.REPORTS, perms.VIEW):
        sections = {section for section, areas in _STOCK_SECTION_MODULES.items() if any(user_can(db, user, m, perms.VIEW) for m in areas)}
    out = farm_reports.build(db, user.farm_id, kind, start, end, with_sales=money, stock_sections=sections)
    db.commit()  # the feed report's cover figures may refresh the forecast snapshot
    return out


# One route per report, not `/reports/{kind}`: a path parameter there would
# also answer the other modules' reports (`/reports/visit-profitability`,
# `/reports/daily-summary`) registered after this router.
@router.get("/reports/milk")
def milk_report(start: date | None = Query(None), end: date | None = Query(None), db: Session = Depends(get_db),
                user: models.User = Depends(get_current_user)) -> dict:
    """Milk for a period: produced, per day and animal, where it went, the tank; with money, the sales."""
    return _farm_report("milk", start, end, db, user)


@router.get("/reports/feed")
def feed_report(start: date | None = Query(None), end: date | None = Query(None), db: Session = Depends(get_db),
                user: models.User = Depends(get_current_user)) -> dict:
    """Feed for a period: feedings, feed used and its cost, deliveries, mixes, stock now."""
    return _farm_report("feed", start, end, db, user)


@router.get("/reports/herd")
def herd_report(start: date | None = Query(None), end: date | None = Query(None), db: Session = Depends(get_db),
                user: models.User = Depends(get_current_user)) -> dict:
    """The herd for a period: on the farm by species, births, animals added and that left, health cases."""
    return _farm_report("herd", start, end, db, user)


@router.get("/reports/finance")
def finance_report(start: date | None = Query(None), end: date | None = Query(None), db: Session = Depends(get_db),
                   user: models.User = Depends(get_current_user)) -> dict:
    """Money for a period: revenue, expenses, margin, cash collected, unpaid; by product, category and day."""
    return _farm_report("finance", start, end, db, user)


@router.get("/reports/sales")
def sales_report(start: date | None = Query(None), end: date | None = Query(None), db: Session = Depends(get_db),
                 user: models.User = Depends(get_current_user)) -> dict:
    """Everything sold in a period: by product, buyer, activity and day; what is still unpaid; every sale."""
    return _farm_report("sales", start, end, db, user)


@router.get("/reports/profitability")
def profitability_report(start: date | None = Query(None), end: date | None = Query(None), animal_id: str | None = Query(None),
                         group_id: str | None = Query(None), db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> dict:
    """Each dairy animal's milk (AM, PM, saleable), its value and attributed
    sales, her feed (own and her share of her group's) and its cost per
    litre, medicine and vet, known labour and electricity, and the margin —
    by animal, for a group, for a period; unknown costs labelled, never
    zero; the totals reconciled with the canonical records (Package 3).
    Money: Reports or Finance."""
    if not any(user_can(db, user, m, perms.VIEW) for m in (perms.REPORTS, perms.FINANCE)):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "This report shows money: it needs Reports or Finance. Ask a farm manager to grant it.")
    return animal_profitability.report(db, user.farm_id, start, end, animal_id=animal_id, group_id=group_id)


@router.get("/reports/stock")
def stock_report(start: date | None = Query(None), end: date | None = Query(None), db: Session = Depends(get_db),
                 user: models.User = Depends(get_current_user)) -> dict:
    """What is in stock now: feed, medicine, Mouneh goods and materials, milk in the tank, other items;
    low and expiring stock; its value at cost (for those who see money)."""
    return _farm_report("stock", start, end, db, user)
