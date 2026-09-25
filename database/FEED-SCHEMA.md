# Database Pass 3B — Feed, Formula, Batch & Feeding Schema

**Status:** Canonical implementation baseline  
**Depends on:** Foundation, Livestock, Inventory

## 1. Core flow
```text
Purchased Ingredient ─┐
                      ├→ Inventory Lot → Formula/Batch → Feed Product Lot ─┐
Purchased Finished ────────────────────────────────────────────────────────┤
                                                                          ↓
Feeding Program → Assignment → Feeding Event → Inventory Consumption
```
Purchased and farm-produced feed converge before downstream feeding.

## 2. feed_item
Feed semantics attached to a canonical inventory item.
```sql
feed_item (
 id uuid primary key,
 farm_id uuid references farm(id),
 inventory_item_id uuid not null references inventory_item(id),
 feed_item_type varchar(40) not null,
 physical_form varchar(40),
 dry_matter_percent numeric(8,4),
 status varchar(30) not null,
 unique (inventory_item_id),
 check (dry_matter_percent is null or dry_matter_percent between 0 and 100)
)
```
Types include FORAGE, SILAGE, GRAIN, PROTEIN, MINERAL, VITAMIN, PREMIX, ADDITIVE, FINISHED_FEED, OTHER.

## 3. feed_product
A feed usable in feeding, whether purchased or farm-produced.
```sql
feed_product (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 inventory_item_id uuid not null references inventory_item(id),
 code varchar(80) not null,
 name varchar(200) not null,
 source_mode varchar(30) not null,
 status varchar(30) not null,
 unique (farm_id, code),
 unique (inventory_item_id)
)
```
source_mode: PURCHASED, FARM_PRODUCED, BOTH.

## 4. feed_usage_policy and rules
```sql
feed_usage_policy (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 feed_product_id uuid not null references feed_product(id),
 name varchar(150) not null,
 default_action varchar(20) not null,
 status varchar(30) not null,
 valid_from timestamptz,
 valid_to timestamptz
)

feed_usage_policy_rule (
 id uuid primary key,
 policy_id uuid not null references feed_usage_policy(id),
 species_id uuid references species(id),
 sex_code varchar(30),
 life_stage_id uuid references life_stage(id),
 management_profile_id uuid references management_profile(id),
 action varchar(20) not null,
 priority integer not null default 0,
 configuration jsonb
)
```
Actions: ALLOW, BLOCK, REQUIRE_APPROVAL. Most-specific/highest-priority rule wins. Physical possession does not imply permission to use.

## 5. feed_formula / version / component
```sql
feed_formula (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 code varchar(80) not null,
 name varchar(200) not null,
 output_feed_product_id uuid not null references feed_product(id),
 status varchar(30) not null,
 created_at timestamptz not null,
 unique (farm_id, code)
)

feed_formula_version (
 id uuid primary key,
 feed_formula_id uuid not null references feed_formula(id),
 version_no integer not null,
 batch_basis_quantity numeric(20,6) not null,
 basis_uom_id uuid not null references uom(id),
 effective_from timestamptz,
 effective_to timestamptz,
 status varchar(30) not null,
 created_at timestamptz not null,
 approved_at timestamptz,
 approved_by uuid references user_account(id),
 unique (feed_formula_id, version_no)
)

feed_formula_component (
 id uuid primary key,
 formula_version_id uuid not null references feed_formula_version(id),
 feed_item_id uuid not null references feed_item(id),
 target_quantity numeric(20,6) not null,
 uom_id uuid not null references uom(id),
 target_percent numeric(9,6),
 sequence_no integer,
 check (target_quantity > 0),
 check (target_percent is null or target_percent between 0 and 100)
)
```
A version referenced by a started/completed batch is immutable.

## 6. feed_batch and components
```sql
feed_batch (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 feed_product_id uuid not null references feed_product(id),
 formula_version_id uuid references feed_formula_version(id),
 batch_code varchar(100) not null,
 status varchar(30) not null,
 started_at timestamptz,
 completed_at timestamptz,
 target_quantity numeric(20,6),
 actual_output_quantity numeric(20,6),
 output_uom_id uuid references uom(id),
 output_inventory_lot_id uuid references inventory_lot(id),
 created_by uuid references user_account(id),
 approved_by uuid references user_account(id),
 created_at timestamptz not null,
 unique (farm_id, batch_code)
)

feed_batch_component (
 id uuid primary key,
 feed_batch_id uuid not null references feed_batch(id),
 feed_item_id uuid not null references feed_item(id),
 inventory_lot_id uuid not null references inventory_lot(id),
 target_quantity numeric(20,6),
 actual_quantity numeric(20,6) not null,
 uom_id uuid not null references uom(id),
 inventory_consumption_transaction_id uuid references inventory_transaction(id),
 check (actual_quantity > 0)
)
```
Completion atomically posts actual ingredient consumption, output production inventory, output lot genealogy and outbox event. Target quantities never drive actual stock.

## 7. feed_lot linkage
Do not create a second stock ledger. A feed lot is an `inventory_lot`. Feed-specific metadata may use:
```sql
feed_lot_detail (
 inventory_lot_id uuid primary key references inventory_lot(id),
 feed_product_id uuid not null references feed_product(id),
 feed_batch_id uuid references feed_batch(id),
 supplier_id uuid,
 declared_analysis_reference uuid
)
```
Supplier FK becomes active when Procurement/Supplier schema is introduced.

## 8. nutrient model
```sql
feed_nutrient (
 id uuid primary key,
 code varchar(80) not null unique,
 name varchar(150) not null,
 default_uom_id uuid references uom(id),
 status varchar(30) not null
)

feed_nutrient_profile (
 id uuid primary key,
 farm_id uuid references farm(id),
 subject_type varchar(30) not null,
 feed_item_id uuid references feed_item(id),
 feed_product_id uuid references feed_product(id),
 inventory_lot_id uuid references inventory_lot(id),
 formula_version_id uuid references feed_formula_version(id),
 basis varchar(30) not null,
 source_type varchar(30) not null,
 effective_at timestamptz not null,
 check (num_nonnulls(feed_item_id,feed_product_id,inventory_lot_id,formula_version_id)=1)
)

feed_nutrient_value (
 id uuid primary key,
 profile_id uuid not null references feed_nutrient_profile(id),
 nutrient_id uuid not null references feed_nutrient(id),
 value numeric(20,8) not null,
 uom_id uuid not null references uom(id),
 unique (profile_id,nutrient_id)
)
```
source_type: DECLARED, CALCULATED, LAB_MEASURED. Lab results never silently overwrite prior declared/calculated profiles.

## 9. feeding_program / versions
```sql
feeding_program (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 code varchar(80) not null,
 name varchar(200) not null,
 status varchar(30) not null,
 unique (farm_id,code)
)

feeding_program_version (
 id uuid primary key,
 feeding_program_id uuid not null references feeding_program(id),
 version_no integer not null,
 status varchar(30) not null,
 effective_from timestamptz,
 effective_to timestamptz,
 created_at timestamptz not null,
 approved_at timestamptz,
 approved_by uuid references user_account(id),
 unique (feeding_program_id,version_no)
)

feeding_program_component (
 id uuid primary key,
 program_version_id uuid not null references feeding_program_version(id),
 feed_product_id uuid not null references feed_product(id),
 quantity_per_head numeric(20,6),
 quantity_per_group numeric(20,6),
 uom_id uuid not null references uom(id),
 frequency_per_day numeric(10,4),
 timing_code varchar(40),
 sequence_no integer,
 check (num_nonnulls(quantity_per_head,quantity_per_group)=1)
)
```

## 10. feeding_program_rule
```sql
feeding_program_rule (
 id uuid primary key,
 program_version_id uuid not null references feeding_program_version(id),
 species_id uuid references species(id),
 sex_code varchar(30),
 life_stage_id uuid references life_stage(id),
 management_profile_id uuid references management_profile(id),
 reproductive_state_code varchar(50),
 lactation_state_code varchar(50),
 production_metric_code varchar(50),
 production_min numeric(20,6),
 production_max numeric(20,6),
 weight_min numeric(20,6),
 weight_max numeric(20,6),
 weight_uom_id uuid references uom(id),
 age_min_days integer,
 age_max_days integer,
 priority integer not null default 0
)
```
Resolver is explainable and returns matching rule/provenance. Reproductive/lactation/production facts are read from owning domains when available; feed does not duplicate them as truth.

## 11. livestock_feeding_assignment
Explicit constrained animal/group FKs implement conceptual LivestockSubject.
```sql
livestock_feeding_assignment (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 program_version_id uuid not null references feeding_program_version(id),
 assignment_type varchar(40) not null,
 valid_from timestamptz not null,
 valid_to timestamptz,
 status varchar(30) not null,
 reason text,
 approved_by uuid references user_account(id),
 created_at timestamptz not null,
 check (num_nonnulls(animal_id,animal_group_id)=1),
 check (valid_to is null or valid_to > valid_from)
)
```
Types: DIRECT, INHERITED, SUPPLEMENT, TEMPORARY_OVERRIDE, RESTRICTION. Individual overrides do not erase group assignments.

## 12. feeding_event and components
```sql
feeding_event (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 program_version_id uuid references feeding_program_version(id),
 assignment_id uuid references livestock_feeding_assignment(id),
 event_type varchar(30) not null,
 occurred_at timestamptz not null,
 head_count integer,
 status varchar(30) not null,
 recorded_at timestamptz not null,
 recorded_by uuid references user_account(id),
 correlation_id uuid,
 reversal_of_id uuid references feeding_event(id),
 check (num_nonnulls(animal_id,animal_group_id)=1),
 check (head_count is null or head_count > 0)
)

feeding_event_component (
 id uuid primary key,
 feeding_event_id uuid not null references feeding_event(id),
 feed_product_id uuid not null references feed_product(id),
 inventory_lot_id uuid references inventory_lot(id),
 quantity_offered numeric(20,6) not null,
 quantity_consumed_estimate numeric(20,6),
 waste_quantity numeric(20,6),
 uom_id uuid not null references uom(id),
 inventory_consumption_transaction_id uuid references inventory_transaction(id),
 check (quantity_offered >= 0),
 check (quantity_consumed_estimate is null or quantity_consumed_estimate >= 0),
 check (waste_quantity is null or waste_quantity >= 0)
)
```
Offered, consumed estimate and waste are distinct. Inventory consumption basis is configured per operation; never infer measured consumption when only offered quantity is known.

## 13. feed_allocation
Feed-specific purpose restriction layered on inventory reservation.
```sql
feed_allocation (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 inventory_reservation_id uuid not null references inventory_reservation(id),
 feed_product_id uuid not null references feed_product(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 feeding_program_version_id uuid references feeding_program_version(id),
 allocation_type varchar(40) not null,
 status varchar(30) not null,
 created_at timestamptz not null,
 check (num_nonnulls(animal_id,animal_group_id,feeding_program_version_id) >= 1)
)
```
Example: 400 kg of cattle dairy premix reserved for lactating cattle cannot be treated as general available stock.

## 14. reconciliation
```sql
feed_reconciliation (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 inventory_item_id uuid not null references inventory_item(id),
 period_start timestamptz not null,
 period_end timestamptz not null,
 opening_quantity_base numeric(20,6) not null,
 received_quantity_base numeric(20,6) not null,
 produced_quantity_base numeric(20,6) not null,
 consumed_quantity_base numeric(20,6) not null,
 waste_quantity_base numeric(20,6) not null,
 adjustment_quantity_base numeric(20,6) not null,
 expected_closing_quantity_base numeric(20,6) not null,
 counted_closing_quantity_base numeric(20,6),
 variance_quantity_base numeric(20,6),
 status varchar(30) not null,
 created_at timestamptz not null,
 approved_by uuid references user_account(id),
 check (period_end > period_start)
)
```
This is a reconciliation record derived from ledger facts; it does not become a competing inventory ledger.

## 15. Transactional behavior
Before any mixing or feeding issue:
1. calculate eligible available inventory;
2. validate lot status/expiry;
3. evaluate feed usage policy for target species/profile;
4. validate reservation/allocation;
5. lock/serialize affected stock scope as implementation requires;
6. post inventory transaction;
7. post feed business record;
8. insert outbox event;
9. commit atomically.

Unauthorized cross-species use is blocked before stock movement.

## 16. Traceability
```text
Supplier/Receipt Lot
 → Ingredient Inventory Lot
 → Feed Batch Component
 → Feed Batch
 → Output Inventory Lot
 → Feeding Event Component
 → Animal/Group
```
Reverse query must identify exposed animals/groups from any ingredient/output lot.

## 17. Events
FeedFormulaVersionActivated, FeedBatchStarted, FeedBatchCompleted, FeedBatchQuarantined, FeedLotReceived, FeedUsageBlocked, FeedAllocationCreated, FeedAllocationReleased, FeedingProgramActivated, FeedingProgramAssigned, FeedingProgramReviewRequired, FeedingEventRecorded, FeedInventoryConsumed, FeedAnalysisReceived, FeedReconciliationCompleted, FeedInventoryVarianceDetected.

## 18. Acceptance
- Formula != batch != feeding program != feeding event.
- Purchased and produced feeds share downstream lot/feeding behavior.
- Actual batch ingredients drive stock/cost.
- Cattle-only premix is blocked from horse/sheep use.
- Group feeding and individual supplement/override coexist.
- Offered quantity is not falsely recorded as consumed.
- All feed stock uses inventory ledger, not shadow balances.
- Ingredient lot → exposed animals/groups traceability is queryable.
- Formula/program versions used historically are immutable.
