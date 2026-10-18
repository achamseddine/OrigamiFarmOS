"""Request bodies for the platform masters: units of measure, farm
assets, notification routes and the scheduler."""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field


class UnitIn(BaseModel):
    """`POST /units-of-measure` — a farm's own unit. A unit that converts
    names a base unit of the same dimension and its factor."""

    code: str
    name_en: str
    name_ar: str | None = None
    dimension: str = "other"
    base_unit_code: str | None = None
    factor_to_base: float = 1.0


class AssetIn(BaseModel):
    name: str
    asset_type: str = "other"
    code: str | None = None
    manufacturer: str | None = None
    model: str | None = None
    serial_number: str | None = None
    acquisition_date: datetime | None = None
    acquisition_cost: float | None = None
    currency: str | None = None
    current_location_id: str | None = None
    parent_asset_id: str | None = None
    notes: str | None = None


class AssetPatch(BaseModel):
    name: str | None = None
    asset_type: str | None = None
    manufacturer: str | None = None
    model: str | None = None
    serial_number: str | None = None
    acquisition_date: datetime | None = None
    acquisition_cost: float | None = None
    currency: str | None = None
    current_location_id: str | None = None
    status: str | None = None
    notes: str | None = None


class RouteEntryIn(BaseModel):
    role: str | None = None
    user_id: str | None = None
    channel: str = "in_app"


class RoutesSet(BaseModel):
    """`PUT /notification-routes/{route_code}` — the people a route
    reaches. An empty list restores the built-in default."""

    entries: list[RouteEntryIn] = Field(default_factory=list)


class SchedulerRunIn(BaseModel):
    job_codes: list[str] | None = None
    force: bool = True
