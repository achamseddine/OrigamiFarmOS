"""Demo emergency protocols for the Origami farm
(database/CLINICAL-DECISION-SUPPORT-EMERGENCY-PROTOCOLS.md).

Two veterinarian-approved protocols (bovine fever support, poultry heat
stress), one draft that is deliberately not operational (equine colic),
and two live cases: Bella's fever matches the bovine protocol and waits
for the person at the animal to confirm; Rasha the goat has no approved
protocol and is escalated to the veterinarian. The engine never shows a
drug for Rasha — there is nothing approved to show.
"""
from __future__ import annotations

from sqlalchemy.orm import Session

from app.domain import emergency_models as em
from app.domain import models
from app.services import emergency_service as es

MANAGER = "user-rami"
VET = "user-vet-1"
WORKER = "user-worker-1"


def seed_emergency_demo_data(db: Session, farm_id: str) -> None:
    if db.scalar(db.query(em.EmergencyProtocol.id).filter_by(farm_id=farm_id, code="BOVINE-FEVER-SUPPORT").statement) is not None:
        return
    vet = db.get(models.User, VET)

    bovine = es.create_protocol(
        db, farm_id, code="BOVINE-FEVER-SUPPORT", title="Bovine fever support", condition_family_code="FEVER", species_code="cow", subject_scope="animal", user_id=MANAGER,
        version={
            "protocol_text": "Farm protocol for an adult bovine with fever and reduced appetite, approved by the farm veterinarian. Supportive care, one anti-inflammatory dose by weight, "
                             "notification of the veterinarian, reassessment at two hours, escalation if not improving.",
            "minimum_match_confidence": 0.5, "requires_manager_notification": True, "requires_vet_notification": True, "requires_pre_action_confirmation": True,
            "offline_eligible": True, "reassessment_minutes": 120,
            "trigger_rules": [
                {"observation_code": "temperature_c", "operator": ">=", "threshold_numeric": 39.5, "threshold_unit": "°C", "weight": 0.5, "label": "Rectal temperature ≥ 39.5 °C"},
                {"observation_code": "fever", "operator": "present", "weight": 0.3, "label": "Fever observed"},
                {"observation_code": "appetite", "operator": "==", "expected_value_code": "reduced", "weight": 0.2, "label": "Appetite reduced"},
                {"observation_code": "rumination", "operator": "==", "expected_value_code": "reduced", "weight": 0.1, "label": "Rumination reduced"},
                {"observation_code": "temperature_c", "operator": ">=", "threshold_numeric": 41.5, "threshold_unit": "°C", "danger_sign": True, "label": "Temperature ≥ 41.5 °C"},
                {"observation_code": "recumbent", "operator": "present", "danger_sign": True, "label": "Down, cannot rise"},
                {"observation_code": "bloat", "operator": "present", "danger_sign": True, "label": "Bloat"},
            ],
            "eligibility_rules": [
                {"rule_type": "species", "rule_payload": {"in": ["cow"]}, "failure_action": "BLOCK", "message": "This protocol is written for cattle only"},
                {"rule_type": "pregnant", "rule_payload": {"value": False}, "failure_action": "WARN", "message": "Pregnant: the anti-inflammatory dose needs the veterinarian's note"},
                {"rule_type": "withdrawal_active", "rule_payload": {"value": False}, "failure_action": "WARN", "message": "Already under a withdrawal period — note it on the record"},
                {"rule_type": "weight_known", "rule_payload": {"value": True}, "failure_action": "WARN", "message": "No recorded weight: enter the weight before the dose"},
            ],
            "steps": [
                {"step_no": 1, "step_type": "ASSESS", "title": "Confirm temperature and hydration", "instructions": "Take the rectal temperature again, check the skin tent for dehydration and listen for rumination.", "required": True},
                {"step_no": 2, "step_type": "NON_DRUG_ACTION", "title": "Shade, water, separate", "instructions": "Move the animal to shade, offer fresh water and separate it from the herd.", "required": True},
                {"step_no": 3, "step_type": "MEDICATION", "title": "Flunixin meglumine by weight", "instructions": "One intramuscular dose of flunixin meglumine 50 mg/mL at 2.2 mg/kg (0.044 mL/kg). Not more than once in 24 hours, three doses at most.",
                 "required": True, "medication": {"medicine_product_id": "med-flunixin", "route_code": "IM", "dose_rule_type": "PER_WEIGHT", "dose_per_weight_quantity": 0.044, "dose_unit": "ml",
                                                   "weight_unit": "kg", "minimum_dose_quantity": 5, "maximum_dose_quantity": 30, "repeat_interval_minutes": 1440, "maximum_administrations": 3,
                                                   "withdrawal_rule_payload": {"milk_days": 1, "meat_days": 10}}},
                {"step_no": 4, "step_type": "NOTIFY", "title": "Tell the veterinarian", "instructions": "Send the veterinarian the temperature, the time of the dose and the animal's tag.", "required": True},
                {"step_no": 5, "step_type": "REASSESS", "title": "Reassess at two hours", "instructions": "Re-take the temperature and appetite. Expect the temperature to have fallen by at least 0.5 °C.", "required": True, "timing_offset_minutes": 120},
                {"step_no": 6, "step_type": "ESCALATE", "title": "Call the veterinarian now", "instructions": "If the temperature is 41 °C or more, or not falling at reassessment, call the veterinarian immediately.", "required": False},
            ],
        },
    )
    es.approve_version(db, bovine.versions[0], approver=vet, approval_reference="VET-2026-014")

    poultry = es.create_protocol(
        db, farm_id, code="POULTRY-HEAT-STRESS", title="Poultry heat stress support", condition_family_code="HEAT_STRESS", species_code=None, subject_scope="group", user_id=MANAGER,
        version={
            "protocol_text": "Flock-level heat stress: ventilation and water first, oral electrolytes in the drinking water, reassessment at one hour.",
            "minimum_match_confidence": 0.5, "requires_manager_notification": True, "requires_vet_notification": False, "requires_pre_action_confirmation": True,
            "offline_eligible": True, "reassessment_minutes": 60,
            "trigger_rules": [
                {"observation_code": "panting", "operator": "present", "weight": 0.5, "required": True, "label": "Open-mouth panting"},
                {"observation_code": "water_intake", "operator": "==", "expected_value_code": "reduced", "weight": 0.2, "label": "Water intake reduced"},
                {"observation_code": "ambient_temperature_c", "operator": ">=", "threshold_numeric": 32, "threshold_unit": "°C", "weight": 0.2, "label": "Ambient ≥ 32 °C"},
                {"observation_code": "mortality_count", "operator": ">=", "threshold_numeric": 3, "threshold_unit": "head", "weight": 0.1, "label": "Three or more dead today"},
                {"observation_code": "mortality_count", "operator": ">=", "threshold_numeric": 20, "threshold_unit": "head", "danger_sign": True, "label": "Twenty or more dead today"},
            ],
            "eligibility_rules": [
                {"rule_type": "species", "rule_payload": {"in": ["layer_hen", "broiler", "chicken", "duck", "turkey"]}, "failure_action": "BLOCK", "message": "This protocol is written for poultry flocks"},
                {"rule_type": "subject_type", "rule_payload": {"value": "group"}, "failure_action": "BLOCK", "message": "This protocol applies to a flock, not one bird"},
            ],
            "steps": [
                {"step_no": 1, "step_type": "ASSESS", "title": "Count and check water", "instructions": "Count the birds panting, check every water line and drinker is flowing.", "required": True},
                {"step_no": 2, "step_type": "NON_DRUG_ACTION", "title": "Ventilation and drinkers", "instructions": "Open vents, run the fans, add drinkers, stop any handling.", "required": True},
                {"step_no": 3, "step_type": "MEDICATION", "title": "Oral electrolytes in the water", "instructions": "One sachet of oral electrolyte per 10 litres of drinking water; enter the number of sachets used.",
                 "required": True, "medication": {"medicine_product_id": "med-electrolyte", "route_code": "PO", "dose_rule_type": "FIXED", "fixed_dose_quantity": 1, "dose_unit": "sachet",
                                                   "maximum_dose_quantity": 1, "repeat_interval_minutes": 240, "maximum_administrations": 4, "withdrawal_rule_payload": {}}},
                {"step_no": 4, "step_type": "REASSESS", "title": "Reassess at one hour", "instructions": "Count the birds still panting and any new deaths.", "required": True, "timing_offset_minutes": 60},
                {"step_no": 5, "step_type": "ESCALATE", "title": "Call the veterinarian", "instructions": "If deaths continue or panting does not ease, call the veterinarian.", "required": False},
            ],
        },
    )
    es.approve_version(db, poultry.versions[0], approver=vet, approval_reference="VET-2026-015")

    # A draft on purpose: not operational until the vet approves it.
    es.create_protocol(
        db, farm_id, code="EQUINE-COLIC-SUPPORT", title="Equine colic — first response", condition_family_code="COLIC", species_code="horse", subject_scope="animal", user_id=MANAGER,
        version={
            "protocol_text": "Draft: walk the horse, withhold feed, call the veterinarian. No medication until approved.", "minimum_match_confidence": 0.6, "offline_eligible": False,
            "trigger_rules": [
                {"observation_code": "colic_signs", "operator": "present", "weight": 0.6, "required": True, "label": "Pawing, rolling, looking at flank"},
                {"observation_code": "heart_rate", "operator": ">=", "threshold_numeric": 60, "threshold_unit": "bpm", "weight": 0.4, "label": "Heart rate ≥ 60"},
                {"observation_code": "heart_rate", "operator": ">=", "threshold_numeric": 80, "threshold_unit": "bpm", "danger_sign": True, "label": "Heart rate ≥ 80"},
            ],
            "eligibility_rules": [{"rule_type": "species", "rule_payload": {"in": ["horse"]}, "failure_action": "BLOCK", "message": "Horses only"}],
            "steps": [
                {"step_no": 1, "step_type": "ASSESS", "title": "Heart rate and gut sounds", "instructions": "Take the heart rate, listen to all four quadrants.", "required": True},
                {"step_no": 2, "step_type": "NOTIFY", "title": "Call the veterinarian", "instructions": "Call the veterinarian with the heart rate and the time the signs started.", "required": True},
                {"step_no": 3, "step_type": "ESCALATE", "title": "Escalate", "instructions": "Any worsening: escalate.", "required": False},
            ],
        },
    )

    # ------------------------------------------------------------ cases
    # Bella: fever observed this morning (seeded), temperature and appetite
    # from the worker → the bovine protocol matches and waits for confirmation.
    es.assess(db, farm_id, subject_type="animal", subject_id="cow-744", source="worker", user_id=WORKER,
              signs=[{"code": "temperature_c", "value_numeric": 40.2, "unit": "°C"}, {"code": "appetite", "value_text": "reduced"}])
    # Rasha the goat: same signs, no approved protocol for goats → escalated.
    es.assess(db, farm_id, subject_type="animal", subject_id="goat-189", source="worker", user_id=WORKER,
              signs=[{"code": "temperature_c", "value_numeric": 40.0, "unit": "°C"}, {"code": "appetite", "value_text": "reduced"}])
    db.flush()
