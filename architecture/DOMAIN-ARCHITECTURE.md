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

## Feed Performance Intelligence boundary
**Consumes:** supplier/procurement facts, ingredient and feed lot lineage, actual feed batches, feeding events, livestock/group state, production, health/lifecycle context and costing.  
**Owns:** performance monitor configuration, reproducible exposure projections, analytical assessments, batch/supplier performance projections and feed-performance alerts.  
**Does not own:** inventory balances, feed formulas/batches/events, supplier master status, milk/production facts, diagnoses or approved feeding programs. Analytical outputs may trigger review workflows but cannot mutate owning-domain truth directly.

