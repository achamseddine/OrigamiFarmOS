"""Request bodies for the emergency protocol API
(database/CLINICAL-DECISION-SUPPORT-EMERGENCY-PROTOCOLS.md)."""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field


class TriggerRuleIn(BaseModel):
    observation_code: str
    operator: str = "present"
    threshold_numeric: float | None = None
    threshold_unit: str | None = None
    expected_value_code: str | None = None
    required: bool = False
    weight: float = 1.0
    danger_sign: bool = False
    label: str | None = None


class EligibilityRuleIn(BaseModel):
    rule_type: str
    operator: str = "=="
    rule_payload: dict = Field(default_factory=dict)
    failure_action: str = "WARN"
    message: str | None = None


class MedicationStepIn(BaseModel):
    medicine_product_id: str
    route_code: str
    dose_rule_type: str
    fixed_dose_quantity: float | None = None
    dose_per_weight_quantity: float | None = None
    dose_unit: str
    weight_unit: str | None = None
    minimum_dose_quantity: float | None = None
    maximum_dose_quantity: float | None = None
    repeat_interval_minutes: int | None = None
    maximum_administrations: int | None = None
    weight_max_age_days: int | None = None
    withdrawal_rule_payload: dict = Field(default_factory=dict)


class ProtocolStepIn(BaseModel):
    step_no: int
    step_type: str
    title: str
    instructions: str
    required: bool = True
    requires_confirmation: bool = True
    timing_offset_minutes: int | None = None
    medication: MedicationStepIn | None = None


class ProtocolVersionIn(BaseModel):
    protocol_text: str | None = None
    minimum_match_confidence: float = 0.6
    requires_manager_notification: bool = True
    requires_vet_notification: bool = True
    requires_pre_action_confirmation: bool = True
    offline_eligible: bool = False
    reassessment_minutes: int | None = None
    trigger_rules: list[TriggerRuleIn] = Field(default_factory=list)
    eligibility_rules: list[EligibilityRuleIn] = Field(default_factory=list)
    steps: list[ProtocolStepIn] = Field(default_factory=list)


class ProtocolIn(BaseModel):
    code: str
    title: str
    condition_family_code: str
    species_code: str | None = None
    subject_scope: str = "animal"
    version: ProtocolVersionIn


class ApproveVersionIn(BaseModel):
    approval_reference: str
    effective_from: datetime | None = None


class WithdrawVersionIn(BaseModel):
    reason: str


class SignIn(BaseModel):
    code: str
    value_numeric: float | None = None
    value_text: str | None = None
    unit: str | None = None
    present: bool = True


class AssessmentIn(BaseModel):
    """`POST /emergency/assessments` — the worker's signs and measurements.
    Recent observations on the subject are added as evidence."""

    subject_type: str
    subject_id: str
    signs: list[SignIn] = Field(default_factory=list)
    source: str = "worker"
    notes: str | None = None


class StartRunIn(BaseModel):
    match_id: str | None = None
    confirmed: bool = True


class PrepareStepIn(BaseModel):
    weight_kg: float | None = None
    head_count: int | None = None


class ConfirmStepIn(BaseModel):
    weight_kg: float | None = None
    head_count: int | None = None
    lot_id: str | None = None
    result: dict = Field(default_factory=dict)
    notes: str | None = None


class SkipStepIn(BaseModel):
    reason: str


class ReassessIn(BaseModel):
    signs: list[SignIn] = Field(default_factory=list)
    notes: str | None = None


class EscalateIn(BaseModel):
    reason: str


class ResolveRunIn(BaseModel):
    outcome: str
