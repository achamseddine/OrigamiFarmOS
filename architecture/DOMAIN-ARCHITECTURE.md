# Domain Architecture

The canonical semantic model is `handbook/02-Ontology.md`; behavior is `handbook/03-Behavioral-Model.md`.

## Aggregate boundaries
Initial aggregate candidates include Farm/Site/Location, Animal, AnimalGroup, FeedFormula, FeedBatch, FeedingProgram, InventoryLot/ledger transaction, PurchaseOrder, HealthCase, ReproductionEpisode, ProductionRecord, Sample/TestOrder, Asset/WorkOrder.

Aggregates protect invariants locally. Cross-aggregate workflows use application services/events.

## Livestock
```text
LivestockSubject
├─ Animal
└─ AnimalGroup

Animal → Species → Capability Rules → Resolved Capabilities
```
Never create species-specific parallel animal cores.

## Feed
```text
Ingredient → Formula Version → Batch → Feed Lot
Feeding Program → Assignment → Feeding Event
```
Usage policy and allocation are enforced transactionally.

## Domain ownership
Livestock owns identity/lifecycle master state. Reproduction owns breeding/pregnancy/birth records. Health owns clinical records. Feed owns formulas/programs/feeding records. Inventory owns stock ledger. Procurement owns purchasing. Production owns measured output. Workflow orchestrates but does not own domain truth.
