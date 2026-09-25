# Generic Feed, Formula, Batch & Feeding Program Architecture

**Project:** Origami FarmOS  
**Purpose:** Developer handoff for Claude / GitHub implementation  
**Status:** Development specification  
**Companion:** `GENERIC-ANIMAL-CAPABILITY-MODEL.md`

## 1. Core design decision

Origami FarmOS must not implement separate feeding architectures for cattle, sheep, goats, horses, poultry, or other species.

Feeding is generic and configuration-driven:

```text
Species + Sex + Life Stage + Management/Production Profile
+ Physiological State + Production State
                         |
                         v
                 Feed Requirement Profile
                         |
                         v
                  Feeding Program
                         |
              +----------+----------+
              |                     |
       Purchased Feed          Farm-Mixed Feed
                                    |
                               Feed Formula
                                    |
                                Feed Batch
              |                     |
              +----------+----------+
                         |
                    Feeding Event
                         |
                   Animal / Group
```

The architecture must distinguish:
- what a feed is;
- what ingredients/formula define it;
- what was actually mixed;
- what feeding program applies to an animal/group;
- what was actually offered/fed;
- what inventory and cost were consumed.

## 2. Core concepts

### 2.1 Feed Item / Ingredient

A raw material or purchasable input, e.g. corn silage, hay, barley, soybean meal, mineral premix.

### 2.2 Finished Feed Product

A feed usable downstream for feeding. It may be:
- purchased finished feed; or
- produced/mixed on farm.

Downstream feeding logic should not need separate implementations for purchased versus farm-produced feed.

### 2.3 Feed Formula

A recipe defining intended composition. A formula is not an actual batch and is not an animal assignment.

### 2.4 Feed Batch

A physical production/mixing occurrence. It records what was actually used and produced.

### 2.5 Feeding Program / Ration

Defines what an eligible animal/group should receive, quantities, frequency, timing, and applicability.

### 2.6 Feeding Event

Records what was actually offered/delivered/consumed or estimated consumed, according to configured measurement capability.

## 3. Purchased versus farm-mixed feed

```text
                  FEED PRODUCT
                       |
          +------------+------------+
          |                         |
     PURCHASED                  PRODUCED
    FINISHED FEED               ON FARM
          |                         |
     Supplier Lot               Feed Formula
                                    |
                              Mixing Batch
                                    |
                    +---------------+
                    v
                 INVENTORY
                    |
                    v
             FEEDING PROGRAM
                    |
                    v
             LIVESTOCK SUBJECT
                /          \
             Animal      Animal Group
```

Purchased finished feed must retain supplier, purchase, lot, expiry and cost traceability.

Farm-produced feed must retain formula version, actual ingredient lots/quantities, production date, batch quantity and cost traceability.

## 4. Feeding applicability

A feeding program must not be determined by species alone.

Resolution should consider:

```text
Species
+ Sex
+ Life Stage
+ Management / Production Profile
+ Reproductive State
+ Lactation State
+ Production Band
+ Weight / Age where applicable
= Feeding Program Eligibility
```

Examples:

| Animal profile | Program category |
|---|---|
| Dairy cow — fresh | Fresh-cow ration |
| Dairy cow — lactating/high production | High-production dairy ration |
| Dairy cow — lactating/medium production | Medium-production dairy ration |
| Dairy cow — dry | Dry-cow ration |
| Dairy calf | Milk/milk replacer + starter |
| Dairy heifer | Growing-heifer ration |
| Breeding bull | Breeding/maintenance ration |
| Pregnant ewe | Gestation ration |
| Lactating ewe | Lactation ration |
| Lamb | Starter/grower |
| Pregnant mare | Pregnant-mare ration |
| Lactating mare | Lactating-mare ration |
| Foal/yearling | Growth ration |
| Stallion | Breeding/maintenance ration |
| Layer hen/flock | Layer ration |
| Broiler flock | Starter → grower → finisher |

A horse is therefore not one feeding profile, and cattle are not one feeding profile.

## 5. Feed formula versus feeding program

These concepts must never be merged.

Example formula:

```text
DAIRY-CONCENTRATE-18
Ingredient A ...
Ingredient B ...
Mineral premix ...
```

Example feeding program:

```text
HIGH-PRODUCTION-DAIRY

Morning
- Corn silage: 12 kg/head
- Hay: 3 kg/head
- Dairy concentrate: 6 kg/head

Evening
- Corn silage: 12 kg/head
- Hay: 3 kg/head
- Dairy concentrate: 6 kg/head
```

Alternatively a program may assign a TMR:

```text
TMR-DAIRY-HIGH
32 kg/head/day
2 deliveries/day
```

The formula defines a product; the feeding program defines its use.

## 6. Formula versioning

Feed formulas are versioned and historical versions are immutable once used.

```text
Dairy 24L
 ├── v1 RETIRED
 ├── v2 RETIRED
 └── v3 ACTIVE
```

Changing ingredient percentages, nutrient targets or other material recipe attributes creates a new version.

Historical batches must continue to resolve to the exact formula version used.

## 7. Formula versus actual batch

The system must preserve intended and actual composition.

Example target:

```text
Formula: Dairy Mix 24L v3
Corn silage       400 kg
Hay               200 kg
Concentrate       350 kg
Barley             40 kg
Mineral premix     10 kg
-------------------------
Target           1,000 kg
```

Example actual:

```text
Batch MIX-2026-0925-01
Corn silage       398 kg
Hay               205 kg
Concentrate       347 kg
Barley             40 kg
Mineral premix     10 kg
-------------------------
Actual           1,000 kg
```

Actual quantities drive inventory consumption and actual batch costing. Target quantities remain available for variance analysis.

## 8. Nutrient model

Feed items/products/formulas may carry nutrient profiles. The model must be extensible and unit-aware rather than hard-coding a fixed nutrient list.

Examples may include:
- dry matter;
- crude protein;
- energy measures;
- fiber measures;
- fat;
- minerals;
- vitamins;
- moisture;
- other species/program-specific analytes.

Nutrient values must retain basis and unit where relevant, e.g. as-fed versus dry-matter basis.

Laboratory feed analysis should be able to update/associate measured nutrient profiles without destroying declared or calculated values.

## 9. Individual and group feeding

Feeding should normally operate efficiently at group level while allowing individual exceptions.

```text
HIGH PRODUCTION GROUP
27 cows
        |
Dairy High Feeding Program
        |
32 kg/head/day
        |
864 kg planned/day
```

An individual may inherit the group program and receive an override/supplement:

```text
Cow 744
Base program: inherited from HIGH PRODUCTION GROUP
Individual supplement: +2 kg concentrate/day
```

The system must distinguish inherited program, explicit individual assignment, supplement, temporary override and veterinary/management restriction.

## 10. Lifecycle-driven feeding review

Animal events may trigger a feeding-program recommendation or review, but must not silently change feeding without configured authorization.

Cattle example:

```text
Birth
 -> Calf Program
 -> Weaning
 -> Grower Program
 -> Heifer Program
 -> Pregnancy
 -> Pregnant Heifer Program
 -> Close-up
 -> Calving
 -> Fresh Cow Program
 -> Lactation Production Band
 -> Dry-off
 -> Dry Cow Program
```

Horse example:

```text
Mare
 -> Pregnancy confirmed
 -> Pregnant Mare Program
 -> Late Gestation Program
 -> Foaling
 -> Lactating Mare Program
```

Relevant events should raise `FeedingProgramReviewRequired` and create a review task through the workflow architecture where appropriate.

## 11. Production-band support

Programs may use production metrics as eligibility criteria.

Example:

```text
Cattle
+ Female
+ Adult
+ Dairy
+ Lactating
+ Milk 20–30 L/day
= DAIRY-20-30-L feeding program
```

Production thresholds are configuration, not hard-coded logic.

The recommendation engine may suggest a program based on current animal data. A recommendation is not an autonomous feeding decision unless the farm explicitly enables approved automation.

## 12. Feed traceability

Origami should be able to answer:

```text
What did this animal/group receive?
        |
Feeding Event
        |
Feed Product / Batch
        |
Formula Version
        |
Ingredient Lots
        |
Supplier / Farm Production
```

It should also support reverse traceability:

```text
Ingredient Lot
        |
Feed Batches
        |
Feeding Events
        |
Animals / Groups Exposed
```

This is essential for recalls, contamination investigation, performance analysis and costing.

## 13. Suggested database model

```text
feed_item
- id UUID PK
- code
- name
- item_type
- default_uom_id
- status

feed_product
- id UUID PK
- code
- name
- source_type ENUM(PURCHASED, FARM_PRODUCED)
- status

feed_formula
- id UUID PK
- code
- name
- status

feed_formula_version
- id UUID PK
- feed_formula_id FK
- version
- effective_from
- effective_to nullable
- status

feed_formula_component
- id UUID PK
- formula_version_id FK
- feed_item_id FK
- target_quantity
- uom_id FK
- target_percentage nullable

feed_batch
- id UUID PK
- feed_product_id FK
- formula_version_id FK nullable
- batch_code
- produced_at
- target_quantity nullable
- actual_quantity
- uom_id FK
- status

feed_batch_component
- id UUID PK
- feed_batch_id FK
- feed_item_id FK
- inventory_lot_id FK nullable
- target_quantity nullable
- actual_quantity
- uom_id FK

feed_lot
- id UUID PK
- feed_product_id FK
- lot_code
- source_type
- supplier_id nullable
- feed_batch_id nullable
- received_or_produced_at
- expiry_date nullable
- status

feed_nutrient
- id UUID PK
- code
- name
- default_uom_id
- status

feed_nutrient_profile
- id UUID PK
- subject_type
- subject_id
- basis
- source_type
- effective_at

feed_nutrient_value
- id UUID PK
- profile_id FK
- nutrient_id FK
- value
- uom_id FK

feeding_program
- id UUID PK
- code
- name
- status

feeding_program_version
- id UUID PK
- feeding_program_id FK
- version
- effective_from
- effective_to nullable
- status

feeding_program_component
- id UUID PK
- program_version_id FK
- feed_product_id FK
- quantity
- uom_id FK
- frequency
- timing nullable

feeding_program_rule
- id UUID PK
- program_version_id FK
- species_id FK nullable
- sex nullable
- life_stage_id nullable
- management_profile_id nullable
- reproductive_state nullable
- lactation_state nullable
- production_metric nullable
- production_min nullable
- production_max nullable
- weight_min nullable
- weight_max nullable
- age_min nullable
- age_max nullable
- priority

livestock_feeding_assignment
- id UUID PK
- livestock_subject_id FK
- program_version_id FK
- assignment_type
- valid_from
- valid_to nullable
- status

feeding_event
- id UUID PK
- livestock_subject_id FK
- program_version_id FK nullable
- occurred_at
- event_type
- head_count nullable
- status

feeding_event_component
- id UUID PK
- feeding_event_id FK
- feed_product_id FK
- feed_lot_id FK nullable
- feed_batch_id FK nullable
- quantity_offered
- quantity_consumed nullable
- uom_id FK
```

Use existing Inventory, Supplier, UOM and Livestock Subject entities where already defined; do not duplicate those masters.

## 14. Feed program resolver

Conceptual service:

```text
resolveFeedingPrograms(
    species,
    sex,
    lifeStage,
    managementProfile,
    reproductiveState,
    lactationState,
    productionMetrics,
    weight,
    age
) -> EligibleFeedingPrograms
```

It should return:
- eligible program(s);
- best matching recommendation;
- matching rule/reason;
- priority;
- warnings;
- whether approval/review is required.

The decision must be explainable.

## 15. APIs

Suggested endpoints:

```http
GET  /api/v1/feed-items
POST /api/v1/feed-items

GET  /api/v1/feed-formulas
POST /api/v1/feed-formulas
POST /api/v1/feed-formulas/{id}/versions
GET  /api/v1/feed-formulas/{id}/versions/{version}

POST /api/v1/feed-batches
GET  /api/v1/feed-batches/{id}

GET  /api/v1/feeding-programs
POST /api/v1/feeding-programs
POST /api/v1/feeding-programs/{id}/versions

POST /api/v1/feeding-programs/resolve

POST /api/v1/livestock-subjects/{id}/feeding-assignments
GET  /api/v1/livestock-subjects/{id}/feeding-assignments

POST /api/v1/feeding-events
GET  /api/v1/livestock-subjects/{id}/feeding-history
```

## 16. Validation rules

- Formula version used by a completed batch cannot be rewritten.
- Actual batch component quantities must drive actual inventory consumption.
- Feed lots/batches used in feeding must be active and available unless an authorized override exists.
- Expired, recalled, quarantined or blocked feed must not be issued without explicitly authorized exception rules.
- Feeding-program applicability must be evaluated using configured rules.
- Group assignment and individual overrides must remain distinguishable.
- Individual override must not erase the inherited group program.
- Historical feeding events remain immutable except through controlled correction/reversal.
- Changes in animal state trigger re-evaluation, not automatic destructive reassignment.
- Units must use the enterprise UOM architecture and supported conversions.
- Formula, program and nutrient-profile versions must preserve history.
- Purchased feed and farm-produced feed must converge on a common downstream feed-product/lot interface.
- Feed consumption must integrate with inventory transactions rather than maintain a separate shadow stock.
- Missing consumption data must not be interpreted as zero consumption.
- Recommended ration must not be represented as actual feeding.

## 17. UI/UX

### Feed workspace
Tabs:
- Feed Inventory
- Ingredients
- Finished Feeds
- Formulas
- Mixing Batches
- Feeding Programs
- Daily Feeding
- Nutrition
- Costs
- Traceability

### Animal/group profile

Display:
- current feeding program;
- inherited vs individual assignment;
- daily target;
- recent actual feeding;
- supplements/overrides;
- feed cost;
- next program review;
- warnings.

### Mixing screen

Provide:
- selected formula/version;
- target batch size;
- scaled ingredient targets;
- actual weighed quantities;
- lot selection;
- variance;
- inventory availability;
- estimated vs actual cost;
- complete batch action.

Mobile entry should support barn/feed-room use and offline capture where required.

## 18. Events

Suggested enterprise events:

```text
FeedFormulaVersionActivated
FeedBatchStarted
FeedBatchCompleted
FeedBatchQuarantined
FeedLotReceived
FeedLotExpired
FeedLotRecalled
FeedingProgramActivated
FeedingProgramAssigned
FeedingProgramReviewRequired
FeedingProgramChanged
FeedingEventRecorded
FeedInventoryConsumed
FeedAnalysisReceived
```

Events must use the enterprise event envelope already defined by Origami FarmOS.

## 19. Integration with animal architecture

The Feed module consumes the Generic Animal Capability Model rather than duplicating animal rules.

Animal lifecycle/reproduction/production events can cause feeding re-evaluation.

Examples:
- `CalvingRecorded` → recommend fresh-cow feeding review.
- `DryOffRecorded` → recommend dry-cow program.
- `PregnancyConfirmed` → evaluate pregnancy feeding rules.
- `FoalingRecorded` → evaluate lactating-mare program.
- production-band change → evaluate dairy feeding program.
- group movement → evaluate inherited feeding assignment.

Feed must not rewrite the animal's authoritative lifecycle, reproduction or production state.

## 20. Integration with other Origami domains

- **Inventory:** ingredient/feed lots, stock movement and consumption.
- **Procurement:** purchased ingredients and finished feed.
- **Finance/Costing:** ingredient, batch, program, animal/group and production-unit feed cost.
- **Laboratory/LIMS:** nutrient/feed-quality analysis.
- **Veterinary:** medically required feed restrictions/supplements where appropriate.
- **Traceability:** ingredient → batch → feeding → exposed livestock.
- **Workflow:** formula approval, feeding review, exception handling.
- **Data Governance:** canonical UOM, ingredient/product/nutrient definitions.
- **Analytics:** feed efficiency, cost per litre/kg/output, variance and wastage.
- **AI:** recommendation/anomaly support only; AI must not silently alter authoritative feeding instructions.

## 21. Developer implementation sequence

1. Feed item/product master.
2. Feed lot and Inventory integration.
3. Formula + immutable formula version.
4. Formula components and scaling.
5. Feed batch + actual component consumption.
6. Feeding program + version.
7. Applicability rules/resolver.
8. Livestock Subject assignment.
9. Feeding event capture.
10. Group inheritance + individual overrides.
11. Animal lifecycle event triggers.
12. Nutrient profiles/lab integration.
13. Cost/performance analytics.
14. Recommendation support.

## 22. Acceptance criteria

The architecture is accepted when:

- a purchased dairy concentrate can be fed without creating a formula;
- an on-farm mix can be created from inventory ingredients and becomes a traceable feed batch;
- formula revisions preserve historical batches;
- lactating and dry cows can receive different programs without separate cattle feeding modules;
- calves and heifers can receive stage-specific programs;
- pregnant/lactating mares and growing horses can receive different programs without a separate horse feed architecture;
- layer and broiler poultry programs can use the same feeding engine;
- group feeding can be recorded efficiently;
- an individual can inherit group feeding while retaining explicit exceptions;
- a feeding event can be traced back to feed/ingredient lots;
- inventory and actual costs update from real batch/feeding transactions;
- animal state changes can trigger explainable feeding-program review.

## 23. Non-negotiable architecture rule

**Feed Product describes what can be fed. Feed Formula describes how a farm-produced feed is intended to be made. Feed Batch describes what was actually made. Feeding Program describes what an animal/group should receive. Feeding Event describes what was actually delivered/fed.**

Never collapse these concepts into one table.

Likewise, never build:

```text
Cow Feed Module
Horse Feed Module
Sheep Feed Module
Chicken Feed Module
```

Build one generic feeding architecture whose applicability changes according to the livestock subject and its current state.


## 24. Feed Usage Policy, Species Restrictions & Authorized Use

Every feed item, finished product and inventory lot may carry an enforceable usage policy. This is not informational metadata: it must be validated when a formula is authored, a batch is mixed, inventory is issued, and a feeding event is recorded.

A policy may define:
- allowed/prohibited species;
- allowed management/production profiles;
- allowed life stages;
- allowed physiological states;
- minimum/maximum age or weight where relevant;
- maximum inclusion rate;
- whether an approved formula is mandatory;
- whether cross-species transfer is permitted;
- cost centre/funding/program restrictions;
- veterinary or safety restrictions.

Example:

```text
CATTLE-DAIRY-PREMIX
Allowed species: CATTLE
Allowed profiles: DAIRY
Horse: BLOCKED
Sheep: BLOCKED
Goat: BLOCKED
Maximum inclusion: configured %
Approved formula required: YES
Cross-species transfer: NO
```

Attempting to add this premix to a horse or sheep formula/batch must fail before inventory is consumed.

Restrictions can exist at product level and be tightened at lot/allocation level. A lot-specific restriction may never broaden a stricter product safety restriction.

## 25. Feed Allocation & Reservation

Physical ownership of stock is different from authorization and availability.

Origami must support reserving feed stock for:
- species;
- livestock group;
- feeding program;
- farm/site/location;
- cost centre;
- project/funding source;
- production purpose.

Example:

```text
500 kg Cattle Premix
├── 400 kg reserved: Lactating Dairy Cows
└── 100 kg available: General Cattle Use
Cross-species transfer: prohibited
```

The inventory engine must expose at least:

```text
On Hand
- Quarantined
- Blocked
- Reserved
= Available to Promise / Available for Use
```

A user must not be able to consume reserved stock for another purpose unless a permitted reallocation workflow is completed.

## 26. Purchase-to-Consumption Quantity Control

Feed quantity must be traceable end-to-end:

```text
Purchase Order
    ↓
Goods Receipt
    ↓
Feed/Ingredient Lot
    ↓
Storage / Reservation
    ↓
Issue to Mixing or Direct Feeding
    ↓
Actual Batch Consumption
    ↓
Feed Offered
    ↓
Consumption Estimate/Measurement
    ↓
Waste / Return / Adjustment
    ↓
Remaining Stock
```

Origami must distinguish:
- ordered quantity;
- received quantity;
- accepted quantity;
- rejected/quarantined quantity;
- on-hand quantity;
- reserved quantity;
- available quantity;
- issued quantity;
- batch-consumed quantity;
- directly fed quantity;
- offered quantity;
- consumed quantity where measured/estimated;
- returned quantity;
- wasted quantity;
- adjusted quantity.

Inventory balances must be derived from auditable inventory transactions rather than editable summary fields.

## 27. Feed Reconciliation & Variance Control

The system must reconcile procurement, inventory and usage.

Example:

```text
Premix received                     500 kg
Recorded in approved cattle batches 420 kg
Documented waste                     10 kg
Current physical/system stock        45 kg
Expected accounted quantity         475 kg
Unexplained variance                 25 kg
```

Configurable variance thresholds should trigger review.

Reconciliation must support:
- book stock vs physical count;
- issued vs actually used in batch;
- formula target vs actual ingredient usage;
- batch produced vs batch issued/fed;
- feed offered vs leftovers/refusals where tracked;
- species/program allocation vs actual use.

An unexplained difference is a variance, not automatically waste.

## 28. Reorder, Days-of-Cover & Feed Inventory Forecasting

Origami must support both simple and demand-aware replenishment.

### 28.1 Static replenishment

Each item/location may define:
- minimum stock;
- reorder point;
- safety stock;
- preferred reorder quantity;
- maximum stock;
- supplier lead time.

When available stock crosses a configured threshold, Origami raises a replenishment alert.

### 28.2 Days of cover

```text
Days of Cover = Available Usable Stock / Forecast Daily Requirement
```

The calculation must use compatible units and should consider only stock that can legally/operationally be used for the relevant demand.

Example:

```text
Cattle premix available: 50 kg
Forecast cattle demand: 12 kg/day
Days of cover: 4.2
Supplier lead time: 7 days
=> STOCKOUT RISK
```

### 28.3 Demand-aware forecast

Forecast demand should be derived where possible from:

```text
Active Feeding Programs
× Current/Projected Animal or Group Counts
× Formula Ingredient Requirements
× Planning Horizon
+ Safety Stock
- Eligible Available Stock
- Confirmed Incoming Supply
= Projected Procurement Requirement
```

Forecasting must respect usage policies. Horse-eligible premix cannot satisfy cattle demand unless the same stock is explicitly eligible for cattle, and cattle-only premix cannot satisfy horse demand.

## 29. Restocking Workflow & Farm Manager Notifications

Suggested workflow:

```text
Forecast / Inventory Evaluation
          ↓
Threshold or Days-of-Cover Breach
          ↓
FeedReorderRequired
          ↓
Notify Farm Manager / Authorized Role
          ↓
Suggested Quantity + Reason + Demand Forecast
          ↓
Review
          ↓
Purchase Requisition
          ↓
Procurement Workflow
```

Notifications should include:
- feed item/product;
- site/storage location;
- current on-hand and available quantity;
- reserved quantity;
- projected daily demand;
- days of cover;
- supplier lead time if known;
- expected stockout date;
- suggested reorder quantity;
- livestock/programs affected.

Duplicate alerts should be suppressed/aggregated while an active replenishment action already covers the shortage.

## 30. Suggested Additional Database Objects

```text
feed_usage_policy
- id UUID PK
- feed_item_id nullable
- feed_product_id nullable
- policy_name
- requires_approved_formula
- cross_species_transfer_allowed
- status
- effective_from
- effective_to nullable

feed_usage_policy_rule
- id UUID PK
- policy_id FK
- rule_type
- species_id nullable
- management_profile_id nullable
- life_stage_id nullable
- reproductive_state nullable
- max_inclusion nullable
- uom_id nullable
- effect ENUM(ALLOW, BLOCK, LIMIT)

feed_allocation
- id UUID PK
- inventory_lot_id FK
- species_id nullable
- livestock_subject_id nullable
- feeding_program_id nullable
- location_id nullable
- cost_centre_id nullable
- allocated_quantity
- consumed_quantity
- uom_id
- transferable boolean
- status

feed_reorder_policy
- id UUID PK
- feed_item_id nullable
- feed_product_id nullable
- location_id
- minimum_stock nullable
- reorder_point nullable
- safety_stock nullable
- preferred_reorder_quantity nullable
- maximum_stock nullable
- lead_time_days nullable
- uom_id
- active

feed_demand_forecast
- id UUID PK
- item_or_product_type
- item_or_product_id
- location_id
- forecast_from
- forecast_to
- forecast_quantity
- uom_id
- generated_at
- basis_json

feed_reconciliation
- id UUID PK
- inventory_lot_id FK
- period_from
- period_to
- opening_quantity
- received_quantity
- issued_quantity
- waste_quantity
- adjustment_quantity
- expected_closing_quantity
- counted_closing_quantity nullable
- variance_quantity nullable
- status
```

Where generic Inventory/Procurement already owns equivalent entities, extend/reference those models rather than creating duplicate ledgers.

## 31. Additional APIs

```http
GET  /api/v1/feed-products/{id}/usage-policy
POST /api/v1/feed-products/{id}/usage-policy/validate

POST /api/v1/feed-allocations
GET  /api/v1/feed-allocations

GET  /api/v1/feed-inventory/availability
GET  /api/v1/feed-inventory/days-of-cover
GET  /api/v1/feed-inventory/forecast
GET  /api/v1/feed-inventory/reorder-recommendations

POST /api/v1/feed-reconciliations
GET  /api/v1/feed-reconciliations/{id}
```

A validation response should explain why use is allowed or blocked.

## 32. Additional Events

```text
FeedUsageBlocked
FeedAllocationCreated
FeedAllocationReleased
FeedAllocationTransferRequested
FeedAllocationTransferred
FeedStockBelowReorderPoint
FeedStockoutRiskDetected
FeedReorderRequired
FeedReorderAcknowledged
FeedReconciliationCompleted
FeedInventoryVarianceDetected
```

## 33. Additional Validation Rules

- A species-restricted feed cannot be included in a formula for a prohibited species.
- The same restriction must be revalidated when the physical batch is created.
- Direct feeding must validate feed eligibility against the livestock subject.
- Allocation/reservation must reduce usable availability for competing purposes.
- A restricted allocation cannot be transferred without authorized workflow.
- Reorder calculations use usable available stock, not gross on-hand stock.
- Forecast calculations must not count ineligible stock against demand.
- Inventory consumption must identify lot/batch where lot traceability is required.
- Physical count corrections require auditable adjustment transactions.
- Unexplained variance cannot be silently posted as feed consumption or waste.
- Purchase quantity, receipt quantity and accepted quantity must remain separately auditable.
- Replenishment recommendations do not automatically create/approve a purchase order unless an explicitly authorized procurement automation exists.

## 34. Additional Acceptance Criteria

The feed architecture is additionally accepted when:
- 500 kg of cattle-only premix can be purchased, received and tracked by lot;
- that premix can be reserved wholly or partly for dairy cattle;
- a horse/sheep formula cannot consume cattle-only premix;
- a prohibited direct feeding transaction is blocked;
- every kilogram can be reconciled among stock, approved mixing/feeding, waste, returns and adjustments;
- unexplained variance is visible and actionable;
- available stock excludes quarantine, blocked and reserved quantities;
- Origami can calculate days of cover from eligible stock and forecast demand;
- a farm manager is notified before projected stockout according to reorder/lead-time rules;
- the alert identifies the livestock/program at risk;
- a replenishment recommendation can flow into the Procurement workflow without bypassing approval controls.

## 35. Extended Non-Negotiable Control Rule

**Physical possession of a feed item does not imply permission to use it.**

Every feed transaction must answer four questions:

1. **Do we have it?** — inventory availability.
2. **Is this stock allocated/reserved?** — allocation control.
3. **Is it permitted for this species/profile/program?** — usage policy.
4. **Will enough remain to meet upcoming demand?** — forecasting/replenishment.

The system must prevent unauthorized cross-species use at transaction time and must provide auditable reconciliation afterward.
