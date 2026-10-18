# ADR-002 — Reference keys, the unit registry, the in-process scheduler and generated artifacts

**Status:** Accepted (implemented with migration `a7c9e1f3b5d7`)

## Context
The database specifications merged with PR #10 (`database/FOUNDATION-SCHEMA.md`,
`MEDICINE-PHARMACY-SCHEMA.md`, `MEDICINE-NOTIFICATION-RULES.md`,
`HEALTH-VETERINARY-SCHEMA.md`, `PROCUREMENT-SCHEMA.md`,
`FEED-PERFORMANCE-INTELLIGENCE.md`, `CLINICAL-DECISION-SUPPORT-EMERGENCY-PROTOCOLS.md`)
describe reference tables keyed by UUID (`species.id`, `uom.id`), scheduled
analytical cycles, role-routed notifications and a repository whose DDL and
API contract are kept in step with the code. The running backend already had
species, capability and unit vocabularies keyed by their **codes**, no
scheduler, farm-wide notifications and a hand-written `schema.sql` that had
fallen 70 tables behind the models. This ADR records how those were
reconciled rather than silently diverging from the documents.

## Decisions

1. **Reference tables keep natural keys.** `species.code`,
   `management_profiles.code`, `capabilities.code` and the new
   `units_of_measure.code` are the primary keys the rest of the schema
   references. The documents' `uuid` columns on these tables are not
   introduced. Reason: the codes are stable, human-readable, already in every
   API payload the tablet caches, and a surrogate would add a join to every
   capability resolution and every unit check for no behavioural gain. The
   documents remain the semantic source; this is a documented physical
   deviation (see `database/README.md`).

2. **Units of measure are a table, not a string.** Every unit column on
   medicines, lots, administrations, protocol medication steps and
   requisition lines references `units_of_measure.code`. An unknown unit is
   refused server-side with a message that names where to add it; the
   migration inserts the built-in catalogue plus any unit code already in
   use so existing data keeps referential integrity. Conversions follow the
   unit's dimension and factor; a count unit never silently becomes another.

3. **Scheduled cycles run in-process.** `app/core/scheduler.py` runs the
   daily feed-performance cycle, the daily pharmacy scan and the
   15-minute emergency reassessment check from the API process's lifespan,
   logs every run in `scheduled_job_runs`, exposes them under `/scheduler`
   and can be driven on demand (`POST /scheduler/run`). It is disabled in
   tests and by `FARMOS_SCHEDULER=false`. A separate worker or an external
   scheduler is deferred until there is more than one API process; the job
   log and the idempotent cycles are what make that move safe later.

4. **Notifications are routed, then copied per person.** `notification_routes`
   maps a route code (pharmacy stock, pharmacy critical, expiry, emergency
   escalation / manager / veterinarian / reassessment, feed performance,
   procurement) to roles or named users per farm, with defaults when a farm
   configures nothing. A routed signal becomes one `notifications` row per
   recipient (`source_id = "<source>|<user>"`), so the bell is addressed and
   dismissed per person.

5. **Generated artifacts are generated, and the build checks them.**
   `database/schema.sql` is rendered from the ORM metadata through the
   PostgreSQL dialect (`python -m app.export_schema`); `api/openapi.yaml` is
   exported from the application (`python -m app.export_openapi`).
   `backend/tests/test_generated_artifacts.py` fails when either is stale;
   `backend/tests/test_migrations.py` proves the Alembic chain produces the
   same tables, columns, types, keys, indexes and unique constraints as the
   models, seeds the demo farm onto the migrated schema, and downgrades to
   the beginning and back — on SQLite always and on PostgreSQL 16 in CI
   (`.github/workflows/backend-tests.yml`). The ORM therefore declares every
   index and named constraint the migrations create.

6. **The PostgreSQL driver is pinned by the application.** SQLAlchemy 2.1
   made psycopg 3 the default for bare `postgresql://` URLs; the backend
   ships psycopg2. `app.core.config.normalize_database_url` rewrites
   `postgresql://` and `postgres://` to `postgresql+psycopg2://` for the API,
   Alembic and the workflows, so a deployment's connection string keeps
   working across dependency upgrades.

## Consequences
- Species, profile and unit codes are part of the public contract; renaming
  one is a data migration, not an edit.
- A unit the farm needs must exist in `units_of_measure` before a medicine
  or a requisition line can use it (`POST /units-of-measure`, manager only).
- `schema.sql` carries no hand-written `CHECK` constraints; the equivalent
  rules are enforced in the services and covered by tests. A database
  created from `schema.sql` must be stamped (`alembic stamp head`) before
  later migrations apply.
- Every new model module must be listed in `app/domain/registry.py`; a test
  fails otherwise, because an unlisted module is a table with no migration,
  no DDL and no parity check.
