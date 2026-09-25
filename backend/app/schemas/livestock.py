"""Shapes for the generic animal model: species configuration, the
capability resolver, identifiers, and animal groups."""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field, field_validator

from app.livestock import catalog
from app.schemas.common import ORMModel


# ------------------------------------------------------------ configuration
class SpeciesOut(ORMModel):
    code: str
    name_en: str
    name_ar: str
    reproduction_mode: str
    icon: str
    default_management: str
    terminology_json: dict
    profiles_json: list[str] = []
    active: bool
    sort_order: int


class BreedOut(ORMModel):
    id: str
    species_code: str
    name: str
    name_ar: str | None = None
    active: bool


class LifeStageOut(ORMModel):
    code: str
    species_code: str | None = None
    label_en: str
    label_ar: str
    sort_order: int


class ManagementProfileOut(ORMModel):
    code: str
    species_code: str | None = None
    label_en: str
    label_ar: str


class CapabilityOut(ORMModel):
    code: str
    category: str
    label_en: str
    label_ar: str
    active: bool


class RuleOut(ORMModel):
    id: str
    species_code: str
    capability_code: str
    sex: str | None = None
    life_stage: str | None = None
    management_profile: str | None = None
    enabled: bool
    required: bool
    configuration_json: dict | None = None
    priority: int


class SpeciesConfigurationOut(BaseModel):
    """Everything the Add Animal flow needs for one species, in one call."""

    species: SpeciesOut
    breeds: list[BreedOut]
    life_stages: list[LifeStageOut]
    management_profiles: list[ManagementProfileOut]
    rules: list[RuleOut]


# ----------------------------------------------------------------- resolver
class ResolveRequest(BaseModel):
    species: str
    sex: str | None = None
    life_stage: str | None = None
    management_profile: str | None = None

    @field_validator("sex")
    @classmethod
    def sex_code(cls, v: str | None) -> str | None:
        if v is None:
            return None
        code = v.strip().upper()
        aliases = {"FEMALE": "F", "MALE": "M", "UNKNOWN": "U", "UNDETERMINED": "U"}
        code = aliases.get(code, code)
        if code not in catalog.SEXES:
            raise ValueError(f"sex must be one of {list(catalog.SEXES)} (or FEMALE / MALE / UNKNOWN)")
        return code


class ResolvedCapabilityOut(BaseModel):
    code: str
    category: str
    label_en: str
    label_ar: str
    required: bool
    configuration: dict | None = None


class CapabilitySetOut(BaseModel):
    species: str
    sex: str | None
    life_stage: str | None
    management_profile: str | None
    reproduction_mode: str
    subject_kind: str
    capabilities: list[ResolvedCapabilityOut]
    allowed_identifier_types: list[str]
    required_identifier_types: list[str]
    terminology: dict
    suppressed: list[str]


# -------------------------------------------------------------- identifiers
class IdentifierIn(BaseModel):
    identifier_type: str
    identifier_value: str
    issuing_authority: str | None = None
    valid_from: datetime | None = None
    valid_to: datetime | None = None
    is_primary: bool = False
    notes: str | None = None

    @field_validator("identifier_type")
    @classmethod
    def known_type(cls, v: str) -> str:
        code = v.strip().upper()
        if code not in catalog.IDENTIFIER_TYPES:
            raise ValueError(f"identifier_type must be one of {sorted(catalog.IDENTIFIER_TYPES)}")
        return code

    @field_validator("identifier_value")
    @classmethod
    def non_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("identifier_value cannot be empty")
        return v.strip()


class IdentifierOut(ORMModel):
    id: str
    animal_id: str
    identifier_type: str
    identifier_value: str
    issuing_authority: str | None = None
    valid_from: datetime | None = None
    valid_to: datetime | None = None
    is_primary: bool
    status: str
    notes: str | None = None
    created_at: datetime


# ------------------------------------------------------------ animal groups
class AnimalGroupCreate(BaseModel):
    name: str
    species: str
    group_type: str = "flock"
    count: int = Field(0, ge=0)
    sex_composition: str | None = None
    life_stage: str | None = None
    management_profile: str | None = None
    location_label: str | None = None

    @field_validator("name")
    @classmethod
    def non_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("name cannot be empty")
        return v.strip()


class AnimalGroupUpdate(BaseModel):
    name: str | None = None
    group_type: str | None = None
    count: int | None = Field(None, ge=0)
    sex_composition: str | None = None
    life_stage: str | None = None
    management_profile: str | None = None
    location_label: str | None = None
    status: str | None = None


class AnimalGroupOut(ORMModel):
    id: str
    farm_id: str
    name: str
    species: str
    group_type: str
    count: int
    sex_composition: str | None = None
    life_stage: str | None = None
    management_profile: str | None = None
    status: str
    location_label: str | None = None
