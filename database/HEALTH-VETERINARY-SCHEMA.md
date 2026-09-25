# Database Pass 4B — Health, Veterinary & Welfare

**Status:** Canonical implementation baseline  
**Depends on:** Foundation, Livestock, Inventory  
**Future integration:** Laboratory, Compliance

## Boundary
Observation is not diagnosis. Diagnosis is not treatment. Treatment plan is not medication administration. Withdrawal restriction is not merely a note.

## health_case
```sql
health_case (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 case_code varchar(100) not null,
 opened_at timestamptz not null,
 closed_at timestamptz,
 status varchar(30) not null,
 severity_code varchar(30),
 primary_problem_code varchar(100),
 responsible_user_id uuid references user_account(id),
 created_at timestamptz not null,
 check (num_nonnulls(animal_id,animal_group_id)=1),
 unique (farm_id,case_code)
)
```

## health_observation
```sql
health_observation (
 id uuid primary key,
 health_case_id uuid references health_case(id),
 farm_id uuid not null references farm(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 observation_code varchar(100) not null,
 observed_at timestamptz not null,
 value_numeric numeric(20,6),
 value_text text,
 uom_id uuid references uom(id),
 severity_code varchar(30),
 recorded_by uuid references user_account(id),
 recorded_at timestamptz not null,
 check (num_nonnulls(animal_id,animal_group_id)=1)
)
```
Examples: temperature, diarrhea, salivation, lameness, appetite, lesion, cough. Recording these never automatically asserts a diagnosis.

## clinical_examination
```sql
clinical_examination (
 id uuid primary key,
 health_case_id uuid not null references health_case(id),
 examined_at timestamptz not null,
 examiner_user_id uuid references user_account(id),
 findings jsonb not null,
 notes text,
 recorded_at timestamptz not null
)
```

## diagnosis
```sql
diagnosis (
 id uuid primary key,
 health_case_id uuid not null references health_case(id),
 diagnosis_code varchar(120) not null,
 diagnosis_text varchar(250),
 certainty_code varchar(30) not null,
 diagnosed_at timestamptz not null,
 diagnosed_by uuid references user_account(id),
 status varchar(30) not null,
 supersedes_diagnosis_id uuid references diagnosis(id)
)
```
AI suggestions never insert confirmed diagnoses directly.

## treatment_plan / treatment_action
```sql
treatment_plan (
 id uuid primary key,
 health_case_id uuid not null references health_case(id),
 status varchar(30) not null,
 prescribed_at timestamptz not null,
 prescribed_by uuid references user_account(id),
 instructions text
)

treatment_action (
 id uuid primary key,
 treatment_plan_id uuid references treatment_plan(id),
 health_case_id uuid not null references health_case(id),
 action_type varchar(50) not null,
 scheduled_at timestamptz,
 performed_at timestamptz,
 performed_by uuid references user_account(id),
 status varchar(30) not null,
 notes text
)
```

## medication_administration
Medication product is a canonical inventory item; future pharmaceutical master metadata can extend it.
```sql
medication_administration (
 id uuid primary key,
 health_case_id uuid references health_case(id),
 treatment_action_id uuid references treatment_action(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 inventory_item_id uuid not null references inventory_item(id),
 inventory_lot_id uuid references inventory_lot(id),
 dose_quantity numeric(20,6) not null,
 dose_uom_id uuid not null references uom(id),
 route_code varchar(40),
 administered_at timestamptz not null,
 administered_by uuid references user_account(id),
 inventory_consumption_transaction_id uuid references inventory_transaction(id),
 status varchar(30) not null,
 reversal_of_id uuid references medication_administration(id),
 check (num_nonnulls(animal_id,animal_group_id)=1),
 check (dose_quantity > 0)
)
```
Posting administration and inventory consumption is atomic. Corrections reverse rather than edit posted history.

## withdrawal_period
```sql
withdrawal_period (
 id uuid primary key,
 medication_administration_id uuid not null references medication_administration(id),
 restriction_type varchar(40) not null,
 starts_at timestamptz not null,
 ends_at timestamptz not null,
 status varchar(30) not null,
 check (ends_at > starts_at)
)
```
Types include MILK, MEAT, EGGS and other configured outputs. Production/sales disposition must consult active restrictions.

## vaccination_event
```sql
vaccination_event (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 inventory_item_id uuid not null references inventory_item(id),
 inventory_lot_id uuid references inventory_lot(id),
 administered_at timestamptz not null,
 dose_quantity numeric(20,6),
 dose_uom_id uuid references uom(id),
 administered_by uuid references user_account(id),
 next_due_at timestamptz,
 inventory_consumption_transaction_id uuid references inventory_transaction(id),
 check (num_nonnulls(animal_id,animal_group_id)=1)
)
```

## welfare_assessment
```sql
welfare_assessment (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 location_id uuid references location(id),
 assessment_type varchar(80) not null,
 assessed_at timestamptz not null,
 score numeric(12,4),
 result_code varchar(40),
 findings jsonb,
 assessed_by uuid references user_account(id),
 check (num_nonnulls(animal_id,animal_group_id,location_id)>=1)
)
```

## Events
HealthCaseOpened, HealthObservationRecorded, ClinicalExaminationRecorded, DiagnosisRecorded, TreatmentPrescribed, TreatmentPerformed, MedicationAdministered, WithdrawalStarted, WithdrawalEnded, VaccinationRecorded, WelfareConcernDetected, HealthCaseClosed.

## Acceptance
Worker observations remain distinct from veterinary diagnosis; medication use consumes traceable lot inventory; withdrawals can block affected production; group treatment is supported without fake animals; history is immutable/correctable; AI cannot autonomously diagnose/prescribe/administer.
