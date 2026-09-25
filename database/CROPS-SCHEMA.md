# Database Pass 6A — Fields, Crops, Crop Cycles & Field Operations

**Status:** Canonical implementation baseline  
**Depends on:** Foundation, Inventory, Costing  
**Integrates with:** Feed, Procurement, Assets, Laboratory

## 1. Boundary
Crops owns agronomic planning and field execution. Inventory owns physical inputs/outputs. Assets owns machinery. Costing owns operational cost facts. A planned application is not inventory consumption; a planned harvest is not stock.

## 2. field
A field/plot is an agricultural production unit linked to canonical Location.
```sql
field (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 location_id uuid not null unique references location(id),
 code varchar(80) not null,
 name varchar(150) not null,
 area numeric(20,6) not null,
 area_uom_id uuid not null references uom(id),
 irrigation_type varchar(50),
 soil_type_code varchar(60),
 status varchar(30) not null,
 created_at timestamptz not null,
 updated_at timestamptz not null,
 unique (farm_id,code),
 check (area > 0)
)
```

## 3. crop / cultivar
```sql
crop (
 id uuid primary key,
 code varchar(80) not null unique,
 name varchar(150) not null,
 scientific_name varchar(180),
 active boolean not null default true
)

cultivar (
 id uuid primary key,
 crop_id uuid not null references crop(id),
 code varchar(80) not null,
 name varchar(150) not null,
 active boolean not null default true,
 unique (crop_id,code)
)
```

## 4. crop_cycle
```sql
crop_cycle (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 field_id uuid not null references field(id),
 crop_id uuid not null references crop(id),
 cultivar_id uuid references cultivar(id),
 cycle_code varchar(100) not null,
 planned_planting_date date,
 actual_planting_date date,
 expected_harvest_start date,
 actual_harvest_end date,
 planted_area numeric(20,6),
 area_uom_id uuid references uom(id),
 status varchar(30) not null,
 production_purpose varchar(50),
 created_at timestamptz not null,
 updated_at timestamptz not null,
 unique (farm_id,cycle_code)
)
```
Purposes include FEED, SALE, SEED, MIXED.

## 5. field_operation
```sql
field_operation (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 crop_cycle_id uuid not null references crop_cycle(id),
 operation_type varchar(60) not null,
 planned_at timestamptz,
 started_at timestamptz,
 completed_at timestamptz,
 status varchar(30) not null,
 area_treated numeric(20,6),
 area_uom_id uuid references uom(id),
 performed_by uuid references user_account(id),
 notes text,
 created_at timestamptz not null
)
```
Examples: PLOW, PLANT, IRRIGATE, FERTILIZE, SPRAY, WEED, HARVEST_PREP.

## 6. field_operation_input
```sql
field_operation_input (
 id uuid primary key,
 field_operation_id uuid not null references field_operation(id),
 inventory_item_id uuid not null references inventory_item(id),
 inventory_lot_id uuid references inventory_lot(id),
 planned_quantity numeric(20,6),
 actual_quantity numeric(20,6),
 uom_id uuid not null references uom(id),
 inventory_consumption_transaction_id uuid references inventory_transaction(id)
)
```
Only completed/posted actual use consumes inventory.

## 7. field_observation
```sql
field_observation (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 crop_cycle_id uuid references crop_cycle(id),
 field_id uuid not null references field(id),
 observation_type varchar(60) not null,
 observed_at timestamptz not null,
 value_numeric numeric(20,6),
 value_text text,
 uom_id uuid references uom(id),
 severity_code varchar(30),
 geometry jsonb,
 recorded_by uuid references user_account(id),
 recorded_at timestamptz not null
)
```
Observation is evidence, not automatically diagnosis/recommendation.

## 8. irrigation_event
```sql
irrigation_event (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 crop_cycle_id uuid references crop_cycle(id),
 field_id uuid not null references field(id),
 started_at timestamptz not null,
 ended_at timestamptz,
 water_quantity numeric(20,6),
 uom_id uuid references uom(id),
 source_code varchar(60),
 asset_id uuid,
 energy_cost_entry_id uuid references cost_entry(id),
 recorded_at timestamptz not null
)
```
Asset FK becomes active with Pass 6C asset table.

## 9. Events
CropCycleCreated, CropPlanted, FieldOperationCompleted, CropInputApplied, IrrigationRecorded, FieldObservationRecorded, CropReadyForHarvest.

## 10. Acceptance
Multiple crop cycles retain history per field; planned inputs do not reduce inventory; actual seed/fertilizer/etc. uses traceable lots; field/cycle costs can be derived; irrigation is measurable; crop output can flow into harvest inventory without creating a separate stock truth.
