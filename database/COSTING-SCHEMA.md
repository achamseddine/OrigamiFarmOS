# Database Pass 5B — Operational Costing

**Status:** Canonical operational costing baseline  
**Boundary:** This is management/operational costing, not a substitute for a statutory general ledger.

## 1. Principles
- Cost follows authoritative operational facts.
- Historical cost is not recomputed silently when master prices change.
- Planned/standard cost is distinct from actual cost.
- Feed batch cost derives from actual consumed ingredient lots.
- Feeding cost derives from posted feed inventory consumption.
- Medication cost derives from actual administered inventory consumption.
- Production unit cost is an allocation/projection with methodology provenance.

## 2. cost_center
```sql
cost_center (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 code varchar(80) not null,
 name varchar(150) not null,
 parent_cost_center_id uuid references cost_center(id),
 status varchar(30) not null,
 unique (farm_id,code)
)
```
Examples: dairy herd, sheep unit, poultry, crops, machinery.

## 3. cost_entry
Append-only operational cost fact.
```sql
cost_entry (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 cost_center_id uuid references cost_center(id),
 cost_type varchar(50) not null,
 source_type varchar(80) not null,
 source_id uuid not null,
 occurred_at timestamptz not null,
 quantity numeric(20,6),
 uom_id uuid references uom(id),
 amount numeric(20,4) not null,
 currency char(3) not null,
 base_currency_amount numeric(20,4),
 fx_rate numeric(20,10),
 allocation_status varchar(30) not null,
 reversal_of_id uuid references cost_entry(id),
 recorded_at timestamptz not null,
 check (amount >= 0 or reversal_of_id is not null)
)
```
Examples: FEED, MEDICATION, PURCHASE_FREIGHT, LAB, LABOR, ASSET, UTILITIES.

## 4. inventory_cost_layer
Supports chosen inventory valuation method without corrupting quantity ledger.
```sql
inventory_cost_layer (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 inventory_item_id uuid not null references inventory_item(id),
 inventory_lot_id uuid references inventory_lot(id),
 source_transaction_id uuid not null references inventory_transaction(id),
 original_quantity_base numeric(20,6) not null,
 remaining_quantity_base numeric(20,6) not null,
 unit_cost_base_currency numeric(20,8) not null,
 valuation_method varchar(30) not null,
 created_at timestamptz not null,
 check (original_quantity_base > 0),
 check (remaining_quantity_base >= 0)
)
```
Initial implementation should prefer lot-specific actual cost where lot tracking exists. Broader FIFO/weighted-average policy requires an ADR before implementation.

## 5. cost_allocation
```sql
cost_allocation (
 id uuid primary key,
 cost_entry_id uuid not null references cost_entry(id),
 target_type varchar(50) not null,
 target_id uuid not null,
 allocation_percent numeric(9,6),
 allocated_amount numeric(20,4) not null,
 methodology_code varchar(60) not null,
 methodology_version varchar(30),
 created_at timestamptz not null,
 check (allocation_percent is null or allocation_percent between 0 and 100)
)
```
Targets can include ANIMAL, ANIMAL_GROUP, FEED_BATCH, PRODUCTION_RECORD, FIELD, ASSET, COST_CENTER. Application validates target existence/type.

## 6. feed batch actual cost
```text
Actual batch ingredient cost
= SUM(actual component quantity × consumed lot cost)

+ optional allocated mixing labor/energy/overhead
= actual feed batch cost

Actual cost per base unit
= batch actual cost / actual usable output
```
Never use formula target quantities for actual batch cost when actual component data exists.

## 7. animal/group feed cost
Feed cost is generated from feeding-event-linked inventory consumption and allocated to the animal/group. For quantity-managed groups, per-head figures require a documented head-count basis.

## 8. production cost projection
```sql
production_cost_projection (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 production_record_id uuid not null references production_record(id),
 methodology_code varchar(60) not null,
 methodology_version varchar(30) not null,
 calculated_at timestamptz not null,
 direct_feed_cost numeric(20,4) not null default 0,
 direct_health_cost numeric(20,4) not null default 0,
 allocated_labor_cost numeric(20,4) not null default 0,
 allocated_asset_cost numeric(20,4) not null default 0,
 allocated_other_cost numeric(20,4) not null default 0,
 total_cost numeric(20,4) not null,
 currency char(3) not null
)
```
This is reproducible analytical output, not accounting truth.

## 9. FX
Store transaction currency and amount. When converting, retain rate, source/date/method and base amount. Never overwrite original currency facts.

## 10. Events
OperationalCostRecorded, OperationalCostReversed, CostAllocated, InventoryCostLayerCreated, FeedBatchCostCalculated, ProductionCostCalculated.

## 11. Acceptance
Actual feed cost uses actual consumed lots; purchase price changes do not rewrite history; medicine use can be costed to health case/animal/group; planned and actual costs remain distinct; per-liter/per-egg/per-kg analytics identify methodology; operational costing does not pretend to be full accounting.
