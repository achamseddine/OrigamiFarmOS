from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, field_validator

from app.schemas.common import ORMModel

ALLOWED_MILK_DESTINATIONS = {"stored", "sold", "processed", "consumed"}


class MilkRecordCreate(BaseModel):
    """POST /production/milk.

    Validation rule (tech spec §14): "Liters >= 0; destination sale blocked
    or hard-warned if withdrawal active." The hard block (not just a
    warning) happens in services/production.py, which has access to the
    animal's current withdrawal_until date.
    """

    animal_id: str
    session: str
    liters: float
    destination: str = "stored"
    quality_status: str = "normal"
    recorded_at: datetime | None = None
    recorded_by: str | None = None

    @field_validator("liters")
    @classmethod
    def liters_non_negative(cls, v: float) -> float:
        if v < 0:
            raise ValueError("liters cannot be negative")
        return v

    @field_validator("destination")
    @classmethod
    def destination_known(cls, v: str) -> str:
        if v not in ALLOWED_MILK_DESTINATIONS:
            raise ValueError(f"destination must be one of {sorted(ALLOWED_MILK_DESTINATIONS)}")
        return v


class EggRecordCreate(BaseModel):
    """POST /production/eggs.

    Validation rule (tech spec §14): "Sellable + broken + consumed +
    hatched + wasted cannot exceed total eggs."
    """

    flock_id: str
    total_eggs: int
    sellable_eggs: int = 0
    broken_eggs: int = 0
    consumed: int = 0
    hatched: int = 0
    wasted: int = 0
    recorded_at: datetime | None = None

    @field_validator("total_eggs", "sellable_eggs", "broken_eggs", "consumed", "hatched", "wasted")
    @classmethod
    def non_negative(cls, v: int) -> int:
        if v < 0:
            raise ValueError("egg quantities cannot be negative")
        return v

    def allocation_total(self) -> int:
        return self.sellable_eggs + self.broken_eggs + self.consumed + self.hatched + self.wasted

    def is_allocation_valid(self) -> bool:
        return self.allocation_total() <= self.total_eggs


class HarvestRecordCreate(BaseModel):
    """POST /production/harvest."""

    field_id: str
    product_name: str
    quantity: float
    unit: str = "kg"
    waste_qty: float = 0
    destination: str | None = None
    recorded_at: datetime | None = None

    @field_validator("quantity")
    @classmethod
    def quantity_positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("quantity must be greater than zero")
        return v


class MilkRecordOut(ORMModel):
    id: str
    animal_id: str
    session: str
    liters: float
    quality_status: str
    destination: str
    recorded_at: datetime
    recorded_by: str | None = None


class EggRecordOut(ORMModel):
    id: str
    flock_id: str
    total_eggs: int
    sellable_eggs: int
    broken_eggs: int
    consumed: int
    hatched: int
    wasted: int
    recorded_at: datetime


class HarvestRecordOut(ORMModel):
    id: str
    field_id: str
    product_name: str
    quantity: float
    unit: str
    waste_qty: float
    destination: str | None = None
    recorded_at: datetime


class FieldOut(ORMModel):
    id: str
    name: str
    crop_type: str | None = None
    area_value: float | None = None
    area_unit: str | None = None
    stage: str | None = None
    expected_harvest_date: datetime | None = None
    est_yield_kg: float | None = None
