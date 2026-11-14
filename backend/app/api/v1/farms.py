from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_farm_access, require_permission
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.repositories.base import write_audit_log, write_event
from app.schemas.auth import BootstrapResponse

router = APIRouter(prefix="/farms", tags=["farms"])


# Columns that never leave the server, whatever endpoint serialises the row.
_NEVER_SERIALISED = frozenset({"password_hash"})


def _serialize(obj) -> dict:
    out = {}
    for column in obj.__table__.columns:
        if column.name in _NEVER_SERIALISED:
            continue
        value = getattr(obj, column.name)
        if isinstance(value, datetime):
            value = value.isoformat()
        out[column.name] = value
    return out


@router.get("/me")
def my_farm(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> dict:
    """The signed-in user's own farm — just the farm record, for the
    Settings screen. `/farms/{farm_id}/bootstrap` below returns this plus
    the whole offline-cache payload, which is far more than a settings
    display needs.
    """
    farm = db.get(models.Farm, current_user.farm_id)
    if farm is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Farm not found")
    return _serialize(farm)


class FarmSettingsUpdate(BaseModel):
    """The farm-level settings a manager changes from the tablet. Only the
    fields sent are changed."""

    # Days before an expected birth that a lactating animal is dried off.
    dry_off_days_before_birth: int | None = Field(None, ge=0, le=200)
    # The calendar after a birth: milk peak window, voluntary waiting
    # period before the next insemination, heat cycle length.
    milk_peak_start_days: int | None = Field(None, ge=0, le=365)
    milk_peak_end_days: int | None = Field(None, ge=0, le=365)
    breeding_wait_days: int | None = Field(None, ge=0, le=365)
    heat_cycle_days: int | None = Field(None, ge=10, le=60)


@router.patch("/me")
def update_my_farm(
    payload: FarmSettingsUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.SETTINGS, perms.CONFIGURE)),
) -> dict:
    """Changes the signed-in user's farm settings. Settings are not history-
    bearing facts, so the row is updated in place — and every change is an
    audit entry and a `farm_settings_changed` event with the old value.

    The calendar every plan is drawn from (dry-off, milk peak, breeding wait)
    is configuration, not day-to-day work: it needs Settings *configure*,
    which the owner and manager hold and an employee only when granted."""
    farm = db.get(models.Farm, current_user.farm_id)
    if farm is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Farm not found")
    changes = {k: v for k, v in payload.model_dump(exclude_unset=True).items() if v is not None and getattr(farm, k) != v}
    start = changes.get("milk_peak_start_days", farm.milk_peak_start_days)
    end = changes.get("milk_peak_end_days", farm.milk_peak_end_days)
    if start is not None and end is not None and start > end:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "The milk peak window must start before it ends.")
    if changes:
        before = {k: getattr(farm, k) for k in changes}
        for k, v in changes.items():
            setattr(farm, k, v)
        write_event(db, farm_id=farm.id, entity_type="farm", entity_id=farm.id, event_type="farm_settings_changed",
                    payload={"before": before, "after": changes}, created_by=current_user.id)
        write_audit_log(
            db, farm_id=farm.id, user_id=current_user.id, action="farm_settings_changed", entity_type="farm", entity_id=farm.id,
            module_code=perms.SETTINGS, changes={k: {"from": before[k], "to": v} for k, v in changes.items()},
            summary=f"{current_user.name} changed " + ", ".join(f"{k.replace('_', ' ')} {before[k]} → {v}" for k, v in changes.items()),
        )
        db.commit()
    return _serialize(farm)


@router.get("/{farm_id}/bootstrap", response_model=BootstrapResponse)
def bootstrap(db: Session = Depends(get_db), user: models.User = Depends(require_farm_access())) -> BootstrapResponse:
    """GET /farms/{farm_id}/bootstrap — initial local cache data (tech spec
    §12). The tablet writes this straight into SQLite on first login /
    when activating demo mode, per the offline-first flow in §10.

    Only the caller's own farm, and never a password hash.
    """
    farm_id = user.farm_id
    farm = db.get(models.Farm, farm_id)
    if farm is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Farm not found")

    def all_of(model):
        return db.scalars(select(model).where(model.farm_id == farm_id)).all()

    return BootstrapResponse(
        farm=_serialize(farm),
        users=[_serialize(u) for u in all_of(models.User)],
        locations=[_serialize(l) for l in all_of(models.Location)],
        animals=[_serialize(a) for a in all_of(models.Animal)],
        flocks=[_serialize(f) for f in all_of(models.Flock)],
        fields=[_serialize(f) for f in all_of(models.Field)],
        inventory_items=[_serialize(i) for i in all_of(models.InventoryItem)],
        tasks=[_serialize(t) for t in all_of(models.Task)],
        recommendations=[_serialize(r) for r in all_of(models.Recommendation)],
        server_time=datetime.now(timezone.utc).isoformat(),
        sync_cursor=datetime.now(timezone.utc).isoformat(),
    )
