# Testing Strategy

## Layers
- Unit tests: domain invariants/resolvers/calculations.
- Integration tests: PostgreSQL repositories, migrations, outbox, module interactions.
- API contract tests: OpenAPI behavior, validation, auth and idempotency.
- End-to-end tests: critical farm workflows.
- Offline/sync tests: duplicate operations, conflicts, stale reference data and reconnect.
- Migration tests: clean install and upgrade paths.

## Mandatory domain cases
Test capability resolution, invalid pregnancy workflow, animal/group assignments, formula version immutability, species-restricted feed, reserved/quarantined stock, inventory reconciliation, reorder forecast, duplicate feeding submission and authorization boundaries.

Every bug affecting a domain invariant should receive a regression test.
