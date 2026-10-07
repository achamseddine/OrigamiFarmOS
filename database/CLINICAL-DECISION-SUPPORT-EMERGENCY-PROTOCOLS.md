# Clinical Decision Support & Emergency Protocol Engine

**Status:** Canonical implementation baseline  
**Depends on:** Livestock, Health/Veterinary, Medicine/Pharmacy, Inventory, Workflow/Notifications  
**Purpose:** Let Origami recognize urgent animal-health patterns and operationalize veterinarian-approved farm protocols at the point of care.

## 1. Principle
Origami AI is an active clinical decision-support and orchestration layer, not an autonomous veterinarian.

AI may recognize a pattern, rank urgency, match a current veterinarian-approved protocol, explain why it matched, calculate a dose when the approved protocol defines the formula, check animal-specific eligibility and medicine stock, present protocol actions, start reassessment/escalation workflows, and notify the manager/veterinarian.

AI must not invent a drug, route, dose, contraindication rule or withdrawal instruction outside an approved protocol/prescription. When no applicable approved protocol exists, confidence/required data are inadequate, a contraindication or danger rule fires, or protocol limits are exceeded, Origami escalates rather than improvises.

## 2. emergency_protocol
```sql
emergency_protocol (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 code varchar(100) not null,
 title varchar(200) not null,
 condition_family_code varchar(100) not null,
 species_id uuid references species(id),
 status varchar(30) not null,
 current_version_id uuid,
 created_at timestamptz not null,
 created_by uuid references user_account(id),
 unique (farm_id,code)
)
```

## 3. emergency_protocol_version
A version becomes operational only after required veterinary approval.
```sql
emergency_protocol_version (
 id uuid primary key,
 emergency_protocol_id uuid not null references emergency_protocol(id),
 version_no integer not null,
 effective_from timestamptz,
 effective_to timestamptz,
 protocol_text text,
 minimum_match_confidence numeric(6,5),
 requires_manager_notification boolean not null default true,
 requires_vet_notification boolean not null default true,
 requires_pre_action_confirmation boolean not null default true,
 offline_eligible boolean not null default false,
 status varchar(30) not null,
 approved_by_veterinarian_id uuid,
 approved_at timestamptz,
 approval_reference varchar(150),
 created_at timestamptz not null,
 unique (emergency_protocol_id,version_no)
)
```
Veterinarian identity/credential modeling can later be normalized; approval provenance must remain immutable.

## 4. protocol_trigger_rule
Structured signs and measurements used for deterministic/AI-assisted matching.
```sql
protocol_trigger_rule (
 id uuid primary key,
 protocol_version_id uuid not null references emergency_protocol_version(id),
 observation_code varchar(100) not null,
 operator varchar(20),
 threshold_numeric numeric(20,6),
 threshold_uom_id uuid references uom(id),
 expected_value_code varchar(100),
 required boolean not null default false,
 weight numeric(10,4),
 danger_sign boolean not null default false
)
```

## 5. protocol_eligibility_rule
Rules may consider species, sex, life stage, weight range, pregnancy/lactation state, active diagnoses, allergies/adverse reactions, current medications, withdrawal state and other authoritative animal facts.
```sql
protocol_eligibility_rule (
 id uuid primary key,
 protocol_version_id uuid not null references emergency_protocol_version(id),
 rule_type varchar(60) not null,
 operator varchar(20) not null,
 rule_payload jsonb not null,
 failure_action varchar(30) not null
)
```
Failure actions include BLOCK, REQUIRE_VET, WARN.

## 6. protocol_step
```sql
protocol_step (
 id uuid primary key,
 protocol_version_id uuid not null references emergency_protocol_version(id),
 step_no integer not null,
 step_type varchar(40) not null,
 title varchar(200) not null,
 instructions text not null,
 required boolean not null default true,
 requires_confirmation boolean not null default true,
 timing_offset_minutes integer,
 unique (protocol_version_id,step_no)
)
```
Types may include ASSESS, NON_DRUG_ACTION, MEDICATION, MEASUREMENT, NOTIFY, REASSESS, ESCALATE.

## 7. protocol_medication_step
A medication instruction must be explicitly approved within the protocol version.
```sql
protocol_medication_step (
 protocol_step_id uuid primary key references protocol_step(id),
 medicine_product_id uuid not null references medicine_product(inventory_item_id),
 route_code varchar(40) not null,
 dose_rule_type varchar(40) not null,
 fixed_dose_quantity numeric(20,6),
 dose_per_weight_quantity numeric(20,6),
 dose_uom_id uuid not null references uom(id),
 weight_uom_id uuid references uom(id),
 minimum_dose_quantity numeric(20,6),
 maximum_dose_quantity numeric(20,6),
 repeat_interval_minutes integer,
 maximum_administrations integer,
 withdrawal_rule_payload jsonb,
 check (
   (dose_rule_type='FIXED' and fixed_dose_quantity is not null)
   or
   (dose_rule_type='PER_WEIGHT' and dose_per_weight_quantity is not null and weight_uom_id is not null)
 )
)
```
The engine calculates only from these approved parameters. It does not generate novel dosing.

## 8. emergency_assessment
```sql
emergency_assessment (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 health_case_id uuid references health_case(id),
 started_at timestamptz not null,
 source varchar(30) not null,
 observed_signs jsonb not null,
 triage_level varchar(30) not null,
 ai_model_reference varchar(150),
 ai_confidence numeric(6,5),
 status varchar(30) not null,
 created_by uuid references user_account(id),
 check (num_nonnulls(animal_id,animal_group_id)=1)
)
```

## 9. protocol_match
```sql
protocol_match (
 id uuid primary key,
 emergency_assessment_id uuid not null references emergency_assessment(id),
 protocol_version_id uuid not null references emergency_protocol_version(id),
 match_score numeric(6,5),
 match_explanation jsonb not null,
 eligibility_result varchar(30) not null,
 blocking_reasons jsonb,
 selected boolean not null default false,
 evaluated_at timestamptz not null
)
```
The explanation must expose which observed/authoritative facts supported the match and what information is missing.

## 10. emergency_protocol_run
```sql
emergency_protocol_run (
 id uuid primary key,
 emergency_assessment_id uuid not null references emergency_assessment(id),
 protocol_version_id uuid not null references emergency_protocol_version(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 health_case_id uuid references health_case(id),
 started_at timestamptz not null,
 started_by uuid references user_account(id),
 status varchar(30) not null,
 manager_notified_at timestamptz,
 veterinarian_notified_at timestamptz,
 next_reassessment_at timestamptz,
 escalated_at timestamptz,
 escalation_reason text,
 check (num_nonnulls(animal_id,animal_group_id)=1)
)
```

## 11. protocol_run_step
```sql
protocol_run_step (
 id uuid primary key,
 protocol_run_id uuid not null references emergency_protocol_run(id),
 protocol_step_id uuid not null references protocol_step(id),
 status varchar(30) not null,
 due_at timestamptz,
 presented_at timestamptz,
 confirmed_at timestamptz,
 confirmed_by uuid references user_account(id),
 completed_at timestamptz,
 medication_administration_id uuid references medication_administration(id),
 result_payload jsonb
)
```

## 12. Runtime flow
```text
Worker selects animal / scans tag
 → records signs + measurements
 → emergency triage evaluates urgency
 → AI + deterministic rules match active approved protocols
 → load animal facts and contraindication/eligibility rules
 → BLOCK/ESCALATE if unsafe or outside protocol
 → show matched protocol + evidence + confidence
 → notify manager/vet according to policy
 → check medicine product + eligible lot/expiry/storage/stock
 → calculate approved fixed/per-weight dose
 → user confirms actual action
 → administration posts exact lot consumption + withdrawal
 → schedule reassessment
 → evaluate response
 → recover / continue approved steps / escalate
```

## 13. Emergency escalation
Immediate escalation occurs when:
- protocol marks a danger sign;
- required observation is missing and cannot safely be assumed;
- no current veterinarian-approved protocol matches;
- protocol is expired/withdrawn;
- animal fails an eligibility rule marked BLOCK/REQUIRE_VET;
- required medicine is unavailable or only ineligible stock exists;
- calculated dose is outside approved min/max;
- response at reassessment meets escalation criteria;
- AI confidence is below protocol threshold;
- offline data are too stale for a consequential decision.

Origami must visibly tell the user to contact the veterinarian/manager when escalation is required.

## 14. Offline
Only protocol versions explicitly marked offline_eligible may be cached. Cached package includes signed/versioned protocol rules, medicine mapping and required reference data. Offline execution records protocol/version, device, actor, occurrence time and operation IDs. Sync revalidates and never silently changes what was shown/administered.

## 15. Audit & explainability
For every AI-assisted emergency assessment retain:
- input observations;
- animal facts used;
- protocol candidates;
- selected version;
- model/reference where applicable;
- confidence;
- rule outcomes;
- contraindication/block reasons;
- exact instructions shown;
- confirmations;
- notifications;
- administrations;
- reassessments/outcome.

## 16. Events
EmergencyAssessmentStarted, EmergencyPatternDetected, EmergencyProtocolMatched, EmergencyProtocolBlocked, EmergencyProtocolStarted, EmergencyManagerNotified, EmergencyVeterinarianNotified, ProtocolMedicationPrepared, ProtocolStepCompleted, EmergencyReassessmentDue, EmergencyEscalated, EmergencyResolved.

## 17. Acceptance
1. AI can actively identify likely emergency patterns from worker observations.
2. A drug/dose/route is displayed only from a current applicable veterinarian-approved protocol/prescription.
3. Per-weight dose calculation uses authoritative/recent weight according to protocol rules and enforces min/max.
4. Medicine availability checks exact eligible pharmacy stock before an administration step.
5. Manager/veterinarian notification is generated as configured and escalation is explicit.
6. Actual administration requires recording/confirmation and consumes the exact lot.
7. Reassessment is scheduled and failure-to-improve can escalate.
8. Protocol/version and AI reasoning provenance remain auditable.
9. Offline execution cannot expand authority or use unapproved/stale protocols.
10. AI never converts its own unsupported guess into an authoritative prescription.
