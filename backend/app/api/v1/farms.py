from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.base import get_db
from app.domain import models
from app.schemas.auth import BootstrapResponse

router = APIRouter(prefix="/farms", tags=["farms"])


def _serialize(obj) -> dict:
    out = {}
    for column in obj.__table__.columns:
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


@router.get("/{farm_id}/bootstrap", response_model=BootstrapResponse)
def bootstrap(farm_id: str, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)) -> BootstrapResponse:
    """GET /farms/{farm_id}/bootstrap — initial local cache data (tech spec
    §12). The tablet writes this straight into SQLite on first login /
    when activating demo mode, per the offline-first flow in §10.
    """
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
