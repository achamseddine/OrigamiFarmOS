# Database Pass 2 — Generic Livestock Schema

**Database:** PostgreSQL  
**Status:** Canonical implementation baseline  
**Depends on:** `FOUNDATION-SCHEMA.md`

This pass implements the generic Animal/AnimalGroup architecture. It does not create Cow, Horse, Sheep, Goat or Poultry core tables.

## 1. Design invariants
1. One individual animal = one stable `animal.id`.
2. Species-specific behavior comes from capability configuration.
3. Identification is child data; ear tag/name/RFID are not the PK.
4. AnimalGroup is first-class.
5. Group membership is historical/effective-dated.
6. Current location/profile/stage may be cached on the master for operational access, but changes must create history.
7. Reproduction, health, feed and production facts belong to their later owning domains.
8. No editable `pregnant`, `daily_milk`, `current_feed` or similar columns on `animal`.
9. History is never erased when capabilities/configuration change.

## 2. animal

```sql
animal (
  id uuid primary key,
  farm_id uuid not null references farm(id),
  species_id uuid not null references species(id),
  breed_id uuid references breed(id),
  sex_code varchar(30) not null,
  birth_date date,
  birth_date_estimated boolean not null default false,
  life_stage_id uuid references life_stage(id),
  management_profile_id uuid references management_profile(id),
  current_location_id uuid references location(id),
  origin_type varchar(40),
  acquisition_date date,
  status varchar(30) not null,
  status_reason varchar(120),
  notes text,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  created_by uuid references user_account(id),
  updated_by uuid references user_account(id),
  row_version bigint not null default 1
)
```

Validation:
- breed must belong to animal species;
- life stage/profile must be compatible with species when species-scoped;
- location must belong to animal farm;
- acquisition date cannot contradict known birth date without explicit correction workflow;
- `birth_date_estimated=false` with null birth date is invalid;
- species change after dependent operational history exists is restricted and audited;
- sex correction is permitted only through controlled/audited update.

Indexes:
- `(farm_id, status)`;
- `(farm_id, species_id, status)`;
- `(current_location_id, status)`;
- `(breed_id)`;
- `(management_profile_id)`.

## 3. animal_identifier

```sql
animal_identifier (
  id uuid primary key,
  farm_id uuid not null references farm(id),
  animal_id uuid not null references animal(id),
  identifier_type varchar(50) not null,
  identifier_value varchar(255) not null,
  normalized_value varchar(255) not null,
  issuing_authority varchar(200),
  scope_code varchar(50) not null default 'FARM',
  valid_from date,
  valid_to date,
  is_primary boolean not null default false,
  status varchar(30) not null default 'ACTIVE',
  created_at timestamptz not null,
  created_by uuid references user_account(id),
  check (valid_to is null or valid_from is null or valid_to >= valid_from)
)
```

Identifier types include EAR_TAG, RFID, MICROCHIP, LEG_BAND, PASSPORT, REGISTRATION_NUMBER, FARM_NUMBER, NAME and OTHER.

Uniqueness is policy-dependent:
- RFID/microchip may be globally unique;
- farm number normally farm-scoped;
- passport/registration may be authority-scoped;
- NAME is not generally unique.

Therefore do not apply one universal uniqueness rule. Maintain an `identifier_type_policy` table.

## 4. identifier_type_policy

```sql
identifier_type_policy (
  code varchar(50) primary key,
  display_name varchar(100) not null,
  uniqueness_scope varchar(30) not null,
  normalizer_code varchar(50) not null,
  active boolean not null default true,
  check (uniqueness_scope in ('NONE','FARM','AUTHORITY','GLOBAL'))
)
```

The service validates uniqueness according to policy; database partial/expression indexes should enforce stable scopes where practical.

Only one active primary identifier of the same type per animal should exist. A primary display identifier across different types is a UI preference and must not redefine identity.

## 5. animal_state_history

Records effective changes to lifecycle/master state without forcing downstream domains into the Animal aggregate.

```sql
animal_state_history (
  id uuid primary key,
  farm_id uuid not null references farm(id),
  animal_id uuid not null references animal(id),
  state_type varchar(50) not null,
  value_code varchar(120),
  value_reference_id uuid,
  effective_from timestamptz not null,
  effective_to timestamptz,
  reason_code varchar(80),
  source_event_id uuid,
  recorded_at timestamptz not null,
  recorded_by uuid references user_account(id),
  check (effective_to is null or effective_to > effective_from)
)
```

Initial state types: STATUS, LIFE_STAGE, MANAGEMENT_PROFILE, LOCATION.

This table is not a generic replacement for reproduction/health/feed history. Those domains keep their own authoritative records.

For each animal/state_type, effective ranges must not overlap. Enforce through PostgreSQL exclusion constraints where feasible.

## 6. animal_group

Represents herd/flock/batch/management group.

```sql
animal_group (
  id uuid primary key,
  farm_id uuid not null references farm(id),
  species_id uuid not null references species(id),
  code varchar(80) not null,
  name varchar(200) not null,
  group_type varchar(50) not null,
  sex_composition_code varchar(50),
  life_stage_id uuid references life_stage(id),
  management_profile_id uuid references management_profile(id),
  current_location_id uuid references location(id),
  tracking_mode varchar(30) not null,
  reported_quantity integer,
  status varchar(30) not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  created_by uuid references user_account(id),
  updated_by uuid references user_account(id),
  row_version bigint not null default 1,
  unique (farm_id, code),
  check (reported_quantity is null or reported_quantity >= 0),
  check (tracking_mode in ('MEMBERSHIP_DERIVED','QUANTITY_MANAGED','HYBRID'))
)
```

Quantity semantics:
- MEMBERSHIP_DERIVED: active individual memberships are authoritative; `reported_quantity` is not used as truth.
- QUANTITY_MANAGED: group is managed collectively; quantity changes use `animal_group_quantity_event`.
- HYBRID: selected individuals may be registered while aggregate quantity remains authoritative; never infer total quantity solely from memberships.

## 7. animal_group_membership

```sql
animal_group_membership (
  id uuid primary key,
  farm_id uuid not null references farm(id),
  animal_group_id uuid not null references animal_group(id),
  animal_id uuid not null references animal(id),
  valid_from timestamptz not null,
  valid_to timestamptz,
  reason_code varchar(80),
  created_at timestamptz not null,
  created_by uuid references user_account(id),
  check (valid_to is null or valid_to > valid_from)
)
```

Rules:
- animal and group must be same farm;
- normally same species; exceptions require explicit future policy, not ad-hoc bypass;
- overlapping membership in the same group is prohibited;
- whether an animal can simultaneously belong to multiple groups depends on group_type policy.

## 8. animal_group_type_policy

```sql
animal_group_type_policy (
  group_type varchar(50) primary key,
  display_name varchar(120) not null,
  exclusive_membership boolean not null default false,
  allows_individual_members boolean not null default true,
  active boolean not null default true
)
```

This allows a physical pen/herd grouping to be exclusive while analytical cohorts may overlap.

## 9. animal_group_quantity_event

For quantity-managed/hybrid groups, never overwrite quantity without history.

```sql
animal_group_quantity_event (
  id uuid primary key,
  farm_id uuid not null references farm(id),
  animal_group_id uuid not null references animal_group(id),
  event_type varchar(40) not null,
  quantity_delta integer not null,
  resulting_quantity integer not null,
  occurred_at timestamptz not null,
  reason_code varchar(80),
  source_reference_type varchar(80),
  source_reference_id uuid,
  recorded_at timestamptz not null,
  recorded_by uuid references user_account(id),
  correlation_id uuid,
  check (resulting_quantity >= 0)
)
```

Examples: INITIAL_COUNT, ADDITION, REMOVAL, BIRTH, DEATH, SALE, PURCHASE, TRANSFER, COUNT_ADJUSTMENT.

Later owning domains may generate these events; this ledger preserves collective quantity history.

## 10. animal_relationship

Generic animal-to-animal relationships, including biological parentage.

```sql
animal_relationship (
  id uuid primary key,
  farm_id uuid not null references farm(id),
  source_animal_id uuid not null references animal(id),
  target_animal_id uuid not null references animal(id),
  relationship_type varchar(50) not null,
  valid_from date,
  valid_to date,
  confidence_code varchar(30),
  evidence_reference varchar(255),
  created_at timestamptz not null,
  created_by uuid references user_account(id),
  check (source_animal_id <> target_animal_id),
  check (valid_to is null or valid_from is null or valid_to >= valid_from)
)
```

Initial relationship types: DAM_OF, SIRE_OF, OFFSPRING_OF, GENETIC_PARENT_OF, FOSTER_PARENT_OF.

Reproduction will later own breeding/birth episodes. Relationship records provide canonical graph/query semantics and must link back to source reproduction evidence when generated from those workflows.

## 11. animal_external_alias

External systems never replace internal UUID identity.

```sql
animal_external_alias (
  id uuid primary key,
  farm_id uuid not null references farm(id),
  animal_id uuid not null references animal(id),
  system_code varchar(80) not null,
  external_id varchar(255) not null,
  valid_from timestamptz,
  valid_to timestamptz,
  created_at timestamptz not null,
  unique (system_code, external_id),
  check (valid_to is null or valid_from is null or valid_to > valid_from)
)
```

## 12. Documents/media linkage

Do not put binary images on `animal`. A future document/media domain should store object metadata and link records. Until that domain is implemented, API contracts may expose attachment references but livestock schema must not invent a second document store.

## 13. Capability resolution persistence

Resolved capabilities are **derived**, not copied permanently onto each animal by default.

Resolver input:
```text
species + sex + life_stage + management_profile + effective capability rules
```

Resolver output:
```text
capability code + enabled + required + configuration + rule provenance
```

For historical audit, operational records that require a capability store their own business facts and may record the rule/configuration version or decision evidence. Do not delete history if a later rule disables the capability.

A cache/read projection such as `animal_capability_projection` is allowed and rebuildable.

## 14. Current state vs authoritative history

`animal.current_location_id`, `life_stage_id`, `management_profile_id`, and `status` are operational current-state fields. A successful change transaction must:
1. validate the new state;
2. close the prior matching `animal_state_history` range;
3. insert new history;
4. update current-state field;
5. insert outbox event;
6. commit atomically.

Do not update only the current field.

## 15. Suggested livestock events

- AnimalCreated
- AnimalMasterDataCorrected
- AnimalIdentifierAdded
- AnimalIdentifierRetired
- AnimalLocationChanged
- AnimalLifeStageChanged
- AnimalManagementProfileChanged
- AnimalStatusChanged
- AnimalGroupCreated
- AnimalAddedToGroup
- AnimalRemovedFromGroup
- AnimalGroupQuantityChanged
- AnimalRelationshipRecorded

All use the canonical outbox envelope.

## 16. API/data behavior implications

Create Animal requires farm, species, sex and capability-driven required identifiers. Backend resolves capabilities; frontend visibility alone is insufficient.

Animal search supports canonical UUID plus allowed identifiers/aliases. Ambiguous non-unique identifiers return multiple candidates rather than silently choosing.

Group operations distinguish membership-derived and quantity-managed groups.

Changing species is not a normal edit once operational history exists. Implement as privileged correction with impact validation.

## 17. Offline implications

Mobile-created animals/groups receive client-generated UUIDs. Identifier uniqueness is revalidated by server during sync. A conflict does not silently merge two animals. It enters explicit resolution.

Membership and quantity events have stable operation IDs/idempotency. Offline timestamps preserve occurred-at and recorded-at separately.

## 18. Recommended constraints/indexes

- animal `(farm_id, species_id, status)`
- animal `(farm_id, current_location_id, status)`
- identifier `(farm_id, identifier_type, normalized_value)`
- identifier `(animal_id, status)`
- state history `(animal_id, state_type, effective_from desc)`
- group `(farm_id, species_id, status)`
- membership `(animal_group_id, valid_from, valid_to)`
- membership `(animal_id, valid_from, valid_to)`
- quantity event `(animal_group_id, occurred_at)`
- relationship `(source_animal_id, relationship_type)`
- relationship `(target_animal_id, relationship_type)`

Use exclusion constraints for effective-range overlaps where PostgreSQL supports the required operator classes/extensions.

## 19. Acceptance criteria

Pass 2 is accepted when:
- cattle, horse, sheep, goat and individual poultry use the same Animal table;
- flock/herd/batch management works without fake individual animals;
- ear tag is not universally mandatory;
- farm number, RFID, microchip, passport and name can coexist;
- identifier uniqueness respects identifier type policy;
- breed/profile/stage/location cannot cross incompatible farm/species boundaries;
- animal/group history survives current-state changes;
- quantity-managed flocks retain count history;
- parentage/relationships are queryable without embedding reproduction episodes in Animal;
- capability resolver drives eligibility without duplicating capabilities per animal;
- offline creation does not cause silent duplicate merging;
- no downstream domain needs to add species-specific core livestock tables.
