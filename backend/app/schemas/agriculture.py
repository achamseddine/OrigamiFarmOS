"""Fields, crop types and plantings (tech spec §15/§16)."""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, field_validator

from app.schemas.common import ORMModel

FIELD_STATUSES = {"active", "fallow", "retired"}
PLANTING_STAGES = {"planted", "growing", "flowering", "developing", "ripening", "mature", "harvested"}
PLANTING_STATUSES = {"active", "harvested", "failed", "cleared"}


def _non_empty(v: str) -> str:
    if not v.strip():
        raise ValueError("value cannot be empty")
    return v.strip()


class FieldCreate(BaseModel):
    name: str
    field_code: str | None = None
    area_value: float | None = None
    area_unit: str | None = "m2"
    location_label: str | None = None
    soil_type: str | None = None
    irrigation_method: str | None = None
    status: str = "active"
    notes: str | None = None

    @field_validator("name")
    @classmethod
    def name_ok(cls, v: str) -> str:
        return _non_empty(v)

    @field_validator("area_value")
    @classmethod
    def area_positive(cls, v: float | None) -> float | None:
        if v is not None and v <= 0:
            raise ValueError("area must be greater than zero")
        return v

    @field_validator("status")
    @classmethod
    def status_ok(cls, v: str) -> str:
        if v not in FIELD_STATUSES:
            raise ValueError(f"status must be one of {sorted(FIELD_STATUSES)}")
        return v


class FieldUpdate(BaseModel):
    name: str | None = None
    field_code: str | None = None
    area_value: float | None = None
    area_unit: str | None = None
    location_label: str | None = None
    soil_type: str | None = None
    irrigation_method: str | None = None
    status: str | None = None
    notes: str | None = None
    crop_type: str | None = None
    stage: str | None = None
    expected_harvest_date: datetime | None = None
    est_yield_kg: float | None = None

    @field_validator("status")
    @classmethod
    def status_ok(cls, v: str | None) -> str | None:
        if v is not None and v not in FIELD_STATUSES:
            raise ValueError(f"status must be one of {sorted(FIELD_STATUSES)}")
        return v


class CropCreate(BaseModel):
    """Tech spec §16: crop types are farm data, never a hard-coded list."""

    name: str
    category: str | None = None
    default_cycle_days: int | None = None

    @field_validator("name")
    @classmethod
    def name_ok(cls, v: str) -> str:
        return _non_empty(v)


class CropOut(ORMModel):
    id: str
    name: str
    category: str | None = None
    default_cycle_days: int | None = None
    active: bool


class CropPlantingCreate(BaseModel):
    field_id: str
    crop_id: str
    variety: str | None = None
    planted_area: float | None = None
    area_unit: str | None = "m2"
    planted_date: datetime | None = None
    expected_harvest_date: datetime | None = None
    expected_yield_kg: float | None = None
    stage: str = "planted"
    notes: str | None = None

    @field_validator("stage")
    @classmethod
    def stage_ok(cls, v: str) -> str:
        if v not in PLANTING_STAGES:
            raise ValueError(f"stage must be one of {sorted(PLANTING_STAGES)}")
        return v


class CropPlantingUpdate(BaseModel):
    variety: str | None = None
    planted_area: float | None = None
    expected_harvest_date: datetime | None = None
    expected_yield_kg: float | None = None
    stage: str | None = None
    status: str | None = None
    notes: str | None = None

    @field_validator("stage")
    @classmethod
    def stage_ok(cls, v: str | None) -> str | None:
        if v is not None and v not in PLANTING_STAGES:
            raise ValueError(f"stage must be one of {sorted(PLANTING_STAGES)}")
        return v

    @field_validator("status")
    @classmethod
    def status_ok(cls, v: str | None) -> str | None:
        if v is not None and v not in PLANTING_STATUSES:
            raise ValueError(f"status must be one of {sorted(PLANTING_STATUSES)}")
        return v


class CropPlantingOut(ORMModel):
    id: str
    field_id: str
    crop_id: str
    variety: str | None = None
    planted_area: float | None = None
    area_unit: str | None = None
    planted_date: datetime | None = None
    expected_harvest_date: datetime | None = None
    expected_yield_kg: float | None = None
    stage: str
    status: str
    notes: str | None = None
    created_at: datetime


class DailyHarvestCreate(BaseModel):
    """Tech spec §17 "How much was harvested today?" — the sellable/waste
    split is the point: it is what makes waste and cost-per-kg real
    numbers instead of estimates.
    """

    field_id: str
    planting_id: str | None = None
    crop_id: str | None = None
    product_name: str | None = None
    total_quantity: float
    sellable_quantity: float | None = None
    waste_quantity: float = 0
    unit: str = "kg"
    destination: str | None = None
    recorded_at: datetime | None = None
    notes: str | None = None

    @field_validator("total_quantity")
    @classmethod
    def total_positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("total_quantity must be greater than zero")
        return v

    @field_validator("waste_quantity")
    @classmethod
    def waste_non_negative(cls, v: float) -> float:
        if v < 0:
            raise ValueError("waste_quantity cannot be negative")
        return v


class DailyHarvestOut(BaseModel):
    id: str
    field_id: str
    product_name: str
    total_quantity: float
    sellable_quantity: float
    waste_quantity: float
    unit: str
    recorded_at: datetime
    inventory_item_id: str | None = None
    inventory_qty_after: float | None = None
