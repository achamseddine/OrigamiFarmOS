# Feed Performance Intelligence

**Status:** Canonical implementation baseline  
**Depends on:** Feed, Inventory, Procurement/Suppliers, Livestock, Production, Health, Costing  
**Purpose:** Continuously evaluate how purchased ingredient lots, locally manufactured feed batches and feeding programs are associated with animal/group production, health and economic performance.

## 1. Core principle
Origami must connect what the farm **bought**, what it **actually mixed**, what animals **actually received**, and how they **performed afterward**.

The intelligence layer does not create a second feed, inventory, production or health truth. It consumes canonical facts and produces versioned analytical assessments, alerts and recommendations.

A performance association is not automatically causation. Feed is a major explanatory variable, but the model must evaluate known confounders and expose uncertainty.

## 2. Required lineage
```text
Supplier
 → Purchase Order / Receipt
 → Ingredient Inventory Lot
 → price + quantity + declared/lab quality
 → Feed Batch Component (actual quantity)
 → Feed Batch / Finished Feed Lot
 → Feeding Event
 → Animal / AnimalGroup
 → Production Timeline
 → Health / Reproduction / Lifecycle / Environment Context
 → Feed Performance Assessment
```

Reverse analysis must support:
```text
Milk deterioration
 → exposed group/animals
 → feed lots/batches introduced before change
 → actual formula deviations
 → ingredient lots
 → supplier
```

Different suppliers and different lots of the same canonical ingredient remain analytically distinguishable.

## 3. feed_performance_monitor
Defines what Origami continuously evaluates.
```sql
feed_performance_monitor (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 production_metric_code varchar(60) not null,
 baseline_method_code varchar(60) not null,
 baseline_window_days integer not null,
 evaluation_frequency_code varchar(30) not null,
 minimum_exposure_days numeric(10,2),
 minimum_observations integer,
 alert_threshold_percent numeric(12,6),
 active boolean not null default true,
 configuration jsonb,
 created_at timestamptz not null,
 updated_at timestamptz not null,
 check (num_nonnulls(animal_id,animal_group_id)=1)
)
```
For dairy, the primary metric can be milk volume; milk components may be additional metrics when available.

## 4. feed_exposure_window
A derived, reproducible analytical link between livestock and the feed actually received.
```sql
feed_exposure_window (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 feed_product_id uuid not null references feed_product(id),
 inventory_lot_id uuid references inventory_lot(id),
 feed_batch_id uuid references feed_batch(id),
 exposure_start timestamptz not null,
 exposure_end timestamptz,
 offered_quantity_base numeric(20,6),
 consumed_estimate_base numeric(20,6),
 feeding_event_count integer not null,
 lineage_snapshot jsonb not null,
 generated_at timestamptz not null,
 check (num_nonnulls(animal_id,animal_group_id)=1)
)
```
This is an analytical projection from feeding events, not a replacement for them.

## 5. feed_performance_assessment
```sql
feed_performance_assessment (
 id uuid primary key,
 monitor_id uuid not null references feed_performance_monitor(id),
 evaluated_at timestamptz not null,
 period_start timestamptz not null,
 period_end timestamptz not null,
 baseline_value numeric(20,8),
 observed_value numeric(20,8),
 variance_value numeric(20,8),
 variance_percent numeric(12,6),
 feed_related_likelihood varchar(30),
 confidence_score numeric(6,5),
 model_reference varchar(150),
 model_version varchar(100),
 evidence_snapshot jsonb not null,
 confounder_snapshot jsonb,
 explanation text not null,
 status varchar(30) not null,
 check (period_end > period_start)
)
```
Suggested likelihood labels: LOW, MODERATE, HIGH, INSUFFICIENT_EVIDENCE. These labels express association assessment, not a veterinary or nutritional diagnosis.

## 6. Context and confounders
Where data exist, evaluation should consider:
- days in milk/lactation stage;
- parity;
- pregnancy/reproductive state;
- animal/group membership changes;
- recent calving, drying-off or movement;
- active health cases, fever, mastitis suspicion and treatment;
- withdrawal/restricted milk disposition without falsifying yield;
- live weight/body-condition changes;
- feed intake estimate, refusal and waste;
- feeding frequency/timing;
- formula version;
- actual versus target ingredient quantities;
- ingredient lot changes;
- nutrient/laboratory analysis;
- environmental/heat-stress data when available;
- milking-system or measurement anomalies;
- major management changes.

Missing context must reduce confidence rather than being silently treated as normal.

## 7. feed_batch_performance_score
A rebuildable analytical projection for manager dashboards.
```sql
feed_batch_performance_score (
 feed_batch_id uuid primary key references feed_batch(id),
 evaluated_at timestamptz not null,
 exposed_head_count integer,
 exposure_days numeric(12,4),
 formula_compliance_score numeric(8,4),
 intake_response_score numeric(8,4),
 production_response_score numeric(8,4),
 health_signal_score numeric(8,4),
 consistency_score numeric(8,4),
 economic_score numeric(8,4),
 overall_score numeric(8,4),
 confidence_score numeric(6,5),
 evidence_summary jsonb not null
)
```
The score is explanatory/analytical and never changes authoritative feed quality status by itself.

## 8. Formula compliance
For each completed local feed batch:
```text
component deviation % = (actual quantity - target quantity) / target quantity × 100
```
Origami evaluates material deviations by component and overall batch.

This allows the system to distinguish:
- possible ingredient/supplier quality issue;
- incorrect local mixing;
- intentional authorized formula substitution;
- intake/refusal problem;
- production decline with no obvious feed change.

A batch with material manufacturing deviation should not be used as clean evidence against an ingredient supplier without explicitly accounting for that deviation.

## 9. supplier_feed_performance
Supplier evaluation is derived from the supplier's actual lots and downstream exposures.
```sql
supplier_feed_performance (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 supplier_id uuid not null references supplier(id),
 inventory_item_id uuid not null references inventory_item(id),
 evaluation_start date not null,
 evaluation_end date not null,
 lot_count integer not null,
 feed_batch_count integer,
 purchase_quantity_base numeric(20,6),
 average_unit_cost_base numeric(20,6),
 quality_consistency_score numeric(8,4),
 downstream_performance_score numeric(8,4),
 incident_count integer not null default 0,
 confidence_score numeric(6,5),
 methodology_code varchar(60) not null,
 methodology_version varchar(40) not null,
 evidence_snapshot jsonb not null,
 generated_at timestamptz not null
)
```
Supplier score must never collapse different ingredient types into one misleading quality number.

## 10. Effective feed value
Purchase price alone is insufficient.

Analytics may compare:
- purchase price/kg or tonne;
- delivered cost;
- dry-matter-adjusted cost where applicable;
- nutrient-adjusted cost where data exist;
- feed cost/head/day;
- feed cost/litre of milk;
- milk revenue less feed cost;
- observed production response associated with supplier lot/batch;
- waste/refusal;
- quality incidents.

Origami may therefore explain that a cheaper ingredient lot had lower effective economic value if downstream evidence supports that conclusion, while retaining confidence and confounders.

## 11. feed_performance_alert
```sql
feed_performance_alert (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 assessment_id uuid references feed_performance_assessment(id),
 alert_type varchar(60) not null,
 severity varchar(20) not null,
 detected_at timestamptz not null,
 title varchar(200) not null,
 explanation text not null,
 evidence_snapshot jsonb not null,
 confidence_score numeric(6,5),
 status varchar(30) not null,
 deduplication_key varchar(255) not null,
 acknowledged_by uuid references user_account(id),
 acknowledged_at timestamptz,
 resolved_at timestamptz
)
```

Alert types may include:
- PRODUCTION_DECLINE_AFTER_FEED_CHANGE
- FEED_BATCH_UNDERPERFORMANCE
- FORMULA_COMPLIANCE_DEVIATION
- INGREDIENT_LOT_PERFORMANCE_ANOMALY
- SUPPLIER_LOT_PERFORMANCE_ANOMALY
- INTAKE_OR_REFUSAL_ANOMALY
- FEED_COST_PER_OUTPUT_INCREASE
- FEED_PERFORMANCE_IMPROVEMENT

Alerts are deduplicated and should notify only when configured thresholds, persistence and confidence requirements are met.

## 12. Continuous monitoring
Monitoring is event-driven plus scheduled analytical evaluation.

Re-evaluate after:
- FeedBatchCompleted;
- FeedAnalysisReceived;
- FeedingEventRecorded;
- ingredient/output lot change;
- FeedingProgramAssigned/changed;
- MilkRecorded/ProductionRecorded;
- HealthCaseOpened/Closed;
- relevant lifecycle/group change;
- supplier receipt or cost update;
- daily scheduled feed-performance cycle.

The daily cycle establishes current baselines, evaluates active exposures, checks persistence of anomalies, updates confidence, resolves recovered conditions and creates manager-facing explanations.

## 13. Baselines
Do not compare every cow/group to one static farm average.

Baseline methods may include:
- rolling subject baseline;
- comparable previous period;
- lactation-stage-adjusted baseline;
- matched peer group;
- approved expected production curve;
- model-adjusted expected value.

Every assessment records baseline method/version and the exact evidence window used.

## 14. AI behavior
AI may:
- detect production changes associated with feed changes;
- identify candidate batches/lots/suppliers;
- rank plausible feed-related explanations;
- detect actual-vs-formula mixing deviations;
- compare supplier-lot performance;
- estimate confidence;
- summarize confounders;
- forecast stock and economic implications;
- recommend inspection, sampling, lab analysis or ration review.

AI must not:
- claim feed caused a production/health outcome solely from temporal correlation;
- hide missing/conflicting evidence;
- silently change an approved formula/program;
- automatically reject a supplier or block stock solely from an analytical score unless a separately authorized quality rule applies;
- overwrite production, health, feed, procurement or inventory facts.

## 15. Manager experience
Example:
```text
FEED PERFORMANCE ALERT — High Production Group

Milk yield is 7.8% below the adjusted recent baseline for 3 consecutive days.

Relevant change:
Dairy Mix Batch #241 introduced 4 days ago.
Batch #241 contains Corn Lot C-882 from Supplier B, first exposure for this group.

Checks:
- recorded feed offered: stable
- formula compliance: within tolerance
- group membership: no material change
- active health cases: 2 animals
- lactation mix: stable
- environmental data: unavailable

Feed-related likelihood: MODERATE
Confidence: 0.74

Suggested actions:
1. inspect Batch #241 and Corn Lot C-882;
2. compare refusal/intake;
3. sample for lab analysis if deterioration persists;
4. review ration with the responsible nutrition/veterinary professional.
```

## 16. Events
FeedPerformanceEvaluated, FeedPerformanceAnomalyDetected, FeedPerformanceRecovered, FeedBatchPerformanceUpdated, FormulaComplianceDeviationDetected, IngredientLotPerformanceAnomalyDetected, SupplierFeedPerformanceUpdated, FeedCostEfficiencyChanged, FeedPerformanceReviewRequired.

## 17. Acceptance
1. Different suppliers/lots of the same grain remain traceable through local crushing/mixing to downstream animals/groups.
2. Actual batch quantities, not only formula targets, participate in performance analysis.
3. Vitamins, minerals, premixes and additives retain supplier/lot lineage like bulk grains.
4. Milk yield can be continuously monitored against feed exposure and an explicit baseline.
5. Known health/lactation/group/context changes are considered where available.
6. Missing context lowers confidence rather than being treated as zero/no-change.
7. AI distinguishes association from causation in explanations.
8. Manufacturing deviation can be separated from suspected ingredient-lot quality.
9. Supplier performance is evidence-based, ingredient-specific, versioned and confidence-scored.
10. Feed cost/litre and effective supplier value can combine commercial cost with downstream performance.
11. Alerts are persistent/deduplicated rather than generated for ordinary daily noise.
12. AI recommendations never silently change authoritative formulas, feeding programs, supplier status or inventory.
