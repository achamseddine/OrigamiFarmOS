"""Today's Priorities and the Audit History (tech spec §5/§23).

Priorities are the farm's whole actionable work list — alerts *and* open
tasks — scoped to what the signed-in user is responsible for. The tablet
shows the top few on the Morning Briefing and the full filtered list
behind "Expand".
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, load_permission_map, require_permission
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.schemas.notifications import AuditEventOut, PrioritiesPage
from app.services import signals_service

router = APIRouter(tags=["priorities"])

_PRIORITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}


@router.get("/priorities", response_model=PrioritiesPage)
def list_priorities(
    module: str | None = None,
    priority: str | None = Query(default=None, description="critical | high | medium | low | info"),
    kind: str | None = Query(default=None, description="alert | task"),
    assignment: str | None = Query(default=None, description="me | team | unassigned"),
    limit: int = Query(default=100, ge=1, le=500),
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    permission_map = load_permission_map(db, current_user)

    signals = signals_service.collect_signals(db, current_user.farm_id)
    signals += signals_service.open_task_signals(db, current_user.farm_id)
    signals = signals_service.visible_to(signals, permission_map)
    signals.sort(key=lambda s: s.sort_key())

    # Counts describe everything the user can see, so the filter chips can
    # show "High (4)" while the list below shows only one module.
    counts_by_priority: dict[str, int] = {}
    counts_by_module: dict[str, int] = {}
    for signal in signals:
        counts_by_priority[signal.priority] = counts_by_priority.get(signal.priority, 0) + 1
        counts_by_module[signal.module_code] = counts_by_module.get(signal.module_code, 0) + 1

    if module:
        signals = [s for s in signals if s.module_code == module]
    if priority:
        signals = [s for s in signals if s.priority == priority]
    if kind:
        signals = [s for s in signals if s.kind == kind]
    if assignment == "me":
        signals = [s for s in signals if s.assigned_to == current_user.id]
    elif assignment == "unassigned":
        signals = [s for s in signals if s.assigned_to is None]
    elif assignment == "team":
        signals = [s for s in signals if s.assigned_to is not None and s.assigned_to != current_user.id]

    names = {
        u.id: u.name
        for u in db.scalars(select(models.User).where(models.User.farm_id == current_user.farm_id))
    }

    return {
        "total": len(signals),
        "counts_by_priority": counts_by_priority,
        "counts_by_module": counts_by_module,
        "priorities": [
            {
                "id": f"{s.source_type}:{s.source_id}",
                "kind": s.kind,
                "module_code": s.module_code,
                "notification_type": s.notification_type,
                "title": s.title,
                "description": s.description,
                "priority": s.priority,
                "status": s.status,
                "entity_type": s.entity_type,
                "entity_id": s.entity_id,
                "source_type": s.source_type,
                "source_id": s.source_id,
                "due_at": s.due_at,
                "assigned_to": s.assigned_to,
                "assigned_to_name": names.get(s.assigned_to) if s.assigned_to else None,
                "metadata": s.metadata,
            }
            for s in signals[:limit]
        ],
    }


@router.get("/audit", response_model=list[AuditEventOut])
def list_audit_events(
    entity_type: str | None = None,
    entity_id: str | None = None,
    module: str | None = None,
    user_id: str | None = None,
    limit: int = Query(default=100, ge=1, le=500),
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.REPORTS, perms.VIEW)),
) -> list[dict]:
    """Audit History (tech spec §23). Gated on Reports/view — seeing who
    changed what across the farm is a supervisory capability, not something
    every employee holds by default.
    """
    stmt = select(models.AuditLog).where(models.AuditLog.farm_id == current_user.farm_id)
    if entity_type:
        stmt = stmt.where(models.AuditLog.entity_type == entity_type)
    if entity_id:
        stmt = stmt.where(models.AuditLog.entity_id == entity_id)
    if module:
        stmt = stmt.where(models.AuditLog.module_code == module)
    if user_id:
        stmt = stmt.where(models.AuditLog.user_id == user_id)

    rows = list(db.scalars(stmt.order_by(models.AuditLog.timestamp.desc()).limit(limit)))
    names = {
        u.id: u.name
        for u in db.scalars(select(models.User).where(models.User.farm_id == current_user.farm_id))
    }
    out = []
    for row in rows:
        item = AuditEventOut.model_validate(row).model_dump()
        item["user_name"] = names.get(row.user_id)
        out.append(item)
    return out
