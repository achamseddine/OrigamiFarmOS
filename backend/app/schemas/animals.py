from __future__ import annotations

from datetime import datetime, timezone

from pydantic import BaseModel, field_validator

from app.schemas.common import ORMModel


class AnimalOut(ORMModel):
    id: str
    farm_id: str
    tag: str
    name: str
    species: str
    breed: str | None = None
    sex: str | None = None
    birth_date: datetime | None = None
    status: str
    location_label: str | None = None
    health_score: int
    pregnant: bool
    pregnancy_days: int | None = None
    lactating: bool
    lactation_cycle: int | None = None
    withdrawal_until: datetime | None = None
    withdrawal_reason: str | None = None
    weight_kg: float | None = None
    group_name: str | None = None
    photo_path: str | None = None
    acquisition_date: datetime | None = None
    acquisition_source: str | None = None
    sire_tag: str | None = None
    dam_tag: str | None = None
    color_markings: str | None = None
    purchase_cost: float | None = None
    current_value: float | None = None
    notes: str | None = None
    active: bool = True

    @property
    def is_under_withdrawal(self) -> bool:
        if self.withdrawal_until is None:
            return False
        # `withdrawal_until` may come back tz-naive on SQLite (see
        # app/repositories/base.ensure_utc) even though every write path in
        # this app is UTC; treat a naive value as already-UTC here.
        withdrawal_until = self.withdrawal_until
        if withdrawal_until.tzinfo is None:
            withdrawal_until = withdrawal_until.replace(tzinfo=timezone.utc)
        return withdrawal_until > datetime.now(timezone.utc)


class AnimalMove(BaseModel):
    location_label: str


ANIMAL_SPECIES = {"cow", "goat", "sheep", "horse", "layer_hen", "duck", "turkey", "other"}
ANIMAL_STATUSES = {"healthy", "under_observation", "under_treatment"}


class AnimalCreate(BaseModel):
    """The full Add-Animal record (tech spec §13). Only tag/name/species
    are required — a farmer standing in a barn should be able to register
    an animal in three fields and fill in the rest later.
    """

    # Identity
    tag: str
    name: str
    species: str
    breed: str | None = None
    sex: str | None = None
    birth_date: datetime | None = None
    acquisition_date: datetime | None = None
    acquisition_source: str | None = None
    sire_tag: str | None = None
    dam_tag: str | None = None
    # Location
    location_label: str | None = None
    group_name: str | None = None
    # Physical
    weight_kg: float | None = None
    color_markings: str | None = None
    photo_path: str | None = None
    # Health
    status: str = "healthy"
    health_score: int = 100
    # Production
    pregnant: bool = False
    pregnancy_days: int | None = None
    lactating: bool = False
    lactation_cycle: int | None = None
    # Financial (only stored when the caller may see Finance — see the router)
    purchase_cost: float | None = None
    current_value: float | None = None
    notes: str | None = None

    @field_validator("tag", "name")
    @classmethod
    def non_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("value cannot be empty")
        return v.strip()

    @field_validator("species")
    @classmethod
    def species_known(cls, v: str) -> str:
        if v not in ANIMAL_SPECIES:
            raise ValueError(f"species must be one of {sorted(ANIMAL_SPECIES)}")
        return v

    @field_validator("status")
    @classmethod
    def status_known(cls, v: str) -> str:
        if v not in ANIMAL_STATUSES:
            raise ValueError(f"status must be one of {sorted(ANIMAL_STATUSES)}")
        return v

    @field_validator("health_score")
    @classmethod
    def score_in_range(cls, v: int) -> int:
        if not 0 <= v <= 100:
            raise ValueError("health_score must be between 0 and 100")
        return v

    @field_validator("weight_kg", "purchase_cost", "current_value")
    @classmethod
    def non_negative(cls, v: float | None) -> float | None:
        if v is not None and v < 0:
            raise ValueError("value cannot be negative")
        return v


class AnimalUpdate(BaseModel):
    """Full edit (tech spec §12). `location_label` is here too, so the
    dedicated Move action and a general edit share one code path.
    """

    tag: str | None = None
    name: str | None = None
    species: str | None = None
    breed: str | None = None
    sex: str | None = None
    birth_date: datetime | None = None
    acquisition_date: datetime | None = None
    acquisition_source: str | None = None
    sire_tag: str | None = None
    dam_tag: str | None = None
    location_label: str | None = None
    group_name: str | None = None
    weight_kg: float | None = None
    color_markings: str | None = None
    photo_path: str | None = None
    status: str | None = None
    health_score: int | None = None
    pregnant: bool | None = None
    pregnancy_days: int | None = None
    lactating: bool | None = None
    lactation_cycle: int | None = None
    purchase_cost: float | None = None
    current_value: float | None = None
    notes: str | None = None
    active: bool | None = None

    @field_validator("species")
    @classmethod
    def species_known(cls, v: str | None) -> str | None:
        if v is not None and v not in ANIMAL_SPECIES:
            raise ValueError(f"species must be one of {sorted(ANIMAL_SPECIES)}")
        return v

    @field_validator("status")
    @classmethod
    def status_known(cls, v: str | None) -> str | None:
        if v is not None and v not in ANIMAL_STATUSES:
            raise ValueError(f"status must be one of {sorted(ANIMAL_STATUSES)}")
        return v


class AnimalDigitalTwinOut(AnimalOut):
    recent_observations: list[dict] = []
    recent_events: list[dict] = []
    open_recommendations: list[dict] = []
