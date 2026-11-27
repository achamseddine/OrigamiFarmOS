"""Nutrient requirements and formula assessments (master prompt Package 11)."""
from __future__ import annotations

from pydantic import BaseModel, Field


class RequirementValueIn(BaseModel):
    nutrient_code: str = Field(..., max_length=30)
    # On the ration's dry matter, in the nutrient's catalog unit (% , MJ/kg…).
    min_value: float | None = None
    max_value: float | None = None


class RequirementSetCreate(BaseModel):
    code: str = Field(..., max_length=60)
    name: str = Field(..., max_length=200)
    species_code: str = Field(..., max_length=30)
    production_stage: str | None = Field(None, max_length=60)
    reference_body_weight_kg: float | None = None
    milk_yield_kg: float | None = None
    expected_dmi_kg: float | None = None
    # Where the figures come from: the table, the nutritionist, the date. Required.
    source_reference: str = Field(..., max_length=400)
    source_type: str | None = None  # published | nutritionist | veterinarian | farm
    notes: str | None = Field(None, max_length=2000)
    values: list[RequirementValueIn]


class RequirementSetRevise(BaseModel):
    """A new version: its own source, and the values (the old ones kept when left out)."""

    source_reference: str = Field(..., max_length=400)
    source_type: str | None = None
    name: str | None = Field(None, max_length=200)
    production_stage: str | None = Field(None, max_length=60)
    reference_body_weight_kg: float | None = None
    milk_yield_kg: float | None = None
    expected_dmi_kg: float | None = None
    notes: str | None = Field(None, max_length=2000)
    values: list[RequirementValueIn] | None = None


class PremixIn(BaseModel):
    feed_product_id: str
    # Kg on top of the mix as the formula makes it (the base is kept).
    quantity_kg: float = Field(..., gt=0)


class ForageIn(BaseModel):
    feed_product_id: str
    as_fed_kg: float = Field(..., gt=0)  # per head per day


class AssessmentCreate(BaseModel):
    formula_version_id: str
    requirement_set_id: str
    premix: PremixIn | None = None
    # Per head per day, as fed; left out → the ration cannot be assessed (insufficient data).
    concentrate_kg_per_head: float | None = Field(None, gt=0)
    forages: list[ForageIn] = []
    # The ration is this feed only (no forage): say so, rather than leaving the forage out.
    no_forage: bool = False
    body_weight_kg: float | None = Field(None, gt=0)
    notes: str | None = Field(None, max_length=2000)
