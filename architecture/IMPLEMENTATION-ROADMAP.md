# Implementation Roadmap

Build vertical slices. Do not generate the whole ERP in one pass.

## Phase 0 — Engineering foundation
Repository/workspace, framework ADRs, PostgreSQL, migrations, API skeleton, OpenAPI, auth skeleton, audit/correlation IDs, domain-event outbox, test harness, local containers and CI.

## Phase 1 — Farm foundation
Farm, Site, Location hierarchy, UOM/reference-data framework, users/farm scope.

**Exit:** authenticated user can operate only in authorized farm/site and manage canonical locations.

## Phase 2 — Generic livestock
Species, Breed, Sex/reference data, LifeStage, ManagementProfile, Capability/Rules, Animal, AnimalIdentifier, AnimalGroup/membership and capability resolver.

**Exit:** cattle/horse/sheep/goat can be created without species-specific core tables and UI/actions derive from capabilities.

## Phase 3 — Inventory foundation
Item/Product, lot, location stock ledger, receipt/issue/transfer, reservation, quarantine, physical count/reconciliation.

**Exit:** auditable lot stock and availability calculation.

## Phase 4 — Feed
Feed masters, usage policy, formula/version, mixing batch, ingredient-lot consumption, feed lot output, feeding programs/rules, assignments, feeding events, allocation, reconciliation and replenishment alerts.

**Exit:** cattle-only premix cannot be used for horses/sheep; purchase-to-consumption traceability works; stockout warning is generated.

## Phase 5 — Reproduction / Health / Production
Implement as separate vertical domains consuming livestock capabilities/events.

## Phase 6 — Procurement and costing
Requisition/approval/PO/receipt/invoice links, feed cost and animal/group/product cost attribution.

## Phase 7 — Wider ERP
Crops, assets/maintenance, laboratory/quality, sales, finance, compliance, advanced analytics/integrations.

## Development cadence
For each slice: requirement → ADR if needed → schema/migration → domain rules → API/OpenAPI → event/audit → web/mobile workflow → automated tests → acceptance review.

Do not proceed to the next phase while foundational invariants are failing.

## Feed Performance Intelligence implementation gate
Feed Performance Intelligence is intentionally implemented only after the authoritative lineage it depends on exists. Required sequence: supplier/receipt lot identity → inventory lot genealogy → actual feed-batch components → feeding events/exposure → milk/production records → relevant health/lifecycle context → costing → analytical monitors/assessments/alerts. Feed vertical slices must preserve these keys from day one. Initial intelligence should begin with deterministic baselines/formula deviation/traceability, then add versioned statistical/AI models without changing authoritative domain semantics.

**Status:** the gate is passed and the deterministic first increment is implemented (migrations `c9e1a7b2d4f6` numbered mixes, `d2f4a6c8e0b1` feed performance). The medicine & pharmacy module (`e3a5b7c9d1f2`) and the emergency protocol engine (`f4b6c8d0e2a3`) followed, in that order, because protocol medication steps bind to pharmacy lots. Versioned statistical/AI models are the next increment; they must keep the same assessment, evidence and confidence contract.

