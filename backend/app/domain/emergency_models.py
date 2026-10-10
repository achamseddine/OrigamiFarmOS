"""Clinical decision support & emergency protocol engine
(database/CLINICAL-DECISION-SUPPORT-EMERGENCY-PROTOCOLS.md).

Origami recognises urgent patterns and operationalises veterinarian-
approved farm protocols at the point of care. It never invents a drug,
route, dose, contraindication or withdrawal: every medication instruction
lives inside an approved protocol version, approval provenance is
immutable, and when no current approved protocol applies — or the
evidence, eligibility or dose limits say stop — the engine escalates to
the veterinarian and manager rather than improvising.

Tables: the protocol and its versions (approval lives on the version),
trigger rules (signs and measurements), eligibility rules (animal facts),
steps with their medication parameters, and the runtime records — the
assessment with its candidate matches, the run and its steps, each
medication step bound to the administration it produced.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, Boolean, DateTime, Float, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


STEP_TYPES = ("ASSESS", "NON_DRUG_ACTION", "MEDICATION", "MEASUREMENT", "NOTIFY", "REASSESS", "ESCALATE")
TRIGGER_OPERATORS = (">=", ">", "<=", "<", "==", "!=", "present", "absent")
FAILURE_ACTIONS = ("BLOCK", "REQUIRE_VET", "WARN")
ELIGIBILITY_RULE_TYPES = ("species", "sex", "life_stage", "management_profile", "weight_kg", "weight_known", "pregnant", "lactating",
                          "withdrawal_active", "status", "age_days", "recent_medication", "subject_type")
ELIGIBILITY_RESULTS = ("ELIGIBLE", "WARN", "REQUIRE_VET", "BLOCK")
TRIAGE_LEVELS = ("LOW", "MODERATE", "HIGH", "CRITICAL")
DOSE_RULE_TYPES = ("FIXED", "PER_WEIGHT")


# --------------------------------------------------------------- protocol
class EmergencyProtocol(Base):
    __tablename__ = "emergency_protocols"
    __table_args__ = (UniqueConstraint("farm_id", "code", name="uq_emergency_protocol_farm_code"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    code: Mapped[str] = mapped_column(String(100))
    title: Mapped[str] = mapped_column(String(200))
    condition_family_code: Mapped[str] = mapped_column(String(100))
    species_code: Mapped[str | None] = mapped_column(String(30), ForeignKey("species.code"), nullable=True)
    # animal | group | any — what the protocol is written for.
    subject_scope: Mapped[str] = mapped_column(String(10), default="animal")
    # draft | active | withdrawn
    status: Mapped[str] = mapped_column(String(30), default="draft")
    current_version_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)

    versions: Mapped[list["EmergencyProtocolVersion"]] = relationship(back_populates="protocol", order_by="EmergencyProtocolVersion.version_no")


class EmergencyProtocolVersion(Base):
    """Operational only after veterinary approval (§3). Approval fields
    are written once and never edited; a change is a new version."""

    __tablename__ = "emergency_protocol_versions"
    __table_args__ = (UniqueConstraint("emergency_protocol_id", "version_no", name="uq_emergency_protocol_version_no"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    emergency_protocol_id: Mapped[str] = mapped_column(String(36), ForeignKey("emergency_protocols.id"))
    version_no: Mapped[int] = mapped_column(Integer)
    effective_from: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    effective_to: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    protocol_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    minimum_match_confidence: Mapped[float] = mapped_column(Float, default=0.6)
    requires_manager_notification: Mapped[bool] = mapped_column(Boolean, default=True)
    requires_vet_notification: Mapped[bool] = mapped_column(Boolean, default=True)
    requires_pre_action_confirmation: Mapped[bool] = mapped_column(Boolean, default=True)
    offline_eligible: Mapped[bool] = mapped_column(Boolean, default=False)
    reassessment_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # draft | approved | withdrawn
    status: Mapped[str] = mapped_column(String(30), default="draft")
    approved_by_veterinarian_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    approval_reference: Mapped[str | None] = mapped_column(String(150), nullable=True)
    withdrawn_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)

    protocol: Mapped["EmergencyProtocol"] = relationship(back_populates="versions")
    trigger_rules: Mapped[list["ProtocolTriggerRule"]] = relationship(back_populates="version", cascade="all, delete-orphan")
    eligibility_rules: Mapped[list["ProtocolEligibilityRule"]] = relationship(back_populates="version", cascade="all, delete-orphan")
    steps: Mapped[list["ProtocolStep"]] = relationship(back_populates="version", cascade="all, delete-orphan", order_by="ProtocolStep.step_no")


class ProtocolTriggerRule(Base):
    """A structured sign or measurement the matcher scores (§4)."""

    __tablename__ = "protocol_trigger_rules"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    protocol_version_id: Mapped[str] = mapped_column(String(36), ForeignKey("emergency_protocol_versions.id"))
    observation_code: Mapped[str] = mapped_column(String(100))
    operator: Mapped[str] = mapped_column(String(20), default="present")
    threshold_numeric: Mapped[float | None] = mapped_column(Float, nullable=True)
    threshold_unit: Mapped[str | None] = mapped_column(String(20), nullable=True)
    expected_value_code: Mapped[str | None] = mapped_column(String(100), nullable=True)
    required: Mapped[bool] = mapped_column(Boolean, default=False)
    weight: Mapped[float] = mapped_column(Float, default=1.0)
    danger_sign: Mapped[bool] = mapped_column(Boolean, default=False)
    label: Mapped[str | None] = mapped_column(String(200), nullable=True)

    version: Mapped["EmergencyProtocolVersion"] = relationship(back_populates="trigger_rules")


class ProtocolEligibilityRule(Base):
    """An authoritative-fact check (§5): species, sex, life stage, weight,
    pregnancy/lactation, withdrawal, status, age, recent medication."""

    __tablename__ = "protocol_eligibility_rules"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    protocol_version_id: Mapped[str] = mapped_column(String(36), ForeignKey("emergency_protocol_versions.id"))
    rule_type: Mapped[str] = mapped_column(String(60))
    operator: Mapped[str] = mapped_column(String(20), default="==")
    rule_payload: Mapped[dict] = mapped_column(JSON, default=dict)
    # BLOCK | REQUIRE_VET | WARN
    failure_action: Mapped[str] = mapped_column(String(30), default="WARN")
    message: Mapped[str | None] = mapped_column(String(300), nullable=True)

    version: Mapped["EmergencyProtocolVersion"] = relationship(back_populates="eligibility_rules")


class ProtocolStep(Base):
    __tablename__ = "protocol_steps"
    __table_args__ = (UniqueConstraint("protocol_version_id", "step_no", name="uq_protocol_step_no"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    protocol_version_id: Mapped[str] = mapped_column(String(36), ForeignKey("emergency_protocol_versions.id"))
    step_no: Mapped[int] = mapped_column(Integer)
    step_type: Mapped[str] = mapped_column(String(40))
    title: Mapped[str] = mapped_column(String(200))
    instructions: Mapped[str] = mapped_column(Text)
    required: Mapped[bool] = mapped_column(Boolean, default=True)
    requires_confirmation: Mapped[bool] = mapped_column(Boolean, default=True)
    timing_offset_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)

    version: Mapped["EmergencyProtocolVersion"] = relationship(back_populates="steps")
    medication: Mapped["ProtocolMedicationStep | None"] = relationship(back_populates="step", uselist=False, cascade="all, delete-orphan")


class ProtocolMedicationStep(Base):
    """The only place a drug, route and dose rule may come from (§7). The
    engine calculates from these parameters and nothing else."""

    __tablename__ = "protocol_medication_steps"

    protocol_step_id: Mapped[str] = mapped_column(String(36), ForeignKey("protocol_steps.id"), primary_key=True)
    medicine_product_id: Mapped[str] = mapped_column(String(36), ForeignKey("medicine_products.inventory_item_id"))
    route_code: Mapped[str] = mapped_column(String(40))
    # FIXED | PER_WEIGHT
    dose_rule_type: Mapped[str] = mapped_column(String(40))
    fixed_dose_quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    dose_per_weight_quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    dose_unit: Mapped[str] = mapped_column(String(20))
    weight_unit: Mapped[str | None] = mapped_column(String(20), nullable=True)
    minimum_dose_quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    maximum_dose_quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    repeat_interval_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    maximum_administrations: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # Protocol may require a weight no older than this for PER_WEIGHT.
    weight_max_age_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    withdrawal_rule_payload: Mapped[dict] = mapped_column(JSON, default=dict)

    step: Mapped["ProtocolStep"] = relationship(back_populates="medication")


# ---------------------------------------------------------------- runtime
class EmergencyAssessment(Base):
    """One triage of one subject (§8): the signs used, the animal facts
    used, the candidates, the triage level, the model reference and
    confidence, and why it escalated if it did. Kept whole for audit."""

    __tablename__ = "emergency_assessments"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    animal_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("animals.id"), nullable=True)
    animal_group_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("flocks.id"), nullable=True)
    health_case_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    parent_run_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    # worker | observation_hook | reassessment | api
    source: Mapped[str] = mapped_column(String(30), default="worker")
    observed_signs: Mapped[list] = mapped_column(JSON, default=list)
    animal_facts: Mapped[dict] = mapped_column(JSON, default=dict)
    triage_level: Mapped[str] = mapped_column(String(30), default="LOW")
    ai_model_reference: Mapped[str | None] = mapped_column(String(150), nullable=True)
    ai_confidence: Mapped[float | None] = mapped_column(Float, nullable=True)
    # open | protocol_started | escalated | resolved | closed
    status: Mapped[str] = mapped_column(String(30), default="open")
    escalation_reasons: Mapped[list] = mapped_column(JSON, default=list)
    explanation: Mapped[str] = mapped_column(Text, default="")
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    matches: Mapped[list["ProtocolMatch"]] = relationship(back_populates="assessment", cascade="all, delete-orphan", order_by="ProtocolMatch.match_score.desc()")


class ProtocolMatch(Base):
    __tablename__ = "protocol_matches"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    emergency_assessment_id: Mapped[str] = mapped_column(String(36), ForeignKey("emergency_assessments.id"))
    protocol_version_id: Mapped[str] = mapped_column(String(36), ForeignKey("emergency_protocol_versions.id"))
    match_score: Mapped[float | None] = mapped_column(Float, nullable=True)
    match_explanation: Mapped[dict] = mapped_column(JSON, default=dict)
    # ELIGIBLE | WARN | REQUIRE_VET | BLOCK
    eligibility_result: Mapped[str] = mapped_column(String(30), default="ELIGIBLE")
    blocking_reasons: Mapped[list] = mapped_column(JSON, default=list)
    selected: Mapped[bool] = mapped_column(Boolean, default=False)
    evaluated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    assessment: Mapped["EmergencyAssessment"] = relationship(back_populates="matches")


class EmergencyProtocolRun(Base):
    __tablename__ = "emergency_protocol_runs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    emergency_assessment_id: Mapped[str] = mapped_column(String(36), ForeignKey("emergency_assessments.id"))
    protocol_version_id: Mapped[str] = mapped_column(String(36), ForeignKey("emergency_protocol_versions.id"))
    animal_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("animals.id"), nullable=True)
    animal_group_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("flocks.id"), nullable=True)
    health_case_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    started_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    # in_progress | awaiting_reassessment | escalated | completed | cancelled
    status: Mapped[str] = mapped_column(String(30), default="in_progress")
    manager_notified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    veterinarian_notified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    next_reassessment_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    escalated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    escalation_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    outcome: Mapped[str | None] = mapped_column(Text, nullable=True)
    device_id: Mapped[str | None] = mapped_column(String(100), nullable=True)

    steps: Mapped[list["ProtocolRunStep"]] = relationship(back_populates="run", cascade="all, delete-orphan", order_by="ProtocolRunStep.sequence")


class ProtocolRunStep(Base):
    __tablename__ = "protocol_run_steps"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    protocol_run_id: Mapped[str] = mapped_column(String(36), ForeignKey("emergency_protocol_runs.id"))
    protocol_step_id: Mapped[str] = mapped_column(String(36), ForeignKey("protocol_steps.id"))
    sequence: Mapped[int] = mapped_column(Integer, default=0)
    # pending | presented | completed | skipped | blocked
    status: Mapped[str] = mapped_column(String(30), default="pending")
    due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    presented_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    confirmed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    confirmed_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    medication_administration_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("medication_administrations.id"), nullable=True)
    result_payload: Mapped[dict] = mapped_column(JSON, default=dict)
    skip_reason: Mapped[str | None] = mapped_column(Text, nullable=True)

    run: Mapped["EmergencyProtocolRun"] = relationship(back_populates="steps")
    step: Mapped["ProtocolStep"] = relationship()
