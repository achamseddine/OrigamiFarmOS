from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, field_validator


class TreatmentCreate(BaseModel):
    """POST /health/treatments.

    Manager/veterinarian-gated (Constitution: "Veterinarians diagnose and
    prescribe" — enforced by the `require_diagnostic_role` dependency in
    api/deps.py). Validation rule (tech spec §14): "Medication, dose,
    route, start date, responsible user, and withdrawal period are
    required where applicable."
    """

    entity_type: str
    entity_id: str
    medication: str
    dose: str
    route: str
    responsible_user_id: str
    diagnosis: str | None = None
    start_at: datetime | None = None
    end_at: datetime | None = None
    withdrawal_until: datetime | None = None
    vet_id: str | None = None
    cost: float | None = None
    notes: str | None = None

    @field_validator("medication", "dose", "route")
    @classmethod
    def not_blank(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("medication, dose and route are required")
        return v
