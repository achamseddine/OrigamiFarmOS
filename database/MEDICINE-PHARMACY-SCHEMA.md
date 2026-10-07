# Medicine & Farm Pharmacy Management

**Status:** Canonical implementation baseline  
**Depends on:** Foundation, Inventory, Health/Veterinary, Procurement  
**Purpose:** Manage medicines as stocked farm supplies before, during and after clinical use.

## 1. Core principle
A farm pharmacy is not merely a treatment history. Origami must know what medicine the farm owns, where it is stored, exact lot/expiry, what is available, what must always be kept in stock, and when replenishment is required.

Inventory remains the physical stock ledger. This module adds pharmaceutical semantics and pharmacy policy; it never creates a second medicine stock balance.

## 2. medicine_product
Extends a canonical `inventory_item`.
```sql
medicine_product (
 inventory_item_id uuid primary key references inventory_item(id),
 generic_name varchar(200),
 brand_name varchar(200),
 dosage_form varchar(60) not null,
 strength_value numeric(20,6),
 strength_uom_id uuid references uom(id),
 strength_basis varchar(80),
 administration_routes jsonb,
 prescription_required boolean not null default false,
 antimicrobial boolean not null default false,
 controlled_medicine boolean not null default false,
 cold_chain_required boolean not null default false,
 storage_min_c numeric(8,3),
 storage_max_c numeric(8,3),
 opened_shelf_life_days integer,
 default_pack_size numeric(20,6),
 pack_uom_id uuid references uom(id),
 manufacturer_name varchar(200),
 authorization_reference varchar(150),
 active boolean not null default true
)
```
Examples include injectable medicines, oral medicines, IV fluids, electrolytes, vaccines and other veterinary pharmaceutical products.

## 3. medicine_active_ingredient
```sql
medicine_active_ingredient (
 id uuid primary key,
 code varchar(80) not null unique,
 name varchar(180) not null,
 active boolean not null default true
)

medicine_product_ingredient (
 medicine_product_id uuid not null references medicine_product(inventory_item_id),
 active_ingredient_id uuid not null references medicine_active_ingredient(id),
 concentration_value numeric(20,6),
 concentration_uom_id uuid references uom(id),
 concentration_basis varchar(80),
 primary key (medicine_product_id,active_ingredient_id)
)
```

## 4. medicine_category
Categories support organization/search and essential-stock policies; they are not diagnoses.
```sql
medicine_category (
 id uuid primary key,
 code varchar(80) not null unique,
 name varchar(150) not null,
 active boolean not null default true
)

medicine_product_category (
 medicine_product_id uuid not null references medicine_product(inventory_item_id),
 category_id uuid not null references medicine_category(id),
 primary key (medicine_product_id,category_id)
)
```
Starter configurable categories may include FEVER_SUPPORT, PAIN_INFLAMMATION, COLIC_SUPPORT, IV_FLUID, ELECTROLYTE, ANTIBIOTIC, ANTIPARASITIC, VACCINE, WOUND_CARE and OTHER. Category membership never authorizes treatment.

## 5. pharmacy_stock_policy
The farm user decides which medicines are essential and the minimum quantities to keep.
```sql
pharmacy_stock_policy (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 inventory_item_id uuid not null references medicine_product(inventory_item_id),
 location_id uuid references location(id),
 essential boolean not null default false,
 minimum_stock_base numeric(20,6),
 target_stock_base numeric(20,6),
 critical_stock_base numeric(20,6),
 minimum_days_cover numeric(12,4),
 lead_time_days numeric(10,2),
 preferred_supplier_id uuid references supplier(id),
 alert_enabled boolean not null default true,
 expiry_warning_days integer not null default 60,
 active boolean not null default true,
 updated_by uuid references user_account(id),
 updated_at timestamptz not null,
 unique (farm_id,inventory_item_id,location_id),
 check (minimum_stock_base is null or minimum_stock_base >= 0),
 check (target_stock_base is null or target_stock_base >= 0),
 check (critical_stock_base is null or critical_stock_base >= 0)
)
```
Example: Farm manager marks a 0.9% IV fluid product essential and sets minimum eligible stock to 12 × 1-L bags and target stock to 24. Thresholds are user/farm configuration, not hard-coded medical advice.

## 6. medicine_lot_detail
Pharmacy metadata extends the canonical `inventory_lot`.
```sql
medicine_lot_detail (
 inventory_lot_id uuid primary key references inventory_lot(id),
 opened_at timestamptz,
 use_by_after_opening timestamptz,
 storage_status varchar(30) not null default 'COMPLIANT',
 cold_chain_exception boolean not null default false,
 quarantine_reason text,
 recalled_at timestamptz,
 recall_reference varchar(150)
)
```
Medicine products require lot and expiry tracking by policy unless an explicitly approved exception exists.

## 7. pharmacy availability
```text
Eligible Pharmacy Stock
= On Hand
- Quarantined
- Blocked
- Recalled
- Expired
- Reserved for another protected purpose
```
An expired/recalled/quarantined lot never satisfies the essential-stock minimum.

## 8. pharmacy_stock_alert
```sql
pharmacy_stock_alert (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 inventory_item_id uuid not null references medicine_product(inventory_item_id),
 location_id uuid references location(id),
 alert_type varchar(50) not null,
 severity varchar(20) not null,
 detected_at timestamptz not null,
 eligible_available_base numeric(20,6),
 minimum_stock_base numeric(20,6),
 target_stock_base numeric(20,6),
 earliest_expiry_date date,
 recommended_reorder_base numeric(20,6),
 status varchar(30) not null,
 acknowledged_by uuid references user_account(id),
 acknowledged_at timestamptz,
 resolved_at timestamptz,
 deduplication_key varchar(255) not null
)
```
Alert types:
- BELOW_MINIMUM_STOCK
- CRITICAL_STOCK
- OUT_OF_STOCK
- LOW_DAYS_COVER
- EXPIRING_SOON
- EXPIRED_STOCK
- RECALL_AFFECTED
- STORAGE_EXCEPTION

Acknowledgement does not resolve the underlying stock condition.

## 9. Replenishment
For static minimum policy:
```text
recommended_reorder = max(0, target_stock - eligible_available - confirmed_incoming)
```
Pack size/minimum order quantity can round the recommendation. An alert/recommendation may create a DRAFT purchase requisition but never approves purchasing.

## 10. Essential medicine dashboard
Farm users can configure their own essential list. Dashboard exposes:
- medicine/category;
- eligible available quantity;
- minimum/critical/target;
- lot count;
- earliest expiry;
- expiring quantity;
- storage exception;
- open reorder;
- stock status: OK / LOW / CRITICAL / OUT.

Examples such as fever-support products, colic-support products and IV fluids are configurable categories/products; Origami does not recommend that a specific medicine be administered merely because it is stocked.

## 11. Treatment integration
Treatment prescription/action selects the medicine product. Administration selects the actual eligible lot and atomically:
1. validates authorization and treatment context;
2. validates lot/expiry/storage/recall status;
3. records dose/route/time/subject;
4. posts inventory consumption;
5. calculates applicable withdrawal restrictions from authorized product rules;
6. emits MedicationAdministered;
7. recalculates pharmacy threshold status.

## 12. Events
MedicineProductConfigured, EssentialMedicinePolicyChanged, MedicineStockBelowMinimum, MedicineStockCritical, MedicineOutOfStock, MedicineExpiringSoon, MedicineExpired, MedicineRecallAffected, MedicineStorageExceptionDetected, MedicineReorderRequired, MedicineStockRecovered.

## 13. Acceptance
1. A farm can maintain medicine stock even when no animal is currently sick.
2. Each receipt records medicine lot and expiry.
3. Farm manager sets minimum/target quantities per medicine/location.
4. Eligible stock below minimum creates one deduplicated active alert/notification.
5. Critical/out-of-stock escalation is distinct from ordinary low stock.
6. Expired/recalled/quarantined medicine does not count toward minimum.
7. Administration consumes exact lot and immediately re-evaluates stock threshold.
8. Suggested reorder can create a draft requisition without bypassing approval.
9. Essential categories are configurable; stocking a product never authorizes its clinical use.
