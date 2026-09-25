# Claude Development Instructions — Origami FarmOS

Read this file before making implementation changes.

## Required reading order
1. `CONSTITUTION.md`
2. `README.md`
3. `handbook/01-Vision.md`
4. `handbook/02-Ontology.md`
5. `handbook/03-Behavioral-Model.md`
6. relevant domain handbook files
7. `architecture/` documents
8. relevant product requirements/acceptance criteria

If documents conflict, stop and surface the conflict. Do not silently invent a new architecture.

## Non-negotiable domain rules
- Use one generic Animal model. Never create Cow, Horse, Sheep, Goat, Chicken tables as parallel core models.
- Resolve species-specific behavior through Species + Sex + LifeStage + ManagementProfile + capabilities/configuration.
- Support both Animal and AnimalGroup as livestock subjects.
- Identifiers (ear tag, RFID, microchip, passport, etc.) are child records/aliases, not the animal PK.
- Feed Item, Feed Formula, Formula Version, Feed Batch, Feed Product/Lot, Feeding Program and Feeding Event are distinct concepts.
- Purchased and farm-mixed feed converge on common downstream inventory/feeding interfaces.
- Enforce feed species/use restrictions server-side.
- Inventory is ledger-driven. On-hand is not necessarily available; reservations/quarantine/blocks matter.
- Plans/recommendations are never stored as actual transactions.
- Preserve history. Use versions, effective dating, reversals/corrections and audit records.
- External IDs are never internal PKs.
- AI may recommend; it does not become authoritative domain truth or bypass approvals.

## Engineering approach
Origami starts as a **modular monolith**, not microservices. Modules have explicit boundaries and may communicate through application services and domain events. Do not directly mutate another module's tables.

Implement vertical slices: schema + domain + API + events + UI/mobile + tests.

## Initial stack
- PostgreSQL as authoritative relational database.
- REST/JSON APIs with OpenAPI contracts.
- UUID primary keys.
- Database migrations are mandatory.
- Domain events use the canonical event envelope.
- Android/tablet workflows are offline-first.
- Web application is management/administration oriented.
- Containers are used for reproducible local/deployment environments.

Framework/library choices must be documented in an ADR before introducing a foundational dependency when the repo has not already standardized it.

## Code rules
- No business-critical validation only in UI.
- No hard-coded species branching scattered through code; centralize configurable rules/capability resolution.
- No destructive schema changes without migration strategy.
- No editing posted ledger history.
- No duplicate shadow inventory.
- Use explicit units; never assume kg/L when domain permits multiple units.
- Use UTC timestamps internally and retain operational timezone/context where required.
- Every retryable write endpoint needs idempotency strategy.
- Every domain mutation checks authorization.
- Every new behavior needs tests.

## Definition of Done
A feature is not complete until it includes applicable:
- migration/schema;
- domain model/rules;
- service/use case;
- API contract;
- authorization;
- validation;
- domain events;
- audit behavior;
- offline implications;
- tests;
- documentation/acceptance criteria.

## First implementation sequence
Do not attempt the entire ERP at once.
1. Platform foundation and IAM skeleton.
2. Farm / Site / Location.
3. Species / Breed / LifeStage / ManagementProfile / Capability configuration.
4. Generic Animal + AnimalIdentifier.
5. AnimalGroup + membership.
6. Capability resolver and dynamic animal profile.
7. Inventory foundation + UOM.
8. Feed masters/formulas/lots/batches.
9. Feeding programs/assignments/events.
10. Reproduction, health and production verticals.
11. Procurement/costing and broader modules.

See `architecture/IMPLEMENTATION-ROADMAP.md`.
