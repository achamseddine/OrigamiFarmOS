# Origami FarmOS Database

This directory is the canonical relational database design and implementation baseline.

## Implementation read order
1. `MASTER-ERD.md`
2. `POSTGRESQL-CONVENTIONS.md`
3. `MIGRATION-ORDER.md`
4. `CROSS-DOMAIN-CONSTRAINTS.md`
5. `REFERENCE-CATALOG.md`
6. `SCHEMA-MAP.md`
7. Foundation and domain schema/ERD/integrity documents
8. `migrations/`

The database implements the semantics in `handbook/02-Ontology.md`, behavior in `handbook/03-Behavioral-Model.md`, and conventions in `architecture/DATABASE-ARCHITECTURE.md`.

## Baseline rule
Database Baseline v1 is the consolidated starting point for executable development. Do not infer a different physical schema merely because a conceptual entity exists in the ontology. Schema changes require reviewed migrations, tests and documentation updates. Projections are non-authoritative; posted ledgers/history are immutable.
