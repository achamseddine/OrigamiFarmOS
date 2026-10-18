"""Farm assets (database/ASSET-MAINTENANCE-SCHEMA.md §2): the durable
resources a record can name — a numbered mix names the mixer it was made
on. Spare parts and consumables stay inventory; the machine is an asset.
"""
from __future__ import annotations

import re
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import models
from app.domain import platform_models as plm
from app.repositories.base import ensure_utc, new_id, now, write_event
from app.services.feed_inventory_service import FeedError


class AssetError(FeedError):
    pass


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")[:60] or "asset"


def get_asset(db: Session, asset_id: str, farm_id: str) -> plm.FarmAsset:
    a = db.get(plm.FarmAsset, asset_id)
    if a is None or a.farm_id != farm_id:
        raise AssetError("Asset not found", 404)
    return a


def find_by_code(db: Session, farm_id: str, code: str) -> plm.FarmAsset | None:
    return db.scalar(select(plm.FarmAsset).where(plm.FarmAsset.farm_id == farm_id, plm.FarmAsset.code == code))


def create_asset(db: Session, farm_id: str, *, name: str, asset_type: str = "other", code: str | None = None, manufacturer: str | None = None, model: str | None = None,
                 serial_number: str | None = None, acquisition_date: datetime | None = None, acquisition_cost: float | None = None, currency: str | None = None,
                 current_location_id: str | None = None, parent_asset_id: str | None = None, notes: str | None = None, asset_id: str | None = None,
                 user_id: str) -> plm.FarmAsset:
    if not name or not name.strip():
        raise AssetError("An asset needs a name.")
    if asset_type not in plm.ASSET_TYPES:
        raise AssetError(f"asset_type must be one of {list(plm.ASSET_TYPES)}")
    base = slug(code or name)
    final, n = base, 2
    while find_by_code(db, farm_id, final) is not None:
        final = f"{base}-{n}"
        n += 1
    if current_location_id and db.get(models.Location, current_location_id) is None:
        raise AssetError("Location not found", 404)
    if parent_asset_id:
        get_asset(db, parent_asset_id, farm_id)
    row = plm.FarmAsset(id=asset_id or new_id(), farm_id=farm_id, code=final, name=name.strip(), asset_type=asset_type, manufacturer=manufacturer, model=model,
                        serial_number=serial_number, acquisition_date=ensure_utc(acquisition_date) if acquisition_date else None, acquisition_cost=acquisition_cost,
                        currency=currency, current_location_id=current_location_id, status="active", parent_asset_id=parent_asset_id, notes=notes,
                        created_at=now(), updated_at=now())
    db.add(row)
    db.flush()
    write_event(db, farm_id=farm_id, entity_type="farm_asset", entity_id=row.id, event_type="asset_registered",
                payload={"code": row.code, "name": row.name, "asset_type": asset_type}, created_by=user_id)
    return row


def update_asset(db: Session, asset: plm.FarmAsset, changes: dict, *, user_id: str) -> plm.FarmAsset:
    allowed = {"name", "asset_type", "manufacturer", "model", "serial_number", "acquisition_date", "acquisition_cost", "currency", "current_location_id", "status", "notes"}
    for k, v in changes.items():
        if k in allowed:
            setattr(asset, k, v)
    if asset.asset_type not in plm.ASSET_TYPES:
        raise AssetError(f"asset_type must be one of {list(plm.ASSET_TYPES)}")
    if asset.status not in plm.ASSET_STATUSES:
        raise AssetError(f"status must be one of {list(plm.ASSET_STATUSES)}")
    asset.updated_at = now()
    event = {"out_of_service": "asset_out_of_service", "active": "asset_returned_to_service"}.get(changes.get("status"), "asset_updated")
    write_event(db, farm_id=asset.farm_id, entity_type="farm_asset", entity_id=asset.id, event_type=event, payload={"changed": sorted(changes)}, created_by=user_id)
    return asset


def asset_dict(db: Session, a: plm.FarmAsset) -> dict:
    loc = db.get(models.Location, a.current_location_id) if a.current_location_id else None
    return {"id": a.id, "farm_id": a.farm_id, "code": a.code, "name": a.name, "asset_type": a.asset_type, "manufacturer": a.manufacturer, "model": a.model,
            "serial_number": a.serial_number, "acquisition_date": a.acquisition_date, "acquisition_cost": a.acquisition_cost, "currency": a.currency,
            "current_location_id": a.current_location_id, "current_location_name": loc.name if loc else None, "status": a.status, "parent_asset_id": a.parent_asset_id,
            "notes": a.notes, "created_at": a.created_at, "updated_at": a.updated_at}
