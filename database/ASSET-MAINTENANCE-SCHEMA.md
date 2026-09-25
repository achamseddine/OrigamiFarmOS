# Database Pass 6C — Assets, Machinery, Maintenance & Metering

**Status:** Canonical implementation baseline  
**Depends on:** Foundation, Inventory, Costing

## 1. Boundary
Asset = durable resource. Inventory item = consumable/stock master. Spare parts consumed during maintenance remain inventory; the machine itself is an asset.

## 2. asset
```sql
asset (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 code varchar(80) not null,
 name varchar(180) not null,
 asset_type varchar(60) not null,
 manufacturer varchar(120),
 model varchar(120),
 serial_number varchar(150),
 acquisition_date date,
 acquisition_cost numeric(20,4),
 currency char(3),
 current_location_id uuid references location(id),
 status varchar(30) not null,
 parent_asset_id uuid references asset(id),
 created_at timestamptz not null,
 updated_at timestamptz not null,
 unique (farm_id,code)
)
```
Examples: tractor, pump, generator, sprinkler system, mixer wagon, milking machine, cooling tank, incubator.

## 3. asset_meter
```sql
asset_meter (
 id uuid primary key,
 asset_id uuid not null references asset(id),
 meter_type varchar(50) not null,
 uom_id uuid not null references uom(id),
 rollover_value numeric(20,6),
 active boolean not null default true
)

asset_meter_reading (
 id uuid primary key,
 asset_meter_id uuid not null references asset_meter(id),
 reading_value numeric(20,6) not null,
 measured_at timestamptz not null,
 recorded_by uuid references user_account(id),
 recorded_at timestamptz not null
)
```
Examples: engine hours, kilometers, pump hours, energy meter.

## 4. maintenance_plan
```sql
maintenance_plan (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 asset_id uuid not null references asset(id),
 plan_type varchar(40) not null,
 interval_days integer,
 meter_id uuid references asset_meter(id),
 interval_meter_quantity numeric(20,6),
 next_due_date date,
 next_due_meter numeric(20,6),
 active boolean not null default true
)
```
Supports calendar, meter or combined preventive maintenance.

## 5. maintenance_work_order
```sql
maintenance_work_order (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 asset_id uuid not null references asset(id),
 work_order_no varchar(80) not null,
 maintenance_plan_id uuid references maintenance_plan(id),
 work_type varchar(50) not null,
 priority varchar(30) not null,
 status varchar(30) not null,
 requested_at timestamptz not null,
 scheduled_at timestamptz,
 started_at timestamptz,
 completed_at timestamptz,
 requested_by uuid references user_account(id),
 assigned_to uuid references user_account(id),
 problem_description text,
 resolution_notes text,
 downtime_minutes integer,
 unique (farm_id,work_order_no)
)
```

## 6. maintenance_part
```sql
maintenance_part (
 id uuid primary key,
 work_order_id uuid not null references maintenance_work_order(id),
 inventory_item_id uuid not null references inventory_item(id),
 inventory_lot_id uuid references inventory_lot(id),
 planned_quantity numeric(20,6),
 actual_quantity numeric(20,6),
 uom_id uuid not null references uom(id),
 consumption_transaction_id uuid references inventory_transaction(id)
)
```
Actual posted use consumes inventory atomically.

## 7. maintenance_labor
```sql
maintenance_labor (
 id uuid primary key,
 work_order_id uuid not null references maintenance_work_order(id),
 user_id uuid references user_account(id),
 external_provider varchar(180),
 started_at timestamptz,
 ended_at timestamptz,
 hours numeric(10,4),
 cost_amount numeric(20,4),
 currency char(3)
)
```

## 8. asset_inspection / calibration
```sql
asset_inspection (
 id uuid primary key,
 asset_id uuid not null references asset(id),
 inspection_type varchar(60) not null,
 inspected_at timestamptz not null,
 result_code varchar(40) not null,
 findings jsonb,
 next_due_at timestamptz,
 inspected_by uuid references user_account(id)
)

asset_calibration (
 id uuid primary key,
 asset_id uuid not null references asset(id),
 calibrated_at timestamptz not null,
 result_code varchar(40) not null,
 certificate_reference varchar(200),
 next_due_at timestamptz,
 calibrated_by uuid references user_account(id)
)
```

## 9. asset_usage
Links asset utilization to farm work without embedding every domain in Asset.
```sql
asset_usage (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 asset_id uuid not null references asset(id),
 usage_type varchar(60) not null,
 source_type varchar(80),
 source_id uuid,
 started_at timestamptz not null,
 ended_at timestamptz,
 meter_start numeric(20,6),
 meter_end numeric(20,6),
 operator_user_id uuid references user_account(id),
 cost_entry_id uuid references cost_entry(id)
)
```

## 10. Events
AssetRegistered, AssetMoved, MeterReadingRecorded, MaintenanceDue, WorkOrderCreated, MaintenanceStarted, MaintenanceCompleted, AssetOutOfService, AssetReturnedToService, InspectionFailed, CalibrationDue.

## 11. Acceptance
Tractors/pumps/milking equipment are not inventory consumables; parts and lubricants are; preventive maintenance can be calendar/meter driven; downtime/history/cost are retained; field operations can reference asset use; maintenance costs can flow to cost centers without changing asset history.
