"""Request bodies for health cases, diagnoses, treatment plans, standing
conditions and weight records (database/HEALTH-VETERINARY-SCHEMA.md)."""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel


class HealthCaseIn(BaseModel):
    subject_type: str
    subject_id: str
    severity_code: str | None = None
    primary_problem_code: str | None = None
    responsible_user_id: str | None = None
    notes: str | None = None
    opened_at: datetime | None = None


class HealthCasePatch(BaseModel):
    status: str | None = None
    severity_code: str | None = None
    primary_problem_code: str | None = None
    responsible_user_id: str | None = None
    notes: str | None = None


class HealthCaseClose(BaseModel):
    outcome: str
    status: str = "resolved"


class DiagnosisIn(BaseModel):
    """`POST /health/cases/{id}/diagnoses` — a diagnostic role only."""

    diagnosis_code: str
    diagnosis_text: str | None = None
    certainty_code: str = "suspected"
    supersedes_diagnosis_id: str | None = None
    diagnosed_at: datetime | None = None
    notes: str | None = None


class TreatmentPlanIn(BaseModel):
    instructions: str | None = None


class ConditionIn(BaseModel):
    """`POST /animals/{id}/conditions` — an allergy, adverse reaction,
    chronic condition or contraindication the veterinarian puts on record."""

    condition_type: str
    code: str
    label: str
    severity: str | None = None
    notes: str | None = None


class WeightIn(BaseModel):
    weight_kg: float
    measured_at: datetime | None = None
    method: str = "scale"
    notes: str | None = None
