"""Clinical decision support & emergency protocol engine
(database/CLINICAL-DECISION-SUPPORT-EMERGENCY-PROTOCOLS.md) — the
deterministic first increment.

What it does: scores the worker's signs against the trigger rules of
every current, veterinarian-approved protocol version; checks the
animal's authoritative facts against the version's eligibility rules;
ranks urgency; explains which facts supported a match and what is
missing; calculates a dose only from the approved parameters and only
within their limits; checks exact eligible pharmacy stock before a
medication step; binds the administration to the lot; schedules the
reassessment; and notifies the manager and veterinarian as the version
requires.

What it never does: display a drug, route or dose that is not in a
current approved version; treat its own guess as a prescription; skip
escalation when a danger sign fires, a required observation is missing,
no approved protocol matches, the animal fails a BLOCK / REQUIRE_VET
rule, the medicine is unavailable or only ineligible stock exists, the
dose falls outside the approved range, or the response at reassessment
is not an improvement.
"""
from __future__ import annotations

import hashlib
import json
from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core import permissions as perms
from app.domain import emergency_models as em
from app.domain import models
from app.domain import pharmacy_models as pm
from app.repositories.base import ensure_utc, new_id, now, write_event
from app.services import pharmacy_service as ph
from app.services.feed_inventory_service import FeedError


class EmergencyError(FeedError):
    """A rule of the protocol engine refused the operation."""


MODEL_REFERENCE = "origami.emergency.deterministic"
MODEL_VERSION = "1.0"
OBSERVATION_LOOKBACK_HOURS = 24
DUPLICATE_WINDOW_HOURS = 6
ESCALATION_TASK = "emergency_escalation"
NOTIFY_TASK = "emergency_notification"

# Standard sign vocabulary the tablet offers; protocols may add their own.
STANDARD_SIGNS = (
    {"code": "temperature_c", "kind": "numeric", "unit": "°C", "label": "Rectal temperature"},
    {"code": "heart_rate", "kind": "numeric", "unit": "bpm", "label": "Heart rate"},
    {"code": "respiratory_rate", "kind": "numeric", "unit": "/min", "label": "Respiratory rate"},
    {"code": "appetite", "kind": "categorical", "options": ["normal", "reduced", "absent"], "label": "Appetite"},
    {"code": "rumination", "kind": "categorical", "options": ["normal", "reduced", "absent"], "label": "Rumination"},
    {"code": "water_intake", "kind": "categorical", "options": ["normal", "reduced", "absent"], "label": "Water intake"},
    {"code": "fever", "kind": "boolean", "label": "Fever (felt / suspected)"},
    {"code": "recumbent", "kind": "boolean", "label": "Down, cannot rise"},
    {"code": "bloat", "kind": "boolean", "label": "Bloat"},
    {"code": "diarrhoea", "kind": "boolean", "label": "Diarrhoea"},
    {"code": "nasal_discharge", "kind": "boolean", "label": "Nasal discharge"},
    {"code": "coughing", "kind": "boolean", "label": "Coughing"},
    {"code": "lameness", "kind": "boolean", "label": "Lameness"},
    {"code": "colic_signs", "kind": "boolean", "label": "Colic signs (pawing, rolling)"},
    {"code": "udder_swelling", "kind": "boolean", "label": "Udder swelling / heat"},
    {"code": "panting", "kind": "boolean", "label": "Open-mouth panting"},
    {"code": "mortality_count", "kind": "numeric", "unit": "head", "label": "Dead today"},
    {"code": "ambient_temperature_c", "kind": "numeric", "unit": "°C", "label": "Ambient temperature"},
    {"code": "milk_drop_pct", "kind": "numeric", "unit": "%", "label": "Milk drop"},
)
# Legacy observation types map onto the sign vocabulary.
OBSERVATION_CODE_ALIASES = {"temperature": "temperature_c", "temp": "temperature_c", "body_temperature": "temperature_c", "mortality": "mortality_count",
                            "down": "recumbent", "off_feed": "appetite"}
SEVERE_OBSERVATION_SEVERITIES = ("severe", "critical")


# ---------------------------------------------------------------- helpers
def _rank(result: str) -> int:
    return em.ELIGIBILITY_RESULTS.index(result)


def _worst(results: list[str]) -> str:
    return max(results, key=_rank) if results else "ELIGIBLE"


def _subject(db: Session, subject_type: str, subject_id: str, farm_id: str):
    if subject_type not in ("animal", "group"):
        raise EmergencyError("subject_type must be animal or group")
    subject = db.get(models.Animal, subject_id) if subject_type == "animal" else db.get(models.Flock, subject_id)
    if subject is None or subject.farm_id != farm_id:
        raise EmergencyError("Subject not found", 404)
    return subject


def get_protocol(db: Session, protocol_id: str, farm_id: str) -> em.EmergencyProtocol:
    p = db.get(em.EmergencyProtocol, protocol_id)
    if p is None or p.farm_id != farm_id:
        raise EmergencyError("Protocol not found", 404)
    return p


def get_version(db: Session, version_id: str, farm_id: str) -> em.EmergencyProtocolVersion:
    v = db.get(em.EmergencyProtocolVersion, version_id)
    if v is None or v.protocol.farm_id != farm_id:
        raise EmergencyError("Protocol version not found", 404)
    return v


def get_assessment(db: Session, assessment_id: str, farm_id: str) -> em.EmergencyAssessment:
    a = db.get(em.EmergencyAssessment, assessment_id)
    if a is None or a.farm_id != farm_id:
        raise EmergencyError("Assessment not found", 404)
    return a


def get_run(db: Session, run_id: str, farm_id: str) -> em.EmergencyProtocolRun:
    r = db.get(em.EmergencyProtocolRun, run_id)
    if r is None or r.farm_id != farm_id:
        raise EmergencyError("Protocol run not found", 404)
    return r


def version_is_current(v: em.EmergencyProtocolVersion, at: datetime | None = None) -> bool:
    at = at or now()
    if v.status != "approved" or v.protocol.status != "active" or v.protocol.current_version_id != v.id:
        return False
    if v.effective_from is not None and ensure_utc(v.effective_from) > at:
        return False
    if v.effective_to is not None and ensure_utc(v.effective_to) <= at:
        return False
    return True


# -------------------------------------------------------------- authoring
def _validate_version_payload(db: Session, farm_id: str, *, trigger_rules: list[dict], eligibility_rules: list[dict], steps: list[dict]) -> None:
    if not trigger_rules:
        raise EmergencyError("A protocol version needs at least one trigger rule.")
    for r in trigger_rules:
        if r.get("operator", "present") not in em.TRIGGER_OPERATORS:
            raise EmergencyError(f"Trigger operator must be one of {list(em.TRIGGER_OPERATORS)}")
        if r.get("operator") in (">=", ">", "<=", "<") and r.get("threshold_numeric") is None:
            raise EmergencyError(f"Trigger '{r.get('observation_code')}' compares a number but has no threshold.")
        if (r.get("weight") or 0) < 0:
            raise EmergencyError("Trigger weights cannot be negative.")
    for r in eligibility_rules:
        if r.get("rule_type") not in em.ELIGIBILITY_RULE_TYPES:
            raise EmergencyError(f"Eligibility rule type must be one of {list(em.ELIGIBILITY_RULE_TYPES)}")
        if r.get("failure_action", "WARN") not in em.FAILURE_ACTIONS:
            raise EmergencyError(f"failure_action must be one of {list(em.FAILURE_ACTIONS)}")
    if not steps:
        raise EmergencyError("A protocol version needs at least one step.")
    numbers = [s["step_no"] for s in steps]
    if len(set(numbers)) != len(numbers):
        raise EmergencyError("Step numbers must be unique.")
    for s in steps:
        if s.get("step_type") not in em.STEP_TYPES:
            raise EmergencyError(f"step_type must be one of {list(em.STEP_TYPES)}")
        med = s.get("medication")
        if s["step_type"] == "MEDICATION":
            if not med:
                raise EmergencyError(f"Step {s['step_no']} is a medication step without an approved medication instruction.")
            product = db.get(pm.MedicineProduct, med["medicine_product_id"])
            if product is None or product.farm_id != farm_id:
                raise EmergencyError(f"Step {s['step_no']}: medicine product not found in this farm's pharmacy.")
            if med["dose_rule_type"] not in em.DOSE_RULE_TYPES:
                raise EmergencyError("dose_rule_type must be FIXED or PER_WEIGHT")
            if med["dose_rule_type"] == "FIXED" and med.get("fixed_dose_quantity") is None:
                raise EmergencyError("A FIXED dose rule needs fixed_dose_quantity.")
            if med["dose_rule_type"] == "PER_WEIGHT" and (med.get("dose_per_weight_quantity") is None or not med.get("weight_unit")):
                raise EmergencyError("A PER_WEIGHT dose rule needs dose_per_weight_quantity and weight_unit.")
            if med["route_code"] not in pm.ROUTES:
                raise EmergencyError(f"route_code must be one of {list(pm.ROUTES)}")
            if product.administration_routes and med["route_code"] not in product.administration_routes:
                raise EmergencyError(f"Step {s['step_no']}: {med['route_code']} is not an authorised route for this medicine ({', '.join(product.administration_routes)}).")
            lo, hi = med.get("minimum_dose_quantity"), med.get("maximum_dose_quantity")
            if lo is not None and hi is not None and lo > hi:
                raise EmergencyError("minimum_dose_quantity cannot exceed maximum_dose_quantity.")
        elif med:
            raise EmergencyError(f"Step {s['step_no']} is not a medication step but carries a medication instruction.")


def add_version(db: Session, protocol: em.EmergencyProtocol, *, trigger_rules: list[dict], eligibility_rules: list[dict], steps: list[dict],
                protocol_text: str | None = None, minimum_match_confidence: float = 0.6, requires_manager_notification: bool = True,
                requires_vet_notification: bool = True, requires_pre_action_confirmation: bool = True, offline_eligible: bool = False,
                reassessment_minutes: int | None = None, user_id: str) -> em.EmergencyProtocolVersion:
    """A new draft version (§3). Nothing here is operational until a
    veterinarian approves it."""
    trigger_rules = [r if isinstance(r, dict) else r.model_dump() for r in trigger_rules]
    eligibility_rules = [r if isinstance(r, dict) else r.model_dump() for r in eligibility_rules]
    steps = [s if isinstance(s, dict) else s.model_dump() for s in steps]
    _validate_version_payload(db, protocol.farm_id, trigger_rules=trigger_rules, eligibility_rules=eligibility_rules, steps=steps)
    if not 0 < minimum_match_confidence <= 1:
        raise EmergencyError("minimum_match_confidence must be between 0 and 1.")
    last = db.scalar(select(func.max(em.EmergencyProtocolVersion.version_no)).where(em.EmergencyProtocolVersion.emergency_protocol_id == protocol.id)) or 0
    v = em.EmergencyProtocolVersion(
        id=new_id(), emergency_protocol_id=protocol.id, version_no=last + 1, protocol_text=protocol_text, minimum_match_confidence=minimum_match_confidence,
        requires_manager_notification=requires_manager_notification, requires_vet_notification=requires_vet_notification,
        requires_pre_action_confirmation=requires_pre_action_confirmation, offline_eligible=offline_eligible, reassessment_minutes=reassessment_minutes,
        status="draft", created_at=now(), created_by=user_id,
    )
    for r in trigger_rules:
        v.trigger_rules.append(em.ProtocolTriggerRule(id=new_id(), **{k: r.get(k) for k in ("observation_code", "threshold_numeric", "threshold_unit", "expected_value_code", "label")},
                                                      operator=r.get("operator", "present"), required=bool(r.get("required")), weight=float(r.get("weight", 1.0) or 0), danger_sign=bool(r.get("danger_sign"))))
    for r in eligibility_rules:
        v.eligibility_rules.append(em.ProtocolEligibilityRule(id=new_id(), rule_type=r["rule_type"], operator=r.get("operator", "=="), rule_payload=r.get("rule_payload") or {},
                                                              failure_action=r.get("failure_action", "WARN"), message=r.get("message")))
    for s in sorted(steps, key=lambda s: s["step_no"]):
        step = em.ProtocolStep(id=new_id(), step_no=s["step_no"], step_type=s["step_type"], title=s["title"], instructions=s["instructions"],
                               required=bool(s.get("required", True)), requires_confirmation=bool(s.get("requires_confirmation", True)), timing_offset_minutes=s.get("timing_offset_minutes"))
        med = s.get("medication")
        if med:
            step.medication = em.ProtocolMedicationStep(**{k: med.get(k) for k in (
                "medicine_product_id", "route_code", "dose_rule_type", "fixed_dose_quantity", "dose_per_weight_quantity", "dose_unit", "weight_unit",
                "minimum_dose_quantity", "maximum_dose_quantity", "repeat_interval_minutes", "maximum_administrations", "weight_max_age_days")},
                withdrawal_rule_payload=med.get("withdrawal_rule_payload") or {})
        v.steps.append(step)
    db.add(v)
    db.flush()
    write_event(db, farm_id=protocol.farm_id, entity_type="emergency_protocol", entity_id=protocol.id, event_type="emergency_protocol_version_drafted",
                payload={"version_id": v.id, "version_no": v.version_no, "steps": len(steps), "medication_steps": sum(1 for s in steps if s.get("medication"))}, created_by=user_id)
    return v


def create_protocol(db: Session, farm_id: str, *, code: str, title: str, condition_family_code: str, species_code: str | None = None, subject_scope: str = "animal",
                    version: dict, user_id: str) -> em.EmergencyProtocol:
    if subject_scope not in ("animal", "group", "any"):
        raise EmergencyError("subject_scope must be animal, group or any")
    if db.scalar(select(em.EmergencyProtocol.id).where(em.EmergencyProtocol.farm_id == farm_id, em.EmergencyProtocol.code == code)):
        raise EmergencyError(f"A protocol with code {code} already exists.")
    if species_code and db.scalar(select(func.count()).select_from(models.Animal.__table__.metadata.tables["species"]).where(
            models.Animal.__table__.metadata.tables["species"].c.code == species_code)) == 0:
        raise EmergencyError(f"Unknown species '{species_code}'")
    p = em.EmergencyProtocol(id=new_id(), farm_id=farm_id, code=code.strip(), title=title.strip(), condition_family_code=condition_family_code, species_code=species_code,
                             subject_scope=subject_scope, status="draft", created_at=now(), created_by=user_id)
    db.add(p)
    db.flush()
    add_version(db, p, user_id=user_id, **(version if isinstance(version, dict) else version.model_dump()))
    write_event(db, farm_id=farm_id, entity_type="emergency_protocol", entity_id=p.id, event_type="emergency_protocol_created",
                payload={"code": p.code, "title": p.title, "species_code": species_code, "subject_scope": subject_scope}, created_by=user_id)
    return p


def approve_version(db: Session, version: em.EmergencyProtocolVersion, *, approver: models.User, approval_reference: str, effective_from: datetime | None = None) -> em.EmergencyProtocolVersion:
    """Veterinary approval (§3): the only way a version becomes
    operational. Written once; a later change is a new version."""
    if approver.role != "veterinarian":
        raise EmergencyError("Only a veterinarian can approve an emergency protocol. Managers may draft and withdraw; approval is clinical.", 403)
    if version.status != "draft":
        raise EmergencyError(f"Version {version.version_no} is {version.status}; only a draft can be approved.")
    if not approval_reference or not approval_reference.strip():
        raise EmergencyError("An approval reference is required (the vet's note, licence or document number).")
    protocol = version.protocol
    at = now()
    for other in protocol.versions:
        if other.id != version.id and other.status == "approved" and other.effective_to is None:
            other.effective_to = at
    version.status = "approved"
    version.approved_by_veterinarian_id = approver.id
    version.approved_at = at
    version.approval_reference = approval_reference.strip()
    version.effective_from = ensure_utc(effective_from) if effective_from else at
    protocol.current_version_id = version.id
    protocol.status = "active"
    write_event(db, farm_id=protocol.farm_id, entity_type="emergency_protocol", entity_id=protocol.id, event_type="emergency_protocol_approved",
                payload={"version_id": version.id, "version_no": version.version_no, "approved_by": approver.id, "approval_reference": version.approval_reference}, created_by=approver.id)
    return version


def withdraw_version(db: Session, version: em.EmergencyProtocolVersion, *, reason: str, user_id: str) -> em.EmergencyProtocolVersion:
    if version.status == "withdrawn":
        return version
    if not reason or not reason.strip():
        raise EmergencyError("Say why the version is withdrawn.")
    protocol = version.protocol
    version.status = "withdrawn"
    version.effective_to = now()
    version.withdrawn_reason = reason.strip()
    if protocol.current_version_id == version.id:
        protocol.current_version_id = None
        protocol.status = "withdrawn"
    write_event(db, farm_id=protocol.farm_id, entity_type="emergency_protocol", entity_id=protocol.id, event_type="emergency_protocol_withdrawn",
                payload={"version_id": version.id, "version_no": version.version_no, "reason": reason}, created_by=user_id)
    return version


def current_versions(db: Session, farm_id: str, *, at: datetime | None = None) -> list[em.EmergencyProtocolVersion]:
    out = []
    for p in db.scalars(select(em.EmergencyProtocol).where(em.EmergencyProtocol.farm_id == farm_id, em.EmergencyProtocol.status == "active")):
        v = db.get(em.EmergencyProtocolVersion, p.current_version_id) if p.current_version_id else None
        if v is not None and version_is_current(v, at):
            out.append(v)
    return out


# ------------------------------------------------------------------ facts
def _animal_facts(db: Session, subject_type: str, subject) -> dict:
    at = now()
    if subject_type == "animal":
        a: models.Animal = subject
        age_days = int((at - ensure_utc(a.birth_date)).total_seconds() // 86400) if a.birth_date else None
        recent = db.scalars(select(pm.MedicationAdministration).where(
            pm.MedicationAdministration.subject_id == a.id, pm.MedicationAdministration.status == "recorded",
            pm.MedicationAdministration.administered_at >= at - timedelta(days=7))).all()
        treatments = db.scalar(select(func.count(models.Treatment.id)).where(models.Treatment.entity_type == "animal", models.Treatment.entity_id == a.id, models.Treatment.status == "active")) or 0
        return {
            "subject_type": "animal", "species": a.species, "sex": a.sex, "life_stage": a.life_stage, "management_profile": a.management_profile,
            "weight_kg": a.weight_kg, "weight_known": a.weight_kg is not None, "pregnant": bool(a.pregnant), "lactating": bool(a.lactating),
            "withdrawal_active": bool(a.withdrawal_until and ensure_utc(a.withdrawal_until) > at), "withdrawal_until": a.withdrawal_until.isoformat() if a.withdrawal_until else None,
            "status": a.status, "age_days": age_days, "health_score": a.health_score, "active_treatments": treatments,
            "recent_medications": [{"inventory_item_id": r.inventory_item_id, "administered_at": r.administered_at.isoformat(), "route": r.route_code} for r in recent],
        }
    g: models.Flock = subject
    return {"subject_type": "group", "species": g.species, "sex": getattr(g, "sex_composition", None), "life_stage": getattr(g, "life_stage", None),
            "management_profile": getattr(g, "management_profile", None), "weight_kg": None, "weight_known": False, "pregnant": False, "lactating": False,
            "withdrawal_active": False, "status": getattr(g, "status", None), "age_days": None, "count": g.count, "active_treatments": 0, "recent_medications": []}


def _normalise_code(code: str) -> str:
    c = (code or "").strip().lower().replace(" ", "_")
    return OBSERVATION_CODE_ALIASES.get(c, c)


def _sign_values(db: Session, subject_type: str, subject, signs: list[dict]) -> dict[str, dict]:
    """Explicit signs win; recent observations on the subject fill in the
    rest, each tagged with its source so the explanation can say so."""
    out: dict[str, dict] = {}
    since = now() - timedelta(hours=OBSERVATION_LOOKBACK_HOURS)
    entity_types = ("animal",) if subject_type == "animal" else ("flock", "group")
    rows = db.scalars(select(models.Observation).where(
        models.Observation.entity_type.in_(entity_types), models.Observation.entity_id == subject.id, models.Observation.observed_at >= since,
    ).order_by(models.Observation.observed_at)).all()
    for o in rows:
        code = _normalise_code(o.observation_type)
        out[code] = {"code": code, "value_numeric": o.value_numeric, "value_text": o.value_text, "unit": o.unit, "present": True,
                     "severity": o.severity, "source": "observation", "observed_at": ensure_utc(o.observed_at).isoformat(), "observation_id": o.id}
    for s in signs:
        s = s if isinstance(s, dict) else s.model_dump()
        code = _normalise_code(s["code"])
        if s.get("present", True) is False:
            out.pop(code, None)
            out[code] = {"code": code, "present": False, "source": "reported"}
            continue
        out[code] = {"code": code, "value_numeric": s.get("value_numeric"), "value_text": (s.get("value_text") or "").strip().lower() or None,
                     "unit": s.get("unit"), "present": True, "source": "reported", "observed_at": now().isoformat()}
    return out


def _eval_trigger(rule: em.ProtocolTriggerRule, sign: dict | None) -> tuple[bool, str]:
    present = sign is not None and sign.get("present", True)
    label = rule.label or rule.observation_code
    if rule.operator == "present":
        return present, f"{label}: {'reported' if present else 'not reported'}"
    if rule.operator == "absent":
        return not present, f"{label}: {'absent' if not present else 'present'}"
    if not present:
        return False, f"{label}: not reported"
    if rule.operator in (">=", ">", "<=", "<"):
        v = sign.get("value_numeric")
        if v is None:
            return False, f"{label}: no measurement given"
        ok = {">=": v >= rule.threshold_numeric, ">": v > rule.threshold_numeric, "<=": v <= rule.threshold_numeric, "<": v < rule.threshold_numeric}[rule.operator]
        return ok, f"{label}: {v:g}{rule.threshold_unit or ''} {rule.operator} {rule.threshold_numeric:g}{rule.threshold_unit or ''} → {'yes' if ok else 'no'}"
    expected = (rule.expected_value_code or "").strip().lower()
    actual = (sign.get("value_text") or "").strip().lower()
    if actual == "" and sign.get("value_numeric") is not None and rule.threshold_numeric is not None:
        ok = (sign["value_numeric"] == rule.threshold_numeric) if rule.operator == "==" else (sign["value_numeric"] != rule.threshold_numeric)
        return ok, f"{label}: {sign['value_numeric']:g} {rule.operator} {rule.threshold_numeric:g} → {'yes' if ok else 'no'}"
    ok = (actual == expected) if rule.operator == "==" else (actual != expected)
    return ok, f"{label}: '{actual or '—'}' {rule.operator} '{expected}' → {'yes' if ok else 'no'}"


def _score(version: em.EmergencyProtocolVersion, signs: dict[str, dict]) -> dict:
    matched, unmatched, required_missing, danger = [], [], [], []
    total = sum(r.weight for r in version.trigger_rules if not r.danger_sign) or 1.0
    got = 0.0
    for r in version.trigger_rules:
        ok, detail = _eval_trigger(r, signs.get(_normalise_code(r.observation_code)))
        entry = {"code": r.observation_code, "detail": detail, "weight": r.weight, "required": r.required, "danger_sign": r.danger_sign,
                 "source": (signs.get(_normalise_code(r.observation_code)) or {}).get("source")}
        if r.danger_sign:
            if ok:
                danger.append(entry)
            continue
        if ok:
            got += r.weight
            matched.append(entry)
        else:
            unmatched.append(entry)
            if r.required:
                required_missing.append(entry)
    return {"score": round(got / total, 4), "matched": matched, "unmatched": unmatched, "required_missing": required_missing, "danger_signs": danger}


def _eval_eligibility(version: em.EmergencyProtocolVersion, facts: dict) -> tuple[str, list[dict]]:
    outcomes = []
    for r in version.eligibility_rules:
        p = r.rule_payload or {}
        value = facts.get(r.rule_type)
        passed = True
        if r.rule_type in ("species", "sex", "life_stage", "management_profile", "status", "subject_type"):
            if "in" in p:
                passed = value in p["in"]
            elif "not_in" in p:
                passed = value not in p["not_in"]
            elif "value" in p:
                passed = (value == p["value"]) if r.operator in ("==", "in") else (value != p["value"])
        elif r.rule_type in ("weight_kg", "age_days"):
            if value is None:
                passed = not p.get("required", True)
            else:
                lo, hi = p.get("min"), p.get("max")
                passed = (lo is None or value >= lo) and (hi is None or value <= hi)
        elif r.rule_type in ("weight_known", "pregnant", "lactating", "withdrawal_active"):
            expected = bool(p.get("value", True))
            passed = bool(value) == expected
        elif r.rule_type == "recent_medication":
            within = float(p.get("within_hours", 24))
            product = p.get("not")
            cutoff = now() - timedelta(hours=within)
            passed = not any(m["inventory_item_id"] == product and ensure_utc(datetime.fromisoformat(m["administered_at"])) >= cutoff for m in facts.get("recent_medications", []))
        outcomes.append({"rule_type": r.rule_type, "passed": passed, "failure_action": r.failure_action, "message": r.message or f"{r.rule_type} check {'passed' if passed else 'failed'}",
                         "fact": value if not isinstance(value, list) else len(value)})
    result = _worst([o["failure_action"] for o in outcomes if not o["passed"]])
    return result, outcomes


# ------------------------------------------------------------- assessment
def assess(db: Session, farm_id: str, *, subject_type: str, subject_id: str, signs: list, source: str = "worker", notes: str | None = None,
           parent_run_id: str | None = None, only_version: em.EmergencyProtocolVersion | None = None, user_id: str) -> em.EmergencyAssessment:
    """Triage (§12): score every current approved protocol, check
    eligibility, rank urgency, select or escalate. Everything used is
    kept on the assessment for audit (§15)."""
    subject = _subject(db, subject_type, subject_id, farm_id)
    at = now()
    sign_map = _sign_values(db, subject_type, subject, signs)
    facts = _animal_facts(db, subject_type, subject)
    versions = [only_version] if only_version is not None else current_versions(db, farm_id, at=at)
    versions = [v for v in versions if v.protocol.subject_scope in ("any", subject_type) and (v.protocol.species_code in (None, facts["species"]))]

    assessment = em.EmergencyAssessment(
        id=new_id(), farm_id=farm_id, animal_id=subject_id if subject_type == "animal" else None, animal_group_id=subject_id if subject_type == "group" else None,
        parent_run_id=parent_run_id, started_at=at, source=source, observed_signs=list(sign_map.values()), animal_facts=facts,
        ai_model_reference=MODEL_REFERENCE, status="open", created_by=user_id,
    )
    db.add(assessment)
    db.flush()
    write_event(db, farm_id=farm_id, entity_type=subject_type, entity_id=subject_id, event_type="emergency_assessment_started",
                payload={"assessment_id": assessment.id, "source": source, "signs": sorted(sign_map)}, created_by=user_id)

    candidates = []
    any_danger = []
    for v in versions:
        scoring = _score(v, sign_map)
        eligibility, outcomes = _eval_eligibility(v, facts)
        blocking = [o["message"] for o in outcomes if not o["passed"] and o["failure_action"] in ("BLOCK", "REQUIRE_VET")]
        warnings = [o["message"] for o in outcomes if not o["passed"] and o["failure_action"] == "WARN"]
        m = em.ProtocolMatch(
            id=new_id(), emergency_assessment_id=assessment.id, protocol_version_id=v.id, match_score=scoring["score"],
            match_explanation={"protocol_code": v.protocol.code, "protocol_title": v.protocol.title, "version_no": v.version_no, "minimum_match_confidence": v.minimum_match_confidence,
                               "supporting": scoring["matched"], "missing": scoring["unmatched"], "required_missing": scoring["required_missing"],
                               "danger_signs": scoring["danger_signs"], "eligibility": outcomes, "warnings": warnings, "facts_used": sorted(k for k in facts if facts[k] is not None)},
            eligibility_result=eligibility, blocking_reasons=blocking, selected=False, evaluated_at=at,
        )
        db.add(m)
        candidates.append((v, m, scoring))
        any_danger += [f"{v.protocol.code}: {d['detail']}" for d in scoring["danger_signs"]]
    db.flush()

    reasons: list[str] = []
    severe = any((s.get("severity") in SEVERE_OBSERVATION_SEVERITIES) for s in sign_map.values())
    best = None
    for v, m, scoring in sorted(candidates, key=lambda c: -(c[1].match_score or 0)):
        if m.match_score < v.minimum_match_confidence:
            continue
        if scoring["required_missing"]:
            reasons.append(f"{v.protocol.code}: required observation missing — " + ", ".join(e["code"] for e in scoring["required_missing"]))
            continue
        if m.eligibility_result in ("BLOCK", "REQUIRE_VET"):
            reasons.append(f"{v.protocol.code}: {'blocked' if m.eligibility_result == 'BLOCK' else 'requires the veterinarian'} — " + "; ".join(m.blocking_reasons))
            continue
        best = m
        break
    pattern = any((m.match_score or 0) > 0 for _, m, _ in candidates)
    if pattern:
        write_event(db, farm_id=farm_id, entity_type=subject_type, entity_id=subject_id, event_type="emergency_pattern_detected",
                    payload={"assessment_id": assessment.id, "candidates": [{"protocol": v.protocol.code, "score": m.match_score, "eligibility": m.eligibility_result} for v, m, _ in candidates]},
                    created_by=user_id)

    if any_danger:
        triage = "CRITICAL"
        reasons = [f"danger sign — {d}" for d in any_danger] + reasons
    elif best is not None:
        triage = "HIGH" if (severe or (best.match_score or 0) >= 0.8) else "MODERATE"
    elif pattern:
        triage = "HIGH" if severe else "MODERATE"
    else:
        triage = "HIGH" if severe else "LOW"
    assessment.triage_level = triage
    assessment.ai_confidence = max((m.match_score or 0) for _, m, _ in candidates) if candidates else 0.0

    if any_danger or best is None:
        if not candidates:
            reasons.append("no current veterinarian-approved protocol exists for this species / subject")
        elif best is None and not reasons:
            reasons.append("no approved protocol matched above its confidence threshold — " + "; ".join(f"{v.protocol.code} {m.match_score:.2f} < {v.minimum_match_confidence:.2f}" for v, m, _ in candidates))
        _escalate_assessment(db, assessment, subject_type, subject, reasons, user_id=user_id)
    else:
        best.selected = True
        assessment.status = "open"
        v = get_version(db, best.protocol_version_id, farm_id)
        warn = best.match_explanation.get("warnings") or []
        assessment.explanation = (
            f"{getattr(subject, 'name', subject_id)}: {v.protocol.title} (v{v.version_no}, approved {v.approved_at:%Y-%m-%d}, ref {v.approval_reference}) matched at "
            f"{best.match_score:.2f} ≥ {v.minimum_match_confidence:.2f}. Supported by: " + "; ".join(e["detail"] for e in best.match_explanation["supporting"])
            + (". Not reported: " + "; ".join(e["code"] for e in best.match_explanation["missing"]) if best.match_explanation["missing"] else "")
            + (". Warnings: " + "; ".join(warn) if warn else "") + ". Confirm to start the protocol; a person decides."
        )
        write_event(db, farm_id=farm_id, entity_type=subject_type, entity_id=subject_id, event_type="emergency_protocol_matched",
                    payload={"assessment_id": assessment.id, "match_id": best.id, "protocol": v.protocol.code, "version_no": v.version_no, "score": best.match_score,
                             "eligibility": best.eligibility_result, "triage": triage}, created_by=user_id)
    if notes:
        assessment.explanation = (assessment.explanation + f" Notes: {notes}").strip()
    return assessment


def _escalate_assessment(db: Session, assessment: em.EmergencyAssessment, subject_type: str, subject, reasons: list[str], *, user_id: str) -> None:
    """Escalate rather than improvise (§13): the user is told, visibly,
    to contact the veterinarian / manager; a task carries it."""
    assessment.status = "escalated"
    assessment.escalation_reasons = reasons
    name = getattr(subject, "name", assessment.animal_id or assessment.animal_group_id)
    assessment.explanation = (f"{name}: ESCALATE — contact the veterinarian / manager now. " + " | ".join(reasons)
                              + ". No drug, dose or route is shown because no current approved protocol applies.")
    task = models.Task(id=new_id(), farm_id=assessment.farm_id, title=f"EMERGENCY: {name} — call the veterinarian", description=assessment.explanation[:1500],
                       due_at=now(), priority="high", status="open", source_type=ESCALATION_TASK, source_id=assessment.id)
    db.add(task)
    db.flush()
    write_event(db, farm_id=assessment.farm_id, entity_type=subject_type, entity_id=subject.id, event_type="emergency_protocol_blocked" if any("blocked" in r or "requires" in r for r in reasons) else "emergency_escalated",
                payload={"assessment_id": assessment.id, "reasons": reasons, "task_id": task.id, "triage": assessment.triage_level}, created_by=user_id)


def on_observation(db: Session, observation: models.Observation, *, user_id: str) -> em.EmergencyAssessment | None:
    """A severe observation starts triage by itself (§12, acceptance 1),
    unless one is already open for the subject."""
    if observation.severity not in SEVERE_OBSERVATION_SEVERITIES:
        return None
    subject_type = "animal" if observation.entity_type == "animal" else ("group" if observation.entity_type in ("flock", "group") else None)
    if subject_type is None:
        return None
    col = em.EmergencyAssessment.animal_id if subject_type == "animal" else em.EmergencyAssessment.animal_group_id
    # An open, running or already-escalated case in the window is the case;
    # a second severe observation adds to it rather than opening a twin.
    recent = db.scalar(select(em.EmergencyAssessment).where(col == observation.entity_id, em.EmergencyAssessment.status.in_(("open", "protocol_started", "escalated")),
                                                            em.EmergencyAssessment.started_at >= now() - timedelta(hours=DUPLICATE_WINDOW_HOURS)))
    if recent is not None:
        return None
    try:
        return assess(db, observation.farm_id, subject_type=subject_type, subject_id=observation.entity_id, signs=[], source="observation_hook", user_id=user_id)
    except EmergencyError:
        return None


# -------------------------------------------------------------------- run
def start_run(db: Session, assessment: em.EmergencyAssessment, *, match_id: str | None = None, confirmed: bool = True, user_id: str, device_id: str | None = None) -> em.EmergencyProtocolRun:
    if assessment.status != "open":
        raise EmergencyError(f"This assessment is {assessment.status}; a protocol can only start from an open, matched assessment.")
    match = next((m for m in assessment.matches if (m.id == match_id if match_id else m.selected)), None)
    if match is None:
        raise EmergencyError("No selected protocol match on this assessment.", 404)
    if match.eligibility_result in ("BLOCK", "REQUIRE_VET"):
        raise EmergencyError("This protocol is blocked for the animal or requires the veterinarian; it cannot be started.")
    version = get_version(db, match.protocol_version_id, assessment.farm_id)
    if not version_is_current(version):
        _escalate_assessment(db, assessment, "animal" if assessment.animal_id else "group",
                             _subject(db, "animal" if assessment.animal_id else "group", assessment.animal_id or assessment.animal_group_id, assessment.farm_id),
                             [f"{version.protocol.code} v{version.version_no} is no longer current (expired or withdrawn)"], user_id=user_id)
        raise EmergencyError("The matched protocol version is no longer current; the case has been escalated.")
    if version.requires_pre_action_confirmation and not confirmed:
        raise EmergencyError("This protocol requires the person at the animal to confirm before any action.")
    at = now()
    run = em.EmergencyProtocolRun(
        id=new_id(), farm_id=assessment.farm_id, emergency_assessment_id=assessment.id, protocol_version_id=version.id, animal_id=assessment.animal_id,
        animal_group_id=assessment.animal_group_id, started_at=at, started_by=user_id, status="in_progress", device_id=device_id,
    )
    for i, s in enumerate(version.steps):
        run.steps.append(em.ProtocolRunStep(id=new_id(), protocol_step_id=s.id, sequence=i, status="pending",
                                            due_at=at + timedelta(minutes=s.timing_offset_minutes) if s.timing_offset_minutes else None))
    reassess_steps = [s for s in version.steps if s.step_type == "REASSESS" and s.timing_offset_minutes]
    if version.reassessment_minutes:
        run.next_reassessment_at = at + timedelta(minutes=version.reassessment_minutes)
    elif reassess_steps:
        run.next_reassessment_at = at + timedelta(minutes=reassess_steps[0].timing_offset_minutes)
    db.add(run)
    assessment.status = "protocol_started"
    db.flush()
    subject_type = "animal" if run.animal_id else "group"
    subject_id = run.animal_id or run.animal_group_id
    subject = _subject(db, subject_type, subject_id, run.farm_id)
    write_event(db, farm_id=run.farm_id, entity_type=subject_type, entity_id=subject_id, event_type="emergency_protocol_started",
                payload={"run_id": run.id, "assessment_id": assessment.id, "protocol": version.protocol.code, "version_no": version.version_no, "steps": len(version.steps)}, created_by=user_id)
    _notify(db, run, version, subject, user_id=user_id)
    return run


def _notify(db: Session, run: em.EmergencyProtocolRun, version: em.EmergencyProtocolVersion, subject, *, user_id: str) -> None:
    """Manager / veterinarian notification as the version requires
    (acceptance 5): a task each, and the timestamps on the run."""
    name = getattr(subject, "name", "")
    at = now()
    subject_type = "animal" if run.animal_id else "group"
    for flag, who, field, event in (
        (version.requires_manager_notification, "manager", "manager_notified_at", "emergency_manager_notified"),
        (version.requires_vet_notification, "veterinarian", "veterinarian_notified_at", "emergency_veterinarian_notified"),
    ):
        if not flag:
            continue
        db.add(models.Task(id=new_id(), farm_id=run.farm_id, title=f"Emergency protocol started: {name} — {version.protocol.title} ({who})",
                           description=f"{version.protocol.code} v{version.version_no} started at {at:%H:%M} by the person at the animal. Review the case.",
                           due_at=at, priority="high", status="open", source_type=NOTIFY_TASK, source_id=run.id))
        setattr(run, field, at)
        write_event(db, farm_id=run.farm_id, entity_type=subject_type, entity_id=run.animal_id or run.animal_group_id, event_type=event,
                    payload={"run_id": run.id, "protocol": version.protocol.code}, created_by=user_id)
    db.flush()


def _run_subject(db: Session, run: em.EmergencyProtocolRun):
    subject_type = "animal" if run.animal_id else "group"
    return subject_type, _subject(db, subject_type, run.animal_id or run.animal_group_id, run.farm_id)


def _step_of(db: Session, run: em.EmergencyProtocolRun, run_step_id: str) -> em.ProtocolRunStep:
    s = next((s for s in run.steps if s.id == run_step_id), None)
    if s is None:
        raise EmergencyError("Step not found on this run", 404)
    return s


def prepare_step(db: Session, run: em.EmergencyProtocolRun, run_step_id: str, *, weight_kg: float | None = None, head_count: int | None = None, user_id: str) -> em.ProtocolRunStep:
    """Presents a step. For a medication step: the approved dose from the
    approved rule and the animal's authoritative weight, inside the
    approved limits, with the exact eligible lot it would come from
    (acceptance 2–4). Anything else escalates."""
    if run.status not in ("in_progress", "awaiting_reassessment"):
        raise EmergencyError(f"This run is {run.status}.")
    rs = _step_of(db, run, run_step_id)
    if rs.status in ("completed", "skipped"):
        raise EmergencyError("This step is already done.")
    step = rs.step
    subject_type, subject = _run_subject(db, run)
    payload: dict = {"step_type": step.step_type, "title": step.title, "instructions": step.instructions}
    if step.step_type == "MEDICATION":
        med = step.medication
        product = ph.get_product(db, med.medicine_product_id, run.farm_id)
        item = ph.item_of(db, product)
        heads = head_count if head_count is not None else (1 if subject_type == "animal" else max(1, int(getattr(subject, "count", 1) or 1)))
        problems: list[str] = []
        if med.dose_rule_type == "FIXED":
            dose = med.fixed_dose_quantity
            weight_used, weight_source = None, None
        else:
            weight_used = weight_kg if weight_kg is not None else getattr(subject, "weight_kg", None)
            weight_source = "entered now" if weight_kg is not None else ("animal record" if weight_used is not None else None)
            if weight_used is None:
                problems.append("weight unknown — a per-weight dose cannot be calculated")
                dose = None
            else:
                dose = round(med.dose_per_weight_quantity * weight_used, 3)
        if dose is not None:
            if med.minimum_dose_quantity is not None and dose < med.minimum_dose_quantity:
                problems.append(f"calculated dose {dose:g} {med.dose_unit} is below the approved minimum {med.minimum_dose_quantity:g}")
            if med.maximum_dose_quantity is not None and dose > med.maximum_dose_quantity:
                problems.append(f"calculated dose {dose:g} {med.dose_unit} exceeds the approved maximum {med.maximum_dose_quantity:g}")
        prior = [s for s in run.steps if s.protocol_step_id == step.id and s.status == "completed" and s.medication_administration_id]
        if med.maximum_administrations is not None and len(prior) >= med.maximum_administrations:
            problems.append(f"the approved maximum of {med.maximum_administrations} administration(s) is reached")
        if prior and med.repeat_interval_minutes:
            last = max(ensure_utc(s.completed_at) for s in prior)
            if now() < last + timedelta(minutes=med.repeat_interval_minutes):
                problems.append(f"the repeat interval of {med.repeat_interval_minutes} min has not passed")
        lot, needed = None, None
        if dose is not None and not problems:
            needed = round(ph.uom.convert(dose * heads, med.dose_unit, item.unit), 6) if ph.uom.compatible(med.dose_unit, item.unit) else None
            if needed is None:
                problems.append(f"dose unit {med.dose_unit} cannot be converted to the stock unit {item.unit}")
            else:
                lot = next((l for l in ph.eligible_lots(db, product) if l.quantity_on_hand + 0.0005 >= needed), None)
                if lot is None:
                    bd = ph.stock_breakdown(db, product)
                    problems.append(f"{item.name}: no eligible lot holds {needed:g} {item.unit} (eligible {bd['eligible']:g}; on hand {bd['on_hand']:g}, "
                                    f"expired {bd['expired']:g}, quarantined {bd['quarantined']:g}, storage exception {bd['storage_exception']:g})")
        payload.update({
            "medicine_product_id": product.inventory_item_id, "medicine_name": item.name, "route_code": med.route_code, "dose_rule_type": med.dose_rule_type,
            "dose_quantity": dose, "dose_unit": med.dose_unit, "weight_used_kg": weight_used, "weight_source": weight_source, "head_count": heads,
            "quantity_consumed": needed, "stock_unit": item.unit, "lot_id": lot.id if lot else None, "lot_code": lot.lot_code if lot else None,
            "lot_expiry": lot.expiry_date.isoformat() if lot and lot.expiry_date else None, "approved_min": med.minimum_dose_quantity, "approved_max": med.maximum_dose_quantity,
            "withdrawal_rule": med.withdrawal_rule_payload or product.withdrawal_rules_json, "problems": problems,
            "source": f"{run.steps[0].run.protocol_version_id}" if False else "approved protocol parameters",
        })
        if problems:
            rs.status = "blocked"
            rs.result_payload = payload
            escalate_run(db, run, reason="medication step blocked: " + "; ".join(problems), user_id=user_id)
            return rs
        write_event(db, farm_id=run.farm_id, entity_type=subject_type, entity_id=subject.id, event_type="protocol_medication_prepared",
                    payload={"run_id": run.id, "run_step_id": rs.id, "medicine": item.name, "dose": dose, "dose_unit": med.dose_unit, "lot_code": lot.lot_code, "weight_used_kg": weight_used},
                    created_by=user_id)
    rs.status = "presented"
    rs.presented_at = now()
    rs.result_payload = payload
    return rs


def confirm_step(db: Session, run: em.EmergencyProtocolRun, run_step_id: str, *, weight_kg: float | None = None, head_count: int | None = None,
                 lot_id: str | None = None, result: dict | None = None, notes: str | None = None, user_id: str) -> em.ProtocolRunStep:
    """The person confirms the actual action (acceptance 6). A medication
    step records a prescription-provenance treatment and consumes the
    exact lot through the pharmacy; the other step types complete with
    their result. REASSESS schedules; ESCALATE escalates."""
    if run.status not in ("in_progress", "awaiting_reassessment"):
        raise EmergencyError(f"This run is {run.status}.")
    rs = _step_of(db, run, run_step_id)
    if rs.status in ("completed", "skipped"):
        raise EmergencyError("This step is already done.")
    step = rs.step
    subject_type, subject = _run_subject(db, run)
    version = get_version(db, run.protocol_version_id, run.farm_id)
    if not version_is_current(version):
        escalate_run(db, run, reason=f"{version.protocol.code} v{version.version_no} is no longer current", user_id=user_id)
        raise EmergencyError("The protocol version is no longer current; the case has been escalated.")
    at = now()
    if step.step_type == "MEDICATION":
        if rs.status != "presented" or weight_kg is not None or head_count is not None or (rs.result_payload or {}).get("lot_id") is None:
            prepare_step(db, run, run_step_id, weight_kg=weight_kg, head_count=head_count, user_id=user_id)
            if rs.status == "blocked":
                raise EmergencyError("The medication step is blocked: " + "; ".join(rs.result_payload.get("problems", [])) + ". The case has been escalated.")
        p = rs.result_payload
        product = ph.get_product(db, p["medicine_product_id"], run.farm_id)
        item = ph.item_of(db, product)
        treatment_id = next((s.result_payload.get("treatment_id") for s in run.steps if s.result_payload and s.result_payload.get("treatment_id") and s.result_payload.get("medicine_product_id") == product.inventory_item_id), None)
        if treatment_id is None:
            t = models.Treatment(
                id=new_id(), entity_type="animal" if subject_type == "animal" else "flock", entity_id=subject.id,
                diagnosis=f"Emergency protocol {version.protocol.code} v{version.version_no} — {version.protocol.title}",
                medication=f"{item.name} ({version.protocol.code} v{version.version_no} step {step.step_no})",
                dose=f"{p['dose_quantity']:g} {p['dose_unit']}" + (f" per head × {p['head_count']}" if p["head_count"] > 1 else ""), route=p["route_code"], start_at=at,
                vet_id=version.approved_by_veterinarian_id, responsible_user_id=user_id, status="active",
                notes=f"Prescription provenance: veterinarian-approved protocol (approval ref {version.approval_reference}). Dose rule {p['dose_rule_type']}, weight {p.get('weight_used_kg')} kg.",
            )
            db.add(t)
            db.flush()
            treatment_id = t.id
        adm = ph.administer(
            db, run.farm_id, subject_type=subject_type, subject_id=subject.id, inventory_item_id=product.inventory_item_id, lot_id=lot_id or p["lot_id"],
            dose_quantity=p["dose_quantity"], dose_unit=p["dose_unit"], route_code=p["route_code"], head_count=p["head_count"], treatment_id=treatment_id,
            protocol_run_step_id=rs.id, administered_at=at, reason=f"Protocol {version.protocol.code} v{version.version_no} step {step.step_no}: {step.title}", notes=notes, user_id=user_id,
        )
        rs.medication_administration_id = adm.id
        rs.result_payload = {**p, "treatment_id": treatment_id, "administration_id": adm.id, "lot_id": adm.inventory_lot_id, "withdrawal_milk_until": adm.withdrawal_milk_until.isoformat() if adm.withdrawal_milk_until else None,
                             "withdrawal_meat_until": adm.withdrawal_meat_until.isoformat() if adm.withdrawal_meat_until else None, **(result or {})}
    else:
        rs.result_payload = {**(rs.result_payload or {}), **(result or {}), "step_type": step.step_type}
        if step.step_type == "REASSESS":
            minutes = step.timing_offset_minutes or version.reassessment_minutes or 60
            run.status = "awaiting_reassessment"
            run.next_reassessment_at = at + timedelta(minutes=minutes)
            write_event(db, farm_id=run.farm_id, entity_type=subject_type, entity_id=subject.id, event_type="emergency_reassessment_due",
                        payload={"run_id": run.id, "due_at": run.next_reassessment_at.isoformat()}, created_by=user_id)
        elif step.step_type == "NOTIFY":
            _notify(db, run, version, subject, user_id=user_id)
    rs.status = "completed"
    rs.confirmed_at = at
    rs.confirmed_by = user_id
    rs.completed_at = at
    if notes:
        rs.result_payload = {**rs.result_payload, "notes": notes}
    write_event(db, farm_id=run.farm_id, entity_type=subject_type, entity_id=subject.id, event_type="protocol_step_completed",
                payload={"run_id": run.id, "run_step_id": rs.id, "step_no": step.step_no, "step_type": step.step_type, "administration_id": rs.medication_administration_id}, created_by=user_id)
    if step.step_type == "ESCALATE":
        escalate_run(db, run, reason=f"protocol step {step.step_no}: {step.title}", user_id=user_id)
    else:
        _maybe_complete(db, run, user_id=user_id)
    return rs


def skip_step(db: Session, run: em.EmergencyProtocolRun, run_step_id: str, *, reason: str, user_id: str) -> em.ProtocolRunStep:
    rs = _step_of(db, run, run_step_id)
    if rs.step.required:
        raise EmergencyError(f"Step {rs.step.step_no} is required by the approved protocol and cannot be skipped. Escalate instead.")
    if not reason or not reason.strip():
        raise EmergencyError("Say why the step is skipped.")
    rs.status = "skipped"
    rs.skip_reason = reason.strip()
    rs.completed_at = now()
    _maybe_complete(db, run, user_id=user_id)
    return rs


def _maybe_complete(db: Session, run: em.EmergencyProtocolRun, *, user_id: str) -> None:
    if run.status != "in_progress":
        return
    if all(s.status in ("completed", "skipped") for s in run.steps):
        resolve_run(db, run, outcome="all protocol steps completed", user_id=user_id)


def reassess_run(db: Session, run: em.EmergencyProtocolRun, *, signs: list, notes: str | None = None, user_id: str) -> tuple[em.EmergencyAssessment, em.EmergencyProtocolRun]:
    """Response at reassessment (acceptance 7): the same version re-scored
    on the new signs. A danger sign or no improvement escalates; an
    improvement continues the approved steps or resolves the case."""
    if run.status not in ("in_progress", "awaiting_reassessment"):
        raise EmergencyError(f"This run is {run.status}.")
    version = get_version(db, run.protocol_version_id, run.farm_id)
    subject_type, subject = _run_subject(db, run)
    initial = get_assessment(db, run.emergency_assessment_id, run.farm_id)
    before = next((m.match_score for m in initial.matches if m.protocol_version_id == version.id), None) or 0
    follow = assess(db, run.farm_id, subject_type=subject_type, subject_id=subject.id, signs=signs, source="reassessment", notes=notes, parent_run_id=run.id, only_version=version, user_id=user_id)
    after = next((m.match_score for m in follow.matches if m.protocol_version_id == version.id), None) or 0
    danger = any(m.match_explanation.get("danger_signs") for m in follow.matches)
    follow.status = "closed"
    follow.closed_at = now()
    # The follow-up is evidence for the run, not a second case: close its own
    # escalation task if the triage opened one, and let the run decide.
    for t in db.scalars(select(models.Task).where(models.Task.source_type == ESCALATION_TASK, models.Task.source_id == follow.id)):
        t.status = "done"
    if danger:
        escalate_run(db, run, reason="danger sign at reassessment: " + "; ".join(d["detail"] for m in follow.matches for d in m.match_explanation.get("danger_signs", [])), user_id=user_id)
    elif after >= before and after > 0:
        escalate_run(db, run, reason=f"no improvement at reassessment (match score {after:.2f} vs {before:.2f} at the start)", user_id=user_id)
    else:
        run.status = "in_progress"
        run.next_reassessment_at = None
        follow.explanation = f"Reassessment: match score {after:.2f} (was {before:.2f}) — improving. " + (follow.explanation or "")
        write_event(db, farm_id=run.farm_id, entity_type=subject_type, entity_id=subject.id, event_type="emergency_reassessed",
                    payload={"run_id": run.id, "assessment_id": follow.id, "score_before": before, "score_after": after, "outcome": "improving"}, created_by=user_id)
        _maybe_complete(db, run, user_id=user_id)
    return follow, run


def escalate_run(db: Session, run: em.EmergencyProtocolRun, *, reason: str, user_id: str) -> em.EmergencyProtocolRun:
    if run.status in ("escalated", "completed", "cancelled"):
        return run
    subject_type, subject = _run_subject(db, run)
    run.status = "escalated"
    run.escalated_at = now()
    run.escalation_reason = reason
    assessment = get_assessment(db, run.emergency_assessment_id, run.farm_id)
    assessment.status = "escalated"
    assessment.escalation_reasons = [*(assessment.escalation_reasons or []), reason]
    name = getattr(subject, "name", "")
    db.add(models.Task(id=new_id(), farm_id=run.farm_id, title=f"EMERGENCY: {name} — call the veterinarian", description=f"Protocol run escalated: {reason}"[:1500],
                       due_at=now(), priority="high", status="open", source_type=ESCALATION_TASK, source_id=run.id))
    db.flush()
    write_event(db, farm_id=run.farm_id, entity_type=subject_type, entity_id=subject.id, event_type="emergency_escalated",
                payload={"run_id": run.id, "assessment_id": run.emergency_assessment_id, "reason": reason}, created_by=user_id)
    return run


def resolve_run(db: Session, run: em.EmergencyProtocolRun, *, outcome: str, user_id: str) -> em.EmergencyProtocolRun:
    if run.status in ("completed", "cancelled"):
        return run
    if not outcome or not outcome.strip():
        raise EmergencyError("Say how the case resolved.")
    subject_type, subject = _run_subject(db, run)
    run.status = "completed"
    run.completed_at = now()
    run.outcome = outcome.strip()
    assessment = get_assessment(db, run.emergency_assessment_id, run.farm_id)
    assessment.status = "resolved"
    assessment.closed_at = now()
    for t in db.scalars(select(models.Task).where(models.Task.source_type.in_((ESCALATION_TASK, NOTIFY_TASK)), models.Task.source_id.in_((run.id, assessment.id)), models.Task.status == "open")):
        t.status = "done"
    write_event(db, farm_id=run.farm_id, entity_type=subject_type, entity_id=subject.id, event_type="emergency_resolved",
                payload={"run_id": run.id, "assessment_id": assessment.id, "outcome": outcome}, created_by=user_id)
    return run


def close_assessment(db: Session, assessment: em.EmergencyAssessment, *, outcome: str, user_id: str) -> em.EmergencyAssessment:
    """Closes an escalated or open assessment once the vet / manager has
    dealt with it, with the outcome on record."""
    if assessment.status in ("resolved", "closed"):
        return assessment
    if not outcome or not outcome.strip():
        raise EmergencyError("Say how the case was resolved.")
    assessment.status = "resolved"
    assessment.closed_at = now()
    assessment.explanation = (assessment.explanation + f" Outcome: {outcome.strip()}").strip()
    for t in db.scalars(select(models.Task).where(models.Task.source_type == ESCALATION_TASK, models.Task.source_id == assessment.id, models.Task.status == "open")):
        t.status = "done"
    subject_type = "animal" if assessment.animal_id else "group"
    write_event(db, farm_id=assessment.farm_id, entity_type=subject_type, entity_id=assessment.animal_id or assessment.animal_group_id, event_type="emergency_resolved",
                payload={"assessment_id": assessment.id, "outcome": outcome}, created_by=user_id)
    return assessment


# ---------------------------------------------------------------- offline
def offline_package(db: Session, farm_id: str) -> dict:
    """Only versions marked offline-eligible travel to the tablet (§14),
    with their rules, steps and medicine mapping, signed by content so a
    stale or altered package is detectable when it syncs."""
    versions = [version_dict(db, v) for v in current_versions(db, farm_id) if v.offline_eligible]
    body = json.dumps(versions, sort_keys=True, default=str)
    return {"generated_at": now(), "farm_id": farm_id, "model_reference": MODEL_REFERENCE, "model_version": MODEL_VERSION,
            "signature": hashlib.sha256(body.encode("utf-8")).hexdigest(), "versions": versions, "sign_codes": sign_codes(db, farm_id)}


def sign_codes(db: Session, farm_id: str) -> list[dict]:
    known = {s["code"]: dict(s) for s in STANDARD_SIGNS}
    for v in current_versions(db, farm_id):
        for r in v.trigger_rules:
            code = _normalise_code(r.observation_code)
            if code not in known:
                kind = "numeric" if r.operator in (">=", ">", "<=", "<") else ("categorical" if r.expected_value_code else "boolean")
                known[code] = {"code": code, "kind": kind, "unit": r.threshold_unit, "label": r.label or code.replace("_", " ")}
            elif r.expected_value_code and r.expected_value_code.lower() not in known[code].get("options", []):
                known[code].setdefault("options", []).append(r.expected_value_code.lower())
    return list(known.values())


# ------------------------------------------------------------------ views
def _user_name(db: Session, user_id: str | None) -> str | None:
    u = db.get(models.User, user_id) if user_id else None
    return u.name if u else None


def step_dict(db: Session, s: em.ProtocolStep) -> dict:
    med = s.medication
    out = {"id": s.id, "step_no": s.step_no, "step_type": s.step_type, "title": s.title, "instructions": s.instructions, "required": s.required,
           "requires_confirmation": s.requires_confirmation, "timing_offset_minutes": s.timing_offset_minutes, "medication": None}
    if med is not None:
        item = db.get(models.InventoryItem, med.medicine_product_id)
        out["medication"] = {"medicine_product_id": med.medicine_product_id, "medicine_name": item.name if item else None, "route_code": med.route_code,
                             "dose_rule_type": med.dose_rule_type, "fixed_dose_quantity": med.fixed_dose_quantity, "dose_per_weight_quantity": med.dose_per_weight_quantity,
                             "dose_unit": med.dose_unit, "weight_unit": med.weight_unit, "minimum_dose_quantity": med.minimum_dose_quantity, "maximum_dose_quantity": med.maximum_dose_quantity,
                             "repeat_interval_minutes": med.repeat_interval_minutes, "maximum_administrations": med.maximum_administrations, "withdrawal_rule_payload": med.withdrawal_rule_payload}
    return out


def version_dict(db: Session, v: em.EmergencyProtocolVersion) -> dict:
    return {
        "id": v.id, "protocol_id": v.emergency_protocol_id, "protocol_code": v.protocol.code, "protocol_title": v.protocol.title, "version_no": v.version_no,
        "status": v.status, "current": version_is_current(v), "effective_from": v.effective_from, "effective_to": v.effective_to, "protocol_text": v.protocol_text,
        "minimum_match_confidence": v.minimum_match_confidence, "requires_manager_notification": v.requires_manager_notification, "requires_vet_notification": v.requires_vet_notification,
        "requires_pre_action_confirmation": v.requires_pre_action_confirmation, "offline_eligible": v.offline_eligible, "reassessment_minutes": v.reassessment_minutes,
        "approved_by_veterinarian_id": v.approved_by_veterinarian_id, "approved_by_name": _user_name(db, v.approved_by_veterinarian_id), "approved_at": v.approved_at,
        "approval_reference": v.approval_reference, "withdrawn_reason": v.withdrawn_reason, "created_at": v.created_at,
        "trigger_rules": [{"id": r.id, "observation_code": r.observation_code, "operator": r.operator, "threshold_numeric": r.threshold_numeric, "threshold_unit": r.threshold_unit,
                           "expected_value_code": r.expected_value_code, "required": r.required, "weight": r.weight, "danger_sign": r.danger_sign, "label": r.label} for r in v.trigger_rules],
        "eligibility_rules": [{"id": r.id, "rule_type": r.rule_type, "operator": r.operator, "rule_payload": r.rule_payload, "failure_action": r.failure_action, "message": r.message} for r in v.eligibility_rules],
        "steps": [step_dict(db, s) for s in v.steps],
    }


def protocol_dict(db: Session, p: em.EmergencyProtocol, *, with_versions: bool = True) -> dict:
    current = db.get(em.EmergencyProtocolVersion, p.current_version_id) if p.current_version_id else None
    return {
        "id": p.id, "farm_id": p.farm_id, "code": p.code, "title": p.title, "condition_family_code": p.condition_family_code, "species_code": p.species_code,
        "subject_scope": p.subject_scope, "status": p.status, "current_version_id": p.current_version_id, "current_version_no": current.version_no if current else None,
        "created_at": p.created_at, "created_by": p.created_by,
        "current_version": version_dict(db, current) if current else None,
        "versions": [version_dict(db, v) for v in p.versions] if with_versions else None,
    }


def match_dict(db: Session, m: em.ProtocolMatch) -> dict:
    v = db.get(em.EmergencyProtocolVersion, m.protocol_version_id)
    return {"id": m.id, "protocol_version_id": m.protocol_version_id, "protocol_code": v.protocol.code if v else None, "protocol_title": v.protocol.title if v else None,
            "version_no": v.version_no if v else None, "match_score": m.match_score, "minimum_match_confidence": v.minimum_match_confidence if v else None,
            "eligibility_result": m.eligibility_result, "blocking_reasons": m.blocking_reasons, "selected": m.selected, "explanation": m.match_explanation, "evaluated_at": m.evaluated_at}


def assessment_dict(db: Session, a: em.EmergencyAssessment) -> dict:
    subject_type = "animal" if a.animal_id else "group"
    subject = db.get(models.Animal, a.animal_id) if a.animal_id else db.get(models.Flock, a.animal_group_id)
    run = db.scalar(select(em.EmergencyProtocolRun).where(em.EmergencyProtocolRun.emergency_assessment_id == a.id).order_by(em.EmergencyProtocolRun.started_at.desc()))
    task = db.scalar(select(models.Task).where(models.Task.source_type == ESCALATION_TASK, models.Task.source_id == a.id).order_by(models.Task.due_at.desc()))
    return {
        "id": a.id, "subject_type": subject_type, "subject_id": a.animal_id or a.animal_group_id, "subject_name": getattr(subject, "name", None), "species": getattr(subject, "species", None),
        "parent_run_id": a.parent_run_id, "started_at": a.started_at, "source": a.source, "observed_signs": a.observed_signs, "animal_facts": a.animal_facts, "triage_level": a.triage_level,
        "ai_model_reference": a.ai_model_reference, "ai_model_version": MODEL_VERSION, "ai_confidence": a.ai_confidence, "status": a.status, "escalation_reasons": a.escalation_reasons,
        "explanation": a.explanation, "created_by": a.created_by, "created_by_name": _user_name(db, a.created_by), "closed_at": a.closed_at,
        "matches": [match_dict(db, m) for m in a.matches], "selected_match_id": next((m.id for m in a.matches if m.selected), None),
        "run_id": run.id if run else None, "run_status": run.status if run else None, "escalation_task_id": task.id if task else None,
    }


def run_step_dict(db: Session, rs: em.ProtocolRunStep) -> dict:
    return {"id": rs.id, "sequence": rs.sequence, "status": rs.status, "due_at": rs.due_at, "presented_at": rs.presented_at, "confirmed_at": rs.confirmed_at,
            "confirmed_by": rs.confirmed_by, "confirmed_by_name": _user_name(db, rs.confirmed_by), "completed_at": rs.completed_at,
            "medication_administration_id": rs.medication_administration_id, "result": rs.result_payload or {}, "skip_reason": rs.skip_reason, "step": step_dict(db, rs.step)}


def run_dict(db: Session, r: em.EmergencyProtocolRun) -> dict:
    v = db.get(em.EmergencyProtocolVersion, r.protocol_version_id)
    subject = db.get(models.Animal, r.animal_id) if r.animal_id else db.get(models.Flock, r.animal_group_id)
    return {
        "id": r.id, "assessment_id": r.emergency_assessment_id, "protocol_version_id": r.protocol_version_id, "protocol_code": v.protocol.code if v else None,
        "protocol_title": v.protocol.title if v else None, "version_no": v.version_no if v else None, "approval_reference": v.approval_reference if v else None,
        "subject_type": "animal" if r.animal_id else "group", "subject_id": r.animal_id or r.animal_group_id, "subject_name": getattr(subject, "name", None),
        "started_at": r.started_at, "started_by": r.started_by, "started_by_name": _user_name(db, r.started_by), "status": r.status, "manager_notified_at": r.manager_notified_at,
        "veterinarian_notified_at": r.veterinarian_notified_at, "next_reassessment_at": r.next_reassessment_at,
        "reassessment_overdue": bool(r.next_reassessment_at and ensure_utc(r.next_reassessment_at) < now() and r.status == "awaiting_reassessment"),
        "escalated_at": r.escalated_at, "escalation_reason": r.escalation_reason, "completed_at": r.completed_at, "outcome": r.outcome,
        "steps": [run_step_dict(db, s) for s in r.steps], "next_step_id": next((s.id for s in r.steps if s.status in ("pending", "presented")), None),
    }


def summary(db: Session, farm_id: str) -> dict:
    protocols = db.scalars(select(em.EmergencyProtocol).where(em.EmergencyProtocol.farm_id == farm_id)).all()
    open_assessments = db.scalar(select(func.count(em.EmergencyAssessment.id)).where(em.EmergencyAssessment.farm_id == farm_id, em.EmergencyAssessment.status == "open")) or 0
    escalated = db.scalar(select(func.count(em.EmergencyAssessment.id)).where(em.EmergencyAssessment.farm_id == farm_id, em.EmergencyAssessment.status == "escalated")) or 0
    runs = db.scalars(select(em.EmergencyProtocolRun).where(em.EmergencyProtocolRun.farm_id == farm_id, em.EmergencyProtocolRun.status.in_(("in_progress", "awaiting_reassessment")))).all()
    return {"protocols": len(protocols), "active_protocols": sum(1 for p in protocols if p.status == "active"), "open_assessments": open_assessments, "escalated": escalated,
            "runs_in_progress": sum(1 for r in runs if r.status == "in_progress"), "awaiting_reassessment": sum(1 for r in runs if r.status == "awaiting_reassessment"),
            "reassessments_overdue": sum(1 for r in runs if r.next_reassessment_at and ensure_utc(r.next_reassessment_at) < now()),
            "model_reference": MODEL_REFERENCE, "model_version": MODEL_VERSION}


def emergency_signals(db: Session, farm_id: str) -> list:
    """Escalations and overdue reassessments reach the bell; a matched
    protocol awaiting confirmation does too, so the manager sees it."""
    from app.services.signals_service import Signal  # local import: signals imports this module

    out = []
    since = now() - timedelta(days=7)
    for a in db.scalars(select(em.EmergencyAssessment).where(em.EmergencyAssessment.farm_id == farm_id, em.EmergencyAssessment.status.in_(("escalated", "open")), em.EmergencyAssessment.started_at >= since)):
        subject = db.get(models.Animal, a.animal_id) if a.animal_id else db.get(models.Flock, a.animal_group_id)
        name = getattr(subject, "name", "")
        escalated = a.status == "escalated"
        out.append(Signal(source_type="emergency_assessment", source_id=a.id, module_code=perms.ANIMAL_HEALTH,
                          notification_type="emergency_escalated" if escalated else "emergency_protocol_matched",
                          title=(f"EMERGENCY: {name} — call the veterinarian" if escalated else f"{name}: protocol matched, awaiting confirmation"),
                          description=a.explanation[:300], priority="critical" if escalated else "high",
                          entity_type="animal" if a.animal_id else "flock", entity_id=a.animal_id or a.animal_group_id,
                          metadata={"assessment_id": a.id, "triage": a.triage_level, "confidence": a.ai_confidence}))
    for r in db.scalars(select(em.EmergencyProtocolRun).where(em.EmergencyProtocolRun.farm_id == farm_id, em.EmergencyProtocolRun.status == "awaiting_reassessment")):
        if r.next_reassessment_at and ensure_utc(r.next_reassessment_at) < now():
            subject = db.get(models.Animal, r.animal_id) if r.animal_id else db.get(models.Flock, r.animal_group_id)
            out.append(Signal(source_type="emergency_run", source_id=r.id, module_code=perms.ANIMAL_HEALTH, notification_type="emergency_reassessment_due",
                              title=f"{getattr(subject, 'name', '')}: reassessment overdue", description="The protocol's reassessment time has passed. Re-take the signs now.",
                              priority="high", entity_type="animal" if r.animal_id else "flock", entity_id=r.animal_id or r.animal_group_id, metadata={"run_id": r.id}))
    return out
