from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator

ALLOWED_ENTITY_TYPES = {"animal", "flock", "field"}


class ObservationCreate(BaseModel):
    """POST /observations.

    Constitution: "Workers record observations. Workers do not diagnose."
    There is deliberately no `diagnosis` field here — see
    schemas/health.TreatmentCreate for the manager/vet-gated path.
    """

    farm_id: str
    entity_type: str
    entity_id: str
    observation_type: str
    quality: str = Field(default="human_observed")
    value_numeric: float | None = None
    value_text: str | None = None
    unit: str | None = None
    severity: str | None = None
    observed_at: datetime | None = None
    observer_id: str
    notes: str | None = None

    @field_validator("entity_type")
    @classmethod
    def entity_type_must_be_known(cls, v: str) -> str:
        if v not in ALLOWED_ENTITY_TYPES:
            raise ValueError(f"entity_type must be one of {sorted(ALLOWED_ENTITY_TYPES)}")
        return v


class ObservationOut(BaseModel):
    id: str
    farm_id: str
    entity_type: str
    entity_id: str
    observation_type: str
    quality: str
    confidence: float
    value_numeric: float | None
    value_text: str | None
    unit: str | None
    severity: str | None
    observed_at: datetime
    observer_id: str
    notes: str | None

    model_config = ConfigDict(from_attributes=True)
