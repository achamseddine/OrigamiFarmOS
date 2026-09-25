# Database Migrations

Executable PostgreSQL migrations are introduced by vertical slice according to ../MIGRATION-ORDER.md. Phase 0 establishes the toolchain but intentionally does not generate the entire ERP schema in one migration. Migrations are committed/reviewed/tested; seed data is idempotent and separate from farm operational data.
