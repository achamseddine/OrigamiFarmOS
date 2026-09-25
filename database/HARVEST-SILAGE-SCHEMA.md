# Database Pass 6B — Harvest, Farm-Produced Feed & Silage

**Status:** Canonical implementation baseline  
**Depends on:** Crops, Inventory, Feed

## 1. Harvest
```sql
harvest_event (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 crop_cycle_id uuid not null references crop_cycle(id),
 harvested_at timestamptz not null,
 harvested_area numeric(20,6),
 area_uom_id uuid references uom(id),
 gross_quantity numeric(20,6) not null,
 quantity_uom_id uuid not null references uom(id),
 moisture_percent numeric(8,4),
 status varchar(30) not null,
 recorded_by uuid references user_account(id),
 recorded_at timestamptz not null,
 check (gross_quantity >= 0),
 check (moisture_percent is null or moisture_percent between 0 and 100)
)
```

## 2. harvest_lot
```sql
harvest_lot (
 id uuid primary key,
 harvest_event_id uuid not null references harvest_event(id),
 inventory_item_id uuid not null references inventory_item(id),
 inventory_lot_id uuid not null references inventory_lot(id),
 quantity_base numeric(20,6) not null,
 inventory_production_transaction_id uuid not null references inventory_transaction(id),
 grade_code varchar(50),
 disposition_code varchar(50),
 check (quantity_base > 0)
)
```
Harvest posting creates farm-produced inventory through PRODUCTION_OUTPUT. Crop records do not maintain a shadow harvest balance.

## 3. post_harvest_transformation
Generic crop-output transformation before/into inventory/feed.
```sql
post_harvest_transformation (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 transformation_type varchar(60) not null,
 code varchar(100) not null,
 started_at timestamptz,
 completed_at timestamptz,
 status varchar(30) not null,
 output_inventory_item_id uuid not null references inventory_item(id),
 output_inventory_lot_id uuid references inventory_lot(id),
 actual_output_quantity numeric(20,6),
 output_uom_id uuid references uom(id),
 unique (farm_id,code)
)

post_harvest_input (
 id uuid primary key,
 transformation_id uuid not null references post_harvest_transformation(id),
 inventory_lot_id uuid not null references inventory_lot(id),
 quantity_base numeric(20,6) not null,
 consumption_transaction_id uuid references inventory_transaction(id),
 check (quantity_base > 0)
)
```

## 4. silage_batch
Specialized metadata for ENSILING transformation.
```sql
silage_batch (
 transformation_id uuid primary key references post_harvest_transformation(id),
 storage_location_id uuid not null references location(id),
 ensiled_at timestamptz not null,
 sealed_at timestamptz,
 opened_at timestamptz,
 target_dry_matter_percent numeric(8,4),
 measured_dry_matter_percent numeric(8,4),
 fermentation_status varchar(30),
 density_kg_m3 numeric(20,6),
 check (target_dry_matter_percent is null or target_dry_matter_percent between 0 and 100),
 check (measured_dry_matter_percent is null or measured_dry_matter_percent between 0 and 100)
)
```

## 5. silage_observation
```sql
silage_observation (
 id uuid primary key,
 transformation_id uuid not null references silage_batch(transformation_id),
 observed_at timestamptz not null,
 observation_type varchar(60) not null,
 value_numeric numeric(20,6),
 value_text text,
 uom_id uuid references uom(id),
 recorded_by uuid references user_account(id)
)
```
Examples: temperature, pH, dry matter, smell/visual assessment. Lab analysis later links as evidence.

## 6. Feed convergence
If silage output is usable as feed, its output inventory item has `feed_item` semantics and/or a `feed_product` mapping. Feeding consumes the same inventory lot. There is no separate silage stock table.

```text
Field → Corn Crop Cycle → Harvest Lot → ENSILING Transformation
→ Silage Inventory Lot → Feed Product/Item → Feeding Program → Feeding Event
```

## 7. Traceability
Reverse tracing must answer which fields/crop cycles/harvest lots contributed to a silage batch and which livestock later received the resulting lot.

## 8. Events
HarvestRecorded, HarvestLotCreated, PostHarvestTransformationStarted, SilageEnsiled, SilageBatchCompleted, SilageOpened, FarmProducedFeedLotReleased.

## 9. Acceptance
Harvest quantity enters inventory exactly once; multiple harvest lots may feed one silage batch; actual transformation input/output quantities are retained; silage losses can be reconciled; resulting feed uses normal feed-policy/inventory controls; field-to-animal traceability is possible.
