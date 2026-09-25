# Database Pass 1 — Foundation Schema

**Database:** PostgreSQL  
**Status:** Canonical implementation baseline

This pass defines platform identity, farm/site/location hierarchy, UOM/reference infrastructure, IAM foundation, audit, idempotency and event outbox. It deliberately does not create livestock/feed tables yet.

## 1. Global conventions

- PK: `uuid`, generated application-side or with PostgreSQL UUID generation.
- Table/column names: `snake_case`, singular table names.
- System timestamps: `timestamptz`.
- Human codes: case-normalized and unique within documented scope.
- Quantity: `numeric(20,6)` unless a domain needs greater precision.
- Money: `numeric(20,4)` + ISO currency code.
- No floating point for authoritative quantities/money.
- Boolean defaults explicit.
- FK deletion defaults to RESTRICT for business records.
- Use soft retirement/status, not deletion, for referenced master data.
- `created_at` is immutable; `updated_at` changes only when mutable master state changes.

## 2. organization

Represents a legal/operating organization that may own/manage farms.

```sql
organization (
  id uuid primary key,
  code varchar(50) not null,
  name varchar(200) not null,
  legal_name varchar(250),
  default_currency char(3),
  default_timezone varchar(100) not null,
  status varchar(30) not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  unique (code)
)
```

`default_timezone` uses IANA timezone identifiers.

## 3. farm

```sql
farm (
  id uuid primary key,
  organization_id uuid not null references organization(id),
  code varchar(50) not null,
  name varchar(200) not null,
  timezone varchar(100) not null,
  default_currency char(3),
  status varchar(30) not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  unique (organization_id, code)
)
```

Farm is the principal operational security/data scope.

## 4. site

A farm may contain one or more geographically/operationally distinct sites.

```sql
site (
  id uuid primary key,
  farm_id uuid not null references farm(id),
  code varchar(50) not null,
  name varchar(200) not null,
  site_type varchar(50),
  latitude numeric(10,7),
  longitude numeric(10,7),
  status varchar(30) not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  unique (farm_id, code)
)
```

Latitude range -90..90 and longitude -180..180 enforced by CHECK.

## 5. location

Hierarchical operational location. Examples: barn, pen, stable, warehouse, bin, field, plot, milking area.

```sql
location (
  id uuid primary key,
  farm_id uuid not null references farm(id),
  site_id uuid not null references site(id),
  parent_location_id uuid references location(id),
  code varchar(80) not null,
  name varchar(200) not null,
  location_type varchar(50) not null,
  active boolean not null default true,
  sort_order integer,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  unique (farm_id, code)
)
```

Rules:
- parent must belong to same farm/site;
- hierarchy cannot contain cycles;
- a location cannot parent itself;
- location retirement does not rewrite historical records.

Same-site parent integrity requires service validation and/or database trigger because a normal FK alone cannot compare the referenced row's site.

## 6. user_account

Authentication provider integration may evolve, but internal identity remains stable.

```sql
user_account (
  id uuid primary key,
  email varchar(320),
  display_name varchar(200) not null,
  external_auth_subject varchar(255),
  status varchar(30) not null,
  created_at timestamptz not null,
  updated_at timestamptz not null
)
```

Use partial unique indexes for normalized non-null email and external auth subject.

## 7. role and permission

```sql
role (
  id uuid primary key,
  code varchar(80) not null unique,
  name varchar(150) not null,
  description text,
  system_role boolean not null default false,
  status varchar(30) not null
)

permission (
  id uuid primary key,
  code varchar(120) not null unique,
  description text not null
)

role_permission (
  role_id uuid not null references role(id),
  permission_id uuid not null references permission(id),
  primary key (role_id, permission_id)
)
```

Permissions use action-oriented codes such as `animal.create`, `feed.batch.complete`, `inventory.adjust`.

## 8. farm_user_role

Effective-dated authorization scope.

```sql
farm_user_role (
  id uuid primary key,
  farm_id uuid not null references farm(id),
  user_id uuid not null references user_account(id),
  role_id uuid not null references role(id),
  site_id uuid references site(id),
  valid_from timestamptz not null,
  valid_to timestamptz,
  granted_by uuid references user_account(id),
  created_at timestamptz not null,
  check (valid_to is null or valid_to > valid_from)
)
```

Null `site_id` means farm-wide within the assigned role. Site must belong to farm.

## 9. UOM foundation

```sql
uom_dimension (
  id uuid primary key,
  code varchar(50) not null unique,
  name varchar(100) not null
)

uom (
  id uuid primary key,
  dimension_id uuid not null references uom_dimension(id),
  code varchar(30) not null unique,
  name varchar(100) not null,
  symbol varchar(30) not null,
  conversion_factor_to_base numeric(30,12) not null,
  conversion_offset_to_base numeric(30,12) not null default 0,
  is_base boolean not null default false,
  active boolean not null default true
)
```

Linear conversion:
`base_value = value * conversion_factor_to_base + conversion_offset_to_base`.

Do not use this generic conversion for domain-specific transformations such as as-fed ↔ dry-matter basis; those require context.

Only one active base UOM per dimension should be enforced by partial unique index.

Initial dimensions: MASS, VOLUME, COUNT, LENGTH, AREA, TEMPERATURE, TIME, ENERGY.

## 10. reference data foundation

Reference masters are governed, not hard-coded enums.

```sql
species (
  id uuid primary key,
  code varchar(50) not null unique,
  scientific_name varchar(150),
  name_en varchar(100) not null,
  name_ar varchar(100),
  active boolean not null default true
)

breed (
  id uuid primary key,
  species_id uuid not null references species(id),
  code varchar(80) not null,
  name varchar(150) not null,
  active boolean not null default true,
  unique (species_id, code)
)

life_stage (
  id uuid primary key,
  species_id uuid references species(id),
  code varchar(80) not null,
  name varchar(150) not null,
  minimum_age_days integer,
  maximum_age_days integer,
  active boolean not null default true,
  check (minimum_age_days is null or minimum_age_days >= 0),
  check (maximum_age_days is null or maximum_age_days >= minimum_age_days)
)

management_profile (
  id uuid primary key,
  species_id uuid references species(id),
  code varchar(80) not null,
  name varchar(150) not null,
  active boolean not null default true
)

capability (
  id uuid primary key,
  code varchar(100) not null unique,
  category varchar(80),
  description text,
  active boolean not null default true
)

species_capability_rule (
  id uuid primary key,
  species_id uuid not null references species(id),
  capability_id uuid not null references capability(id),
  sex_code varchar(30),
  life_stage_id uuid references life_stage(id),
  management_profile_id uuid references management_profile(id),
  enabled boolean not null,
  required boolean not null default false,
  priority integer not null default 0,
  configuration jsonb,
  valid_from timestamptz,
  valid_to timestamptz,
  check (valid_to is null or valid_from is null or valid_to > valid_from)
)
```

A null species on life_stage/profile denotes a globally reusable definition where appropriate. Application validation ensures referenced life stage/profile is compatible with the rule species.

Sex is initially a governed code/value set in application/reference configuration; if richer metadata/localization is required, promote it to a reference table without changing Animal semantics.

## 11. audit_log

Audit is append-only.

```sql
audit_log (
  id uuid primary key,
  farm_id uuid references farm(id),
  actor_user_id uuid references user_account(id),
  action varchar(120) not null,
  entity_type varchar(120) not null,
  entity_id uuid,
  occurred_at timestamptz not null,
  correlation_id uuid,
  reason text,
  before_data jsonb,
  after_data jsonb,
  metadata jsonb
)
```

Audit records are not the domain event stream and must not be used to reconstruct financial/inventory ledgers.

## 12. idempotency_record

```sql
idempotency_record (
  id uuid primary key,
  farm_id uuid references farm(id),
  actor_user_id uuid references user_account(id),
  idempotency_key varchar(200) not null,
  request_fingerprint varchar(128) not null,
  operation varchar(150) not null,
  status varchar(30) not null,
  response_code integer,
  response_body jsonb,
  resource_type varchar(120),
  resource_id uuid,
  created_at timestamptz not null,
  expires_at timestamptz,
  unique (farm_id, actor_user_id, idempotency_key)
)
```

Reusing a key with a different request fingerprint is rejected.

## 13. outbox_event

Transactional outbox for reliable event publication.

```sql
outbox_event (
  id uuid primary key,
  event_type varchar(150) not null,
  event_version integer not null,
  aggregate_type varchar(120) not null,
  aggregate_id uuid not null,
  farm_id uuid references farm(id),
  occurred_at timestamptz not null,
  recorded_at timestamptz not null,
  correlation_id uuid,
  causation_id uuid,
  actor_user_id uuid references user_account(id),
  payload jsonb not null,
  publish_status varchar(30) not null default 'PENDING',
  attempt_count integer not null default 0,
  next_attempt_at timestamptz,
  published_at timestamptz,
  last_error text
)
```

Domain transaction and outbox insert occur in the same database transaction.

Indexes: pending publication on `(publish_status, next_attempt_at)`; aggregate lookup on `(aggregate_type, aggregate_id, occurred_at)`.

## 14. Projection boundary

Authoritative tables above may feed replaceable read models such as:
- location_tree_projection;
- user_farm_access_projection;
- reference_catalog_projection.

Future domain projections include animal_current_status, inventory_balance, feed_days_of_cover and current_feeding_assignment.

Projections are rebuildable and never accepted as the sole authoritative source for posted transactions.

## 15. Foundation indexes

At minimum:
- all FKs used frequently for joins;
- `site(farm_id, status)`;
- `location(site_id, parent_location_id)`;
- `farm_user_role(user_id, farm_id, valid_from, valid_to)`;
- `species_capability_rule(species_id, capability_id, priority)`;
- `audit_log(farm_id, occurred_at desc)`;
- `audit_log(entity_type, entity_id, occurred_at desc)`;
- outbox pending index;
- idempotency uniqueness index.

## 16. Data isolation

Every operational request resolves an authorized farm scope. Queries must never rely solely on a client-provided farm ID. Farm access is derived from authenticated identity and active assignments.

If PostgreSQL Row Level Security is adopted, it is defense-in-depth, not a substitute for application authorization. Adoption should be documented by ADR.

## 17. Foundation acceptance criteria

Pass 1 is complete when:
- organizations can own multiple farms;
- farms can contain multiple sites and hierarchical locations;
- cross-farm location parenting is impossible;
- user roles can be scoped to farm or site and effective dates;
- permissions are action-oriented and configurable;
- canonical UOM conversion exists without assuming kg/L globally;
- species/breed/life-stage/profile/capability configuration supports the Generic Animal model;
- audit is append-only and distinguishable from domain events;
- retryable writes can be deduplicated;
- outbox events are committed atomically with domain transactions;
- authoritative tables and projections are clearly distinguished;
- the schema can be migrated without destructive manual database edits.
