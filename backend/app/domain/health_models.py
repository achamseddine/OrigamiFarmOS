"""Health & veterinary case model (database/HEALTH-VETERINARY-SCHEMA.md).

Observation is not diagnosis; diagnosis is not treatment; a treatment is
not an administration. The tables here hold the clinical frame the
existing `observations`, `treatments` and `medication_administrations`
rows attach to:

* `health_cases` — one episode for one animal or group, opened by a
  veterinarian / manager or by the emergency engine when it escalates or
  starts a protocol; closed with an outcome, never deleted.
* `diagnoses` — what the veterinarian concluded, with a certainty and a
  status; a revised diagnosis supersedes, never overwrites.
* `treatment_plans` — the prescription frame: who prescribed, when, with
  what instructions; the `treatments` rows are its actions.
* `animal_health_conditions` — allergies, adverse reactions and chronic
  conditions a veterinarian put on the animal's record. The emergency
  engine's eligibility rules read them as authoritative facts.
* `animal_weight_records` — dated weights with their method, so a
  per-weight dose can require a weight no older than the protocol allows
  and feed performance can follow growth.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, Float, ForeignKey, Index, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


CASE_STATUSES = ("open", "monitoring", "resolved", "closed")
CASE_SEVERITIES = ("low", "moderate", "high", "critical")
CERTAINTIES = ("suspected", "presumptive", "confirmed", "ruled_out")
DIAGNOSIS_STATUSES = ("active", "resolved", "superseded")
PLAN_STATUSES = ("prescribed", "active", "completed", "cancelled")
CONDITION_TYPES = ("allergy", "adverse_reaction", "chronic_condition", "contraindication")
WEIGHT_METHODS = ("scale", "tape", "visual_estimate", "point_of_care", "legacy")


class HealthCase(Base):
    __tablename__ = "health_cases"
    __table_args__ = (
        UniqueConstraint("farm_id", "case_code", name="uq_health_case_code"),
        Index("ix_health_cases_subject", "farm_id", "animal_id", "animal_group_id"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    animal_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("animals.id"), nullable=True)
    animal_group_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("flocks.id"), nullable=True)
    case_code: Mapped[str] = mapped_column(String(100))
    opened_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    status: Mapped[str] = mapped_column(String(30), default="open")
    severity_code: Mapped[str | None] = mapped_column(String(30), nullable=True)
    primary_problem_code: Mapped[str | None] = mapped_column(String(100), nullable=True)
    responsible_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    # emergency_assessment | emergency_run | manual | observation
    source_type: Mapped[str | None] = mapped_column(String(40), nullable=True)
    source_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    outcome: Mapped[str | None] = mapped_column(Text, nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    diagnoses: Mapped[list["Diagnosis"]] = relationship(back_populates="case", cascade="all, delete-orphan", order_by="Diagnosis.diagnosed_at")
    plans: Mapped[list["TreatmentPlan"]] = relationship(back_populates="case", cascade="all, delete-orphan", order_by="TreatmentPlan.prescribed_at")


class Diagnosis(Base):
    __tablename__ = "diagnoses"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    health_case_id: Mapped[str] = mapped_column(String(36), ForeignKey("health_cases.id"))
    diagnosis_code: Mapped[str] = mapped_column(String(120))
    diagnosis_text: Mapped[str | None] = mapped_column(String(250), nullable=True)
    certainty_code: Mapped[str] = mapped_column(String(30), default="suspected")
    diagnosed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    diagnosed_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    status: Mapped[str] = mapped_column(String(30), default="active")
    supersedes_diagnosis_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("diagnoses.id"), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)

    case: Mapped["HealthCase"] = relationship(back_populates="diagnoses")


class TreatmentPlan(Base):
    __tablename__ = "treatment_plans"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    health_case_id: Mapped[str] = mapped_column(String(36), ForeignKey("health_cases.id"))
    status: Mapped[str] = mapped_column(String(30), default="prescribed")
    prescribed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    prescribed_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    instructions: Mapped[str | None] = mapped_column(Text, nullable=True)
    # protocol run that produced this plan, when the prescription came
    # from a veterinarian-approved emergency protocol
    source_type: Mapped[str | None] = mapped_column(String(40), nullable=True)
    source_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    case: Mapped["HealthCase"] = relationship(back_populates="plans")


class AnimalHealthCondition(Base):
    """A standing clinical fact on the animal: an allergy to an active
    ingredient, an adverse reaction to a product, a chronic condition, a
    contraindication the veterinarian wrote down. Recorded by a diagnostic
    role; ended, never deleted."""

    __tablename__ = "animal_health_conditions"
    __table_args__ = (Index("ix_animal_health_conditions_animal", "animal_id", "active"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    animal_id: Mapped[str] = mapped_column(String(36), ForeignKey("animals.id"))
    condition_type: Mapped[str] = mapped_column(String(40))
    # What it refers to: an active-ingredient code, a medicine product id,
    # a diagnosis code — matched by the eligibility rules.
    code: Mapped[str] = mapped_column(String(120))
    label: Mapped[str] = mapped_column(String(200))
    severity: Mapped[str | None] = mapped_column(String(30), nullable=True)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    recorded_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)


class AnimalWeightRecord(Base):
    __tablename__ = "animal_weight_records"
    __table_args__ = (Index("ix_animal_weight_records_animal", "animal_id", "measured_at"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    animal_id: Mapped[str] = mapped_column(String(36), ForeignKey("animals.id"))
    weight_kg: Mapped[float] = mapped_column(Float)
    measured_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    # scale | tape | visual_estimate | point_of_care | legacy
    method: Mapped[str] = mapped_column(String(30), default="scale")
    recorded_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    # emergency_run_step | manual | animal_update | migration
    source_type: Mapped[str | None] = mapped_column(String(40), nullable=True)
    source_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
