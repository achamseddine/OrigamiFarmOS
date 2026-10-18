"""Platform masters: units of measure, farm assets, notification routes
and the scheduled analytical cycles.

Units and routes are configuration (Settings configure); assets are
operational records (inventory or feed create / edit); the scheduler's
status is readable by anyone who holds Settings, and running it on demand
is a manager's action.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_manager_role, require_permission, user_can
from app.core import permissions as perms
from app.core import scheduler
from app.db.base import get_db
from app.domain import models
from app.domain import platform_models as plm
from app.schemas.platform import AssetIn, AssetPatch, RoutesSet, SchedulerRunIn, UnitIn
from app.services import asset_service as assets
from app.services import routing_service as routing
from app.services import uom_service

router = APIRouter(tags=["platform"])


def _either(*checks: tuple[str, str]):
    def _dep(db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> models.User:
        for module, action in checks:
            if user_can(db, user, module, action):
                return user
        raise HTTPException(status.HTTP_403_FORBIDDEN, "You do not have permission for this. Ask a farm manager to grant inventory or feed access.")

    return _dep


_configure = require_permission(perms.SETTINGS, perms.CONFIGURE)
_settings_view = require_permission(perms.SETTINGS, perms.VIEW)
_asset_write = _either((perms.INVENTORY, perms.CREATE), (perms.INVENTORY, perms.EDIT), (perms.FEED_NUTRITION, perms.CREATE))


# ---------------------------------------------------------------- units
@router.get("/units-of-measure")
def list_units(include_inactive: bool = False, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)) -> list[dict]:
    """The unit table every unit column references: built-in plus the
    farm's own."""
    rows = [uom_service.unit_dict(u) for u in uom_service.list_units(db, include_inactive=include_inactive)]
    db.commit()
    return rows


@router.post("/units-of-measure", status_code=status.HTTP_201_CREATED)
def create_unit(payload: UnitIn, db: Session = Depends(get_db), user: models.User = Depends(_configure)) -> dict:
    row = uom_service.create_unit(db, farm_id=user.farm_id, user_id=user.id, **payload.model_dump())
    db.commit()
    return uom_service.unit_dict(row)


# --------------------------------------------------------------- assets
@router.get("/assets")
def list_assets(asset_type: str | None = None, include_retired: bool = False, db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> list[dict]:
    stmt = select(plm.FarmAsset).where(plm.FarmAsset.farm_id == user.farm_id)
    if asset_type:
        stmt = stmt.where(plm.FarmAsset.asset_type == asset_type)
    if not include_retired:
        stmt = stmt.where(plm.FarmAsset.status != "retired")
    return [assets.asset_dict(db, a) for a in db.scalars(stmt.order_by(plm.FarmAsset.name))]


@router.post("/assets", status_code=status.HTTP_201_CREATED)
def create_asset(payload: AssetIn, db: Session = Depends(get_db), user: models.User = Depends(_asset_write)) -> dict:
    """A durable resource (ASSET-MAINTENANCE §2): the mixer a numbered mix
    names, a cooling tank, a milking machine."""
    row = assets.create_asset(db, user.farm_id, user_id=user.id, **payload.model_dump())
    db.commit()
    return assets.asset_dict(db, row)


@router.get("/assets/{asset_id}")
def get_asset(asset_id: str, db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> dict:
    return assets.asset_dict(db, assets.get_asset(db, asset_id, user.farm_id))


@router.patch("/assets/{asset_id}")
def update_asset(asset_id: str, payload: AssetPatch, db: Session = Depends(get_db), user: models.User = Depends(_asset_write)) -> dict:
    row = assets.update_asset(db, assets.get_asset(db, asset_id, user.farm_id), payload.model_dump(exclude_unset=True), user_id=user.id)
    db.commit()
    return assets.asset_dict(db, row)


# --------------------------------------------------------- notification routes
@router.get("/notification-routes")
def list_routes(db: Session = Depends(get_db), user: models.User = Depends(_settings_view)) -> list[dict]:
    """Who each route reaches: the farm's configuration and the built-in
    default it falls back to, with the effective recipients resolved."""
    return routing.routes_overview(db, user.farm_id)


@router.put("/notification-routes/{route_code}")
def set_routes(route_code: str, payload: RoutesSet, db: Session = Depends(get_db), user: models.User = Depends(_configure)) -> dict:
    routing.set_routes(db, user.farm_id, route_code, [e.model_dump() for e in payload.entries], user_id=user.id)
    db.commit()
    return next(r for r in routing.routes_overview(db, user.farm_id) if r["route_code"] == route_code)


# ------------------------------------------------------------- scheduler
@router.get("/scheduler/jobs")
def scheduler_jobs(db: Session = Depends(get_db), user: models.User = Depends(_settings_view)) -> list[dict]:
    """The scheduled cycles (feed performance, pharmacy scan, reassessment
    check): cadence, last run, last result, next due."""
    return scheduler.status(db, user.farm_id)


@router.get("/scheduler/runs")
def scheduler_runs(job_code: str | None = None, limit: int = Query(50, ge=1, le=500), db: Session = Depends(get_db), user: models.User = Depends(_settings_view)) -> list[dict]:
    stmt = select(plm.ScheduledJobRun).where(plm.ScheduledJobRun.farm_id == user.farm_id)
    if job_code:
        stmt = stmt.where(plm.ScheduledJobRun.job_code == job_code)
    return [{"id": r.id, "job_code": r.job_code, "trigger": r.trigger, "started_at": r.started_at, "finished_at": r.finished_at, "status": r.status,
             "summary": r.summary_json, "error": r.error} for r in db.scalars(stmt.order_by(plm.ScheduledJobRun.started_at.desc()).limit(limit))]


@router.post("/scheduler/run")
def scheduler_run(payload: SchedulerRunIn | None = None, db: Session = Depends(get_db), user: models.User = Depends(require_manager_role)) -> dict:
    """Runs the cycles now (all, or the ones named). `force=false` runs
    only what is due."""
    p = payload or SchedulerRunIn()
    unknown = [c for c in (p.job_codes or []) if c not in scheduler.JOBS]
    if unknown:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"Unknown job(s): {', '.join(unknown)}. Known: {', '.join(scheduler.JOBS)}.")
    runs = scheduler.run_due(db, farm_id=user.farm_id, job_codes=p.job_codes, force=p.force, trigger="manual")
    return {"ran": len(runs), "runs": [{"id": r.id, "job_code": r.job_code, "status": r.status, "summary": r.summary_json, "error": r.error} for r in runs],
            "jobs": scheduler.status(db, user.farm_id)}
