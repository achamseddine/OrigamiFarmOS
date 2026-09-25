# Pass 6 Integrity & Cross-Domain Behavior

## Crop → Inventory
Planning planting/fertilization/harvest never changes stock. Posting actual field inputs creates inventory CONSUMPTION. Posting harvest creates PRODUCTION_OUTPUT exactly once.

## Harvest → Feed
Farm-grown corn/silage does not bypass Feed. Harvest/transformation creates traceable inventory lots; feed semantics and usage policy govern downstream feeding.

## Transformation mass balance
For silage and other transformations retain:
- input lot quantities;
- output quantity;
- measured/estimated process loss;
- moisture/dry-matter evidence where available.
Do not hide shrinkage by altering harvest quantities.

## Crops/Assets
Field operations may link asset_usage. Tractor/pump/machinery hours feed maintenance schedules and costing.

## Assets/Inventory
Spare parts, fuel and lubricants are inventory items. Posting maintenance consumption creates ledger transactions. Asset master never carries a consumable stock balance.

## Assets/Costing
Labor, parts, fuel and external service costs can allocate to asset/work order/crop cycle/cost center. Depreciation/accounting treatment belongs to later finance architecture.

## Silage example
```text
8-dunum corn field
→ crop cycle
→ seed/fertilizer/water/tractor operations
→ harvest event
→ harvest lot
→ ensiling batch
→ silage inventory lot
→ dairy feeding program
→ feeding event
→ cows/group
→ milk production
→ operational cost analysis
```

This permits cost/yield analysis from field through milk without duplicating authoritative quantities.

## Offline
Field observations, meter readings and routine operations may be captured offline. Inventory-consuming postings are idempotent and revalidated on sync to prevent duplicate consumption.

## Acceptance
1. Farm can calculate yield per field/cycle.
2. Farm-produced feed is traceable field → harvest → silage → feeding → livestock.
3. Inventory remains the single physical quantity ledger.
4. Silage shrink/loss remains visible.
5. Asset maintenance uses real meter/calendar history.
6. Parts consumption and maintenance cost are traceable.
7. Field and machinery costs can later contribute to actual farm-produced feed cost.
