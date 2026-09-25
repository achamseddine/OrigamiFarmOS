# ADR-001 — Phase 0 Implementation Stack

**Status:** Accepted for implementation baseline

## Decision
Origami FarmOS will start as a TypeScript modular monolith.

- Runtime: Node.js 22 LTS
- Backend: NestJS
- API: REST/JSON, OpenAPI generated from application contracts
- Database: PostgreSQL 16
- ORM/migrations: Prisma, with SQL migrations reviewed as authoritative deployment artifacts
- Validation: DTO/schema validation at API boundary plus domain validation in application/domain services
- Tests: Vitest for unit/integration tests; API tests against PostgreSQL
- Package manager/workspace: pnpm workspaces
- Local infrastructure: Docker Compose
- CI: GitHub Actions
- IDs: application-generated UUIDs
- Logging: structured JSON-capable application logging with correlation IDs
- Authentication: adapter boundary in Phase 0; production identity provider selected separately. Development auth must never become production authorization.

## Why
TypeScript provides one language across backend and future web tooling. NestJS provides explicit module boundaries, dependency injection and OpenAPI integration suitable for the modular-monolith architecture. PostgreSQL remains the authoritative store. Prisma provides a productive schema/client and migration workflow while still allowing explicit SQL constraints/indexes where ORM abstractions are insufficient.

## Constraints
- Prisma schema is not permission to weaken database constraints.
- Business-critical rules live server-side.
- Cross-module writes occur through module application interfaces, not arbitrary repository access.
- No microservices in Phase 0.
- No framework-specific entity model may replace the canonical domain/database specifications.
- Foundational dependency changes require a new ADR.

## Consequences
The repository gains executable backend, migration, test and container foundations. Mobile/web framework selection can be recorded separately when those clients begin.
