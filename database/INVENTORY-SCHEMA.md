# Database Pass 3A — Inventory & Stock Ledger

**Status:** Canonical implementation baseline  
**Depends on:** Foundation Schema  
**Used by:** Feed, veterinary, crops, maintenance, procurement, production

## 1. Invariant
Inventory truth is an append-only ledger. No authoritative editable `quantity_on_hand` column exists.

```text
On Hand = SUM(posted inventory transaction quantities)
Available = On Hand - Active Reservations - Quarantined - Blocked
```

Balances may be cached as rebuildable projections.

## 2. inventory_item
```sql
inventory_item (
 id uuid primary key,
 farm_id uuid references farm(id),
 code varchar(80) not null,
 name varchar(200) not null,
 item_category varchar(60) not null,
 base_uom_id uuid not null references uom(id),
 lot_tracking_required boolean not null default true,
 expiry_tracking_required boolean not null default false,
 status varchar(30) not null,
 created_at timestamptz not null,
 updated_at timestamptz not null,
 unique (farm_id, code)
)
```
Null farm_id may later support organization/global catalog items; operational stock is always farm-scoped.

## 3. inventory_lot
```sql
inventory_lot (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 inventory_item_id uuid not null references inventory_item(id),
 lot_code varchar(120) not null,
 supplier_lot_code varchar(120),
 manufactured_at timestamptz,
 received_at timestamptz,
 expiry_date date,
 status varchar(30) not null,
 quality_status varchar(30) not null default 'RELEASED',
 source_type varchar(40) not null,
 source_reference_type varchar(80),
 source_reference_id uuid,
 unit_cost numeric(20,6),
 currency char(3),
 created_at timestamptz not null,
 unique (farm_id, inventory_item_id, lot_code)
)
```
Quality statuses include RELEASED, QUARANTINED, BLOCKED, RECALLED, EXPIRED. Status changes are audited/events and do not rewrite ledger history.

## 4. inventory_transaction
Every posted movement has signed base-UOM quantity.
```sql
inventory_transaction (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 inventory_item_id uuid not null references inventory_item(id),
 inventory_lot_id uuid references inventory_lot(id),
 location_id uuid not null references location(id),
 transaction_type varchar(40) not null,
 quantity_base numeric(20,6) not null,
 base_uom_id uuid not null references uom(id),
 entered_quantity numeric(20,6),
 entered_uom_id uuid references uom(id),
 occurred_at timestamptz not null,
 posted_at timestamptz not null,
 source_reference_type varchar(80),
 source_reference_id uuid,
 reversal_of_id uuid references inventory_transaction(id),
 unit_cost numeric(20,6),
 currency char(3),
 actor_user_id uuid references user_account(id),
 correlation_id uuid,
 notes text,
 check (quantity_base <> 0)
)
```
Types include RECEIPT, ISSUE, CONSUMPTION, PRODUCTION_OUTPUT, TRANSFER_OUT, TRANSFER_IN, RETURN_IN, RETURN_OUT, WASTE, ADJUSTMENT_GAIN, ADJUSTMENT_LOSS.

Transfers create paired OUT/IN rows sharing correlation/source; never mutate location on a lot to fake a transfer. Posted rows are immutable. Corrections post reversal/new rows.

## 5. inventory_reservation
```sql
inventory_reservation (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 inventory_item_id uuid not null references inventory_item(id),
 inventory_lot_id uuid references inventory_lot(id),
 location_id uuid references location(id),
 quantity_base numeric(20,6) not null,
 base_uom_id uuid not null references uom(id),
 purpose_type varchar(80) not null,
 purpose_id uuid,
 valid_from timestamptz not null,
 valid_to timestamptz,
 status varchar(30) not null,
 created_at timestamptz not null,
 created_by uuid references user_account(id),
 check (quantity_base > 0),
 check (valid_to is null or valid_to > valid_from)
)
```
Reservation is not consumption. Issue/consumption releases or reduces the reservation atomically.

## 6. stock_count and lines
```sql
stock_count (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 location_id uuid not null references location(id),
 status varchar(30) not null,
 counted_at timestamptz,
 posted_at timestamptz,
 created_by uuid references user_account(id),
 approved_by uuid references user_account(id),
 created_at timestamptz not null
)

stock_count_line (
 id uuid primary key,
 stock_count_id uuid not null references stock_count(id),
 inventory_item_id uuid not null references inventory_item(id),
 inventory_lot_id uuid references inventory_lot(id),
 system_quantity_base numeric(20,6) not null,
 counted_quantity_base numeric(20,6) not null,
 variance_quantity_base numeric(20,6) not null,
 adjustment_transaction_id uuid references inventory_transaction(id)
)
```
Count approval creates explicit adjustment ledger rows; it never overwrites balance.

## 7. inventory_balance_projection
Rebuildable projection keyed by farm/item/lot/location:
on_hand, reserved, quarantined_or_blocked, available, last_transaction_at. It is not business truth.

## 8. Controls
- Lot/item/location/farm compatibility enforced.
- Transaction base UOM dimension must match item base UOM.
- Expired/recalled/blocked/quarantined lots cannot be issued for ordinary consumption.
- Negative stock policy is configurable; default BLOCK.
- Reservations cannot exceed eligible available stock unless explicit approved override policy exists.
- FEFO can be recommended for expiring feed/medicine; it is selection logic, not ledger truth.

## 9. Events
InventoryReceived, InventoryIssued, InventoryConsumed, InventoryTransferred, InventoryWasted, InventoryAdjusted, InventoryReserved, InventoryReservationReleased, InventoryLotQuarantined, InventoryLotReleased, InventoryLotBlocked, InventoryLotRecalled, StockCountPosted.

## 10. Acceptance
The system can reconstruct stock by item/lot/location/time; distinguish received from ordered; prevent reserved/quarantined stock from appearing available; trace every adjustment; and reconcile physical count without editing history.
