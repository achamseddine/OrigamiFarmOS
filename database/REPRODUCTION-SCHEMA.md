# Database Pass 4A — Reproduction

**Status:** Canonical implementation baseline  
**Depends on:** Foundation, Livestock

Reproduction owns breeding, pregnancy, birth and incubation/hatch facts. It does not store generic animal identity, production output, or veterinary diagnosis.

## Core invariants
- Reproduction capability is validated against the effective livestock configuration.
- Pregnancy is never inferred merely from mating/insemination.
- Poultry incubation/hatching is not forced through mammalian pregnancy.
- Birth creates/links offspring through controlled livestock creation and preserves parentage.
- Current reproductive status is a projection from authoritative episodes/events.

## breeding_event
```sql
breeding_event (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 female_animal_id uuid not null references animal(id),
 male_animal_id uuid references animal(id),
 event_type varchar(40) not null,
 method_code varchar(40),
 occurred_at timestamptz not null,
 semen_batch_reference varchar(120),
 technician_user_id uuid references user_account(id),
 status varchar(30) not null,
 notes text,
 recorded_at timestamptz not null,
 recorded_by uuid references user_account(id),
 correlation_id uuid
)
```
Types may include NATURAL_MATING, ARTIFICIAL_INSEMINATION, EMBRYO_TRANSFER and other configured methods. Female/male terminology reflects biological role in this event, not UI assumptions.

## pregnancy_episode
```sql
pregnancy_episode (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid not null references animal(id),
 originating_breeding_event_id uuid references breeding_event(id),
 status varchar(30) not null,
 estimated_conception_date date,
 expected_due_date date,
 ended_at timestamptz,
 outcome_code varchar(40),
 created_at timestamptz not null,
 updated_at timestamptz not null
)
```
Only animals with effective PREGNANCY capability may have active pregnancy episodes. At most one active episode per animal unless future species policy explicitly permits otherwise.

## pregnancy_assessment
```sql
pregnancy_assessment (
 id uuid primary key,
 pregnancy_episode_id uuid references pregnancy_episode(id),
 animal_id uuid not null references animal(id),
 assessed_at timestamptz not null,
 assessment_type varchar(50) not null,
 result_code varchar(40) not null,
 estimated_gestation_days integer,
 expected_due_date date,
 examiner_user_id uuid references user_account(id),
 evidence_reference uuid,
 notes text,
 recorded_at timestamptz not null
)
```
A NEGATIVE assessment may exist without a pregnancy episode. Domain service controls episode creation/closure.

## birth_event
```sql
birth_event (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 dam_animal_id uuid not null references animal(id),
 pregnancy_episode_id uuid references pregnancy_episode(id),
 occurred_at timestamptz not null,
 birth_type_code varchar(40),
 assistance_code varchar(40),
 offspring_count integer not null,
 live_count integer not null,
 stillborn_count integer not null default 0,
 status varchar(30) not null,
 notes text,
 recorded_by uuid references user_account(id),
 recorded_at timestamptz not null,
 check (offspring_count >= 0 and live_count >= 0 and stillborn_count >= 0),
 check (live_count + stillborn_count <= offspring_count)
)
```

## birth_offspring
```sql
birth_offspring (
 id uuid primary key,
 birth_event_id uuid not null references birth_event(id),
 offspring_animal_id uuid references animal(id),
 sequence_no integer not null,
 sex_code varchar(30),
 birth_weight numeric(20,6),
 weight_uom_id uuid references uom(id),
 outcome_code varchar(40) not null,
 notes text,
 unique (birth_event_id, sequence_no)
)
```
Live individually tracked offspring can create/link Animal records atomically. Group-managed births may instead create quantity events through the livestock group workflow.

## incubation_batch / hatch_event
```sql
incubation_batch (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_group_id uuid references animal_group(id),
 code varchar(100) not null,
 eggs_set integer not null,
 set_at timestamptz not null,
 expected_hatch_date date,
 status varchar(30) not null,
 unique (farm_id, code),
 check (eggs_set > 0)
)

hatch_event (
 id uuid primary key,
 incubation_batch_id uuid not null references incubation_batch(id),
 occurred_at timestamptz not null,
 hatched_live integer not null,
 unhatched integer,
 culled integer,
 destination_group_id uuid references animal_group(id),
 recorded_by uuid references user_account(id),
 recorded_at timestamptz not null,
 check (hatched_live >= 0)
)
```

## Events
BreedingRecorded, PregnancyAssessmentRecorded, PregnancyConfirmed, PregnancyEnded, BirthRecorded, OffspringRegistered, IncubationStarted, HatchRecorded, ReproductionReviewRequired.

## Acceptance
Mammalian and poultry reproduction share canonical architecture without false pregnancy semantics; parentage is traceable; pregnancy history is preserved; births can create individual offspring or group quantity changes; reproductive state can trigger feeding review without silently changing rations.
