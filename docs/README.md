# Origami FarmOS — Animal and Feed documentation

**Current implementation reference:** `feat/qr-animal-quick-entry` at `e7933f09` (reviewed 2026-11-13). The documentation review is on a separate branch; proposed flow corrections are **not yet code fixes**.

## Choose a starting point

| You want to… | Read |
| --- | --- |
| See **what is missing or incorrect** before farm rollout | [Animal + Feed flow audit](ANIMAL-FEED-FLOW-AUDIT.md) — priority, code evidence, tests and correction order |
| Train a worker for morning/evening animal rounds | [Operational Workflows](../handbook/06-Operational-Workflows/README.md) |
| Understand animal registration, capability, history, groups, reproduction and exit | [Animal Digital Twin index](../handbook/05-Animal-Digital-Twin/README.md) → [Animal implementation map](GENERIC-ANIMAL-CAPABILITY-MODEL.md) |
| Use animal-side QR/typed-tag milk, feeding, weight and care | [QR Animal Quick Entry](QR-ANIMAL-QUICK-ENTRY.md) |
| Understand receipts, lots, mixing, numbered mixes, programs, feeding, costs and trace | [Generic Feed implementation map](GENERIC-FEED-ARCHITECTURE.md) |
| Understand **implemented deterministic** feed-performance monitoring | [Feed Performance Intelligence](../database/FEED-PERFORMANCE-INTELLIGENCE.md) + [implementation status](GENERIC-FEED-ARCHITECTURE.md#26-continuous-feed-performance-intelligence--required-extension) |
| Design future **per-animal nutritional requirements and ration optimization** | [Dynamic Nutrition design](../database/DYNAMIC-NUTRITION-AND-RATION-OPTIMIZATION.md) — **not implemented** |
| See actual schema/migration deviations | [Database README](../database/README.md) and [ADR-002](../architecture/ADR-002-REFERENCE-KEYS-UOM-SCHEDULER-GENERATED-ARTIFACTS.md) |
| Check API / Flutter status and tests | [Backend README](../backend/README.md), [Flutter README](../mobile/flutter_app/README.md), [Traceability Matrix](../product/TRACEABILITY.md) |

## Authority hierarchy

1. **Behavioral contract:** [Behavioral Model](../handbook/03-Behavioral-Model.md) and domain constraints.
2. **Conceptual data model:** `database/*-SCHEMA.md`, including nutrition design.
3. **Actual deployed schema:** Alembic migrations + ORM models; see [Database README](../database/README.md).
4. **Current API/UI behavior:** `backend/app/api/v1`, `backend/app/services`, `mobile/flutter_app/lib`, and automated tests.
5. **Known discrepancies:** [Audit](ANIMAL-FEED-FLOW-AUDIT.md); an aspirational specification is **not evidence** that a safeguard is shipped.

**Critical distinction:** feed *formula* ≠ physical numbered *mix* ≠ approved *feeding program* ≠ actual *offered event* ≠ measured *refusal* / estimated *intake* ≠ *performance assessment*. Keep these records and approval boundaries separate. A livestock task marked done is not a milk, feeding or medicine transaction.

## Review status

- Documentation improvements are reviewable without changing code or APK behavior.
- The most urgent engineering issues are group+individual demand accounting, create-permission ration activation/assignment, negative-stock overrides and milk-withdrawal handling while offline.
- No device, PostgreSQL or full end-to-end test suite was executed as part of this documentation-only review.
