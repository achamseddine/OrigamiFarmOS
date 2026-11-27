"""Nutrient requirements and formula assessments (master prompt Package 11;
database/NUTRITION-ASSESSMENT.md).

    a requirement set: what a kind of animal at a stage needs, on dry matter —
      cows in early lactation at 650 kg and 30 kg of milk: CP 16–18 %, NEL,
      NDF, peNDF, Ca, P — with its source and a version; a revision is a new
      version, the old one retired, never rewritten
    → an assessment: a formula version (the 1,210 kg base concentrate, an
      optional premix on top), the ration it is fed in (the concentrate per
      head, the forage, the weight) against one version of a set; stored as
      it was computed — the analyses it used, what was unknown — and never
      changed by a later analysis or a later version

An assessment is an explanation, not a ration: it never changes the formula,
a batch or a feeding program, and it says *insufficient data* rather than
assume what is not known.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, CheckConstraint, DateTime, Float, ForeignKey, Index, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


SET_STATUSES = ("active", "retired")
SOURCE_TYPES = ("published", "nutritionist", "veterinarian", "farm")
ASSESSMENT_STATUSES = ("meets", "does_not_meet", "insufficient_data")


class NutritionRequirementSet(Base):
    """What one kind of animal at one stage needs (on dry matter), from a named source."""

    __tablename__ = "nutrition_requirement_sets"
    __table_args__ = (UniqueConstraint("farm_id", "code", "version", name="uq_nutrition_requirement_sets_version"),
                      CheckConstraint("version >= 1", name="ck_nutrition_requirement_sets_version"))

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"), index=True)
    code: Mapped[str] = mapped_column(String(60))
    version: Mapped[int] = mapped_column(Integer, default=1)
    name: Mapped[str] = mapped_column(String(200))
    species_code: Mapped[str] = mapped_column(String(30), ForeignKey("species.code"))
    # early_lactation, dry, late_gestation, growing… (configured words, not species branches)
    production_stage: Mapped[str | None] = mapped_column(String(60), nullable=True)
    # The animal the figures are for: an assessment for a very different weight is not one.
    reference_body_weight_kg: Mapped[float | None] = mapped_column(Float, nullable=True)
    milk_yield_kg: Mapped[float | None] = mapped_column(Float, nullable=True)
    # The dry matter it is expected to eat a day; the ration's intake is compared with it.
    expected_dmi_kg: Mapped[float | None] = mapped_column(Float, nullable=True)
    basis: Mapped[str] = mapped_column(String(20), default="dry_matter")
    source_type: Mapped[str] = mapped_column(String(30), default="nutritionist")
    source_reference: Mapped[str] = mapped_column(String(400))
    status: Mapped[str] = mapped_column(String(20), default="active")
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    retired_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    values: Mapped[list["NutritionRequirementValue"]] = relationship(back_populates="requirement_set", lazy="selectin", cascade="all, delete-orphan")


class NutritionRequirementValue(Base):
    """A nutrient's minimum and/or maximum in the ration's dry matter."""

    __tablename__ = "nutrition_requirement_values"
    __table_args__ = (UniqueConstraint("requirement_set_id", "nutrient_code", name="uq_nutrition_requirement_values_nutrient"),
                      CheckConstraint("min_value IS NOT NULL OR max_value IS NOT NULL", name="ck_nutrition_requirement_values_bound"),
                      CheckConstraint("min_value IS NULL OR max_value IS NULL OR min_value <= max_value", name="ck_nutrition_requirement_values_order"))

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    requirement_set_id: Mapped[str] = mapped_column(String(36), ForeignKey("nutrition_requirement_sets.id"), index=True)
    nutrient_code: Mapped[str] = mapped_column(String(30), ForeignKey("feed_nutrients.code"))
    min_value: Mapped[float | None] = mapped_column(Float, nullable=True)
    max_value: Mapped[float | None] = mapped_column(Float, nullable=True)
    unit: Mapped[str] = mapped_column(String(20))

    requirement_set: Mapped[NutritionRequirementSet] = relationship(back_populates="values")


class NutritionAssessment(Base):
    """One assessment, kept as computed: its inputs, the analyses used, the result."""

    __tablename__ = "nutrition_assessments"
    __table_args__ = (Index("ix_nutrition_assessments_version", "farm_id", "formula_version_id", "created_at"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    formula_version_id: Mapped[str] = mapped_column(String(36), ForeignKey("feed_formula_versions.id"))
    requirement_set_id: Mapped[str] = mapped_column(String(36), ForeignKey("nutrition_requirement_sets.id"))
    status: Mapped[str] = mapped_column(String(30))
    # The what-if: a premix on top of the base (never written into the formula).
    premix_product_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("feed_products.id"), nullable=True)
    premix_quantity_kg: Mapped[float | None] = mapped_column(Float, nullable=True)
    inputs: Mapped[dict] = mapped_column(JSON, default=dict)
    result: Mapped[dict] = mapped_column(JSON, default=dict)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
