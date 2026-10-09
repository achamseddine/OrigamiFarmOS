"""Feed Performance Intelligence API (database/FEED-PERFORMANCE-INTELLIGENCE.md).

Monitors say what is watched; the cycle evaluates them against explicit
baselines; assessments, mix scores, supplier rows and alerts are what it
produces. Reads need the feed module; running the cycle, editing a
monitor or acknowledging an alert need edit; closing an alert by hand
needs approve, with a reason.
"""
from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import require_permission
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import feed_models as fm
from app.domain import models
from app.repositories.base import ensure_utc
from app.schemas.feeding import FeedPerformanceAlertClose, FeedPerformanceMonitorIn, FeedPerformanceMonitorPatch
from app.services import feed_performance_service as perf
from app.services.feed_inventory_service import FeedError

router = APIRouter(tags=["feed-performance"])

_view = require_permission(perms.FEED_NUTRITION, perms.VIEW)
_edit = require_permission(perms.FEED_NUTRITION, perms.EDIT)
_approve = require_permission(perms.FEED_NUTRITION, perms.APPROVE)


@router.get("/feed-performance/summary")
def performance_summary(db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    """Counts for the Performance tab and the bell: open alerts by type,
    active monitors, when the cycle last ran, and the model it ran."""
    return perf.summary(db, user.farm_id)


@router.post("/feed-performance/evaluate")
def evaluate(as_of: datetime | None = None, monitor_id: str | None = None, db: Session = Depends(get_db), user: models.User = Depends(_edit)) -> dict:
    """Runs the feed-performance cycle now (§12): exposure projection,
    every active monitor against its baseline, mix and supplier scores,
    cost and intake checks. `as_of` evaluates as of an earlier day."""
    out = perf.run_cycle(db, user.farm_id, as_of=ensure_utc(as_of) if as_of else None, monitor_id=monitor_id, user_id=user.id)
    db.commit()
    return out


# --------------------------------------------------------------- monitors
@router.get("/feed-performance/monitors")
def list_monitors(include_inactive: bool = False, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    stmt = select(fm.FeedPerformanceMonitor).where(fm.FeedPerformanceMonitor.farm_id == user.farm_id)
    if not include_inactive:
        stmt = stmt.where(fm.FeedPerformanceMonitor.active.is_(True))
    return [perf.monitor_dict(db, m) for m in db.scalars(stmt.order_by(fm.FeedPerformanceMonitor.created_at))]


@router.post("/feed-performance/monitors", status_code=status.HTTP_201_CREATED)
def create_monitor(payload: FeedPerformanceMonitorIn, db: Session = Depends(get_db), user: models.User = Depends(_edit)) -> dict:
    """Watches one animal or group on one metric against one explicit
    baseline method. The same subject and metric twice returns the
    existing monitor."""
    m = perf.create_monitor(db, user.farm_id, **payload.model_dump(), user_id=user.id)
    db.commit()
    return perf.monitor_dict(db, m)


@router.patch("/feed-performance/monitors/{monitor_id}")
def update_monitor(monitor_id: str, payload: FeedPerformanceMonitorPatch, db: Session = Depends(get_db), user: models.User = Depends(_edit)) -> dict:
    m = perf._get_monitor(db, monitor_id, user.farm_id)
    perf.update_monitor(db, m, payload.model_dump(exclude_unset=True), user_id=user.id)
    db.commit()
    return perf.monitor_dict(db, m)


@router.post("/feed-performance/monitors/{monitor_id}/evaluate")
def evaluate_monitor(monitor_id: str, as_of: datetime | None = None, db: Session = Depends(get_db), user: models.User = Depends(_edit)) -> dict:
    m = perf._get_monitor(db, monitor_id, user.farm_id)
    perf.rebuild_exposures(db, user.farm_id)
    a = perf.evaluate_monitor(db, m, as_of=ensure_utc(as_of) if as_of else None, user_id=user.id)
    db.commit()
    return perf.assessment_dict(db, a)


# ------------------------------------------------------------ assessments
@router.get("/feed-performance/assessments")
def list_assessments(monitor_id: str | None = None, subject_id: str | None = None, limit: int = Query(50, ge=1, le=500),
                     db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    stmt = select(fm.FeedPerformanceAssessment).where(fm.FeedPerformanceAssessment.farm_id == user.farm_id)
    if monitor_id:
        stmt = stmt.where(fm.FeedPerformanceAssessment.monitor_id == monitor_id)
    if subject_id:
        ids = db.scalars(select(fm.FeedPerformanceMonitor.id).where(fm.FeedPerformanceMonitor.farm_id == user.farm_id, fm.FeedPerformanceMonitor.subject_id == subject_id)).all()
        stmt = stmt.where(fm.FeedPerformanceAssessment.monitor_id.in_(ids))
    return [perf.assessment_dict(db, a) for a in db.scalars(stmt.order_by(fm.FeedPerformanceAssessment.evaluated_at.desc()).limit(limit))]


@router.get("/feed-performance/exposures")
def list_exposures(subject_type: str | None = None, subject_id: str | None = None, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    """The exposure projection: which lot and mix each animal or group
    actually received, from when to when, with its supplier lineage."""
    return [perf.exposure_dict(db, w) for w in perf.exposures_for(db, user.farm_id, subject_type, subject_id)]


# ------------------------------------------------------------------ alerts
@router.get("/feed-performance/alerts")
def list_alerts(alert_status: str | None = Query("open", alias="status"), db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    """`status=open` (default) returns open and acknowledged alerts;
    `status=all` includes resolved ones."""
    stmt = select(fm.FeedPerformanceAlert).where(fm.FeedPerformanceAlert.farm_id == user.farm_id)
    if alert_status == "open":
        stmt = stmt.where(fm.FeedPerformanceAlert.status != "resolved")
    elif alert_status and alert_status != "all":
        stmt = stmt.where(fm.FeedPerformanceAlert.status == alert_status)
    return [perf.alert_dict(db, a) for a in db.scalars(stmt.order_by(fm.FeedPerformanceAlert.detected_at.desc()))]


def _alert_or_404(db: Session, alert_id: str, farm_id: str) -> fm.FeedPerformanceAlert:
    a = db.get(fm.FeedPerformanceAlert, alert_id)
    if a is None or a.farm_id != farm_id:
        raise FeedError("Alert not found", 404)
    return a


@router.post("/feed-performance/alerts/{alert_id}/acknowledge")
def acknowledge_alert(alert_id: str, db: Session = Depends(get_db), user: models.User = Depends(_edit)) -> dict:
    a = perf.acknowledge_alert(db, _alert_or_404(db, alert_id, user.farm_id), user_id=user.id)
    db.commit()
    return perf.alert_dict(db, a)


@router.post("/feed-performance/alerts/{alert_id}/resolve")
def resolve_alert(alert_id: str, payload: FeedPerformanceAlertClose, db: Session = Depends(get_db), user: models.User = Depends(_approve)) -> dict:
    """Closes an alert by hand, with a reason — for a condition a person has
    explained (an authorised substitution, a measurement fault)."""
    a = perf.resolve_alert_manually(db, _alert_or_404(db, alert_id, user.farm_id), note=payload.note, user_id=user.id)
    db.commit()
    return perf.alert_dict(db, a)


# -------------------------------------------------------- scores & suppliers
@router.get("/feed-performance/batches")
def list_batch_scores(db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    rows = db.scalars(select(fm.FeedBatchPerformanceScore).where(fm.FeedBatchPerformanceScore.farm_id == user.farm_id)).all()
    out = [perf.batch_score_dict(db, r) for r in rows]
    out.sort(key=lambda d: -(d["mix_number"] or 0))
    return out


@router.get("/feed-performance/batches/{batch_id}")
def batch_score(batch_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    row = db.get(fm.FeedBatchPerformanceScore, batch_id)
    if row is None or row.farm_id != user.farm_id:
        raise FeedError("No performance score for this mix yet — run the cycle.", 404)
    return perf.batch_score_dict(db, row)


@router.get("/feed-performance/suppliers")
def list_supplier_performance(db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    rows = db.scalars(select(fm.SupplierFeedPerformance).where(fm.SupplierFeedPerformance.farm_id == user.farm_id)
                      .order_by(fm.SupplierFeedPerformance.supplier_label, fm.SupplierFeedPerformance.feed_product_id)).all()
    return [perf.supplier_row_dict(db, r) for r in rows]
