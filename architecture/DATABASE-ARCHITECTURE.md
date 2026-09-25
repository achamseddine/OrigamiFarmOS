# Database Architecture & Conventions

## Database
PostgreSQL is the authoritative transactional store.

## Conventions
- UUID primary keys.
- `created_at`, `updated_at`; add `created_by`/`updated_by` where audit requirements apply.
- Effective-dated entities use `valid_from`/`valid_to`.
- Use explicit foreign keys and constraints.
- Prefer normalized authoritative data; use projections/materialized views for reporting.
- Store money as decimal/numeric + currency, never floating point.
- Store quantities as decimal/numeric + UOM reference.
- UTC timestamps for system time; preserve local operational timezone where needed.
- Avoid database enums for rapidly configurable business taxonomies; use governed reference tables.
- JSONB is for extensible configuration/evidence, not an excuse to avoid modeling core relationships.

## History
Posted transactions are immutable. Corrections use reversal/amendment patterns. Formula/program versions used operationally remain historical.

## Inventory
Inventory balance derives from an append-only/auditable transaction ledger. Reservations, quarantine and blocks affect availability. Do not maintain an independent editable stock truth.

## Migrations
All schema changes use version-controlled migrations. Each migration must be forward deterministic and include rollback/mitigation notes for destructive changes.

## Indexing
Index foreign keys, external lookup aliases, status/effective-date filters and high-frequency operational queries. Add indexes from measured query patterns rather than indiscriminately.

## Seed/reference data
Seed stable platform reference data separately from farm-specific operational data. Species/capability examples are seedable but configurable.
