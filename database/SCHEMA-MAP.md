# Canonical Database Schema Map

**Status:** Development baseline

## Domain ownership
```text
platform
├─ organization
├─ farm
├─ site
├─ location
├─ user_account / role / permission
├─ audit_log
├─ idempotency_record
└─ outbox_event

reference
├─ uom_dimension
├─ uom
├─ species
├─ breed
├─ life_stage
├─ management_profile
├─ capability
└─ species_capability_rule

livestock
├─ animal
├─ animal_identifier
├─ animal_group
├─ animal_group_membership
└─ animal_relationship

inventory
├─ inventory_item
├─ inventory_lot
├─ inventory_transaction
├─ inventory_reservation
└─ stock_count

feed
├─ feed_item / feed_product
├─ usage policies
├─ formulas / versions / components
├─ batches / components
├─ feeding programs / rules
├─ assignments
└─ feeding events
```

Later schemas add reproduction, health, production, procurement, crops, assets, laboratory, finance and compliance. Medicine/pharmacy management extends Inventory + Health with `medicine_product`, pharmaceutical lot metadata, farm essential-stock policies, stock alerts and replenishment without creating a second stock ledger.

## Physical design decision: LivestockSubject
`LivestockSubject` remains a conceptual interface. Pass 1 does **not** create a generic polymorphic livestock_subject table. Domain association tables use explicit `animal_id` / `animal_group_id` with a CHECK requiring exactly one where both are supported. This avoids weak polymorphic foreign keys while retaining the conceptual model.

Revisit only if implementation evidence demonstrates a strong need for a shared physical supertype.

## Cross-domain rules
- Every farm-owned operational row carries `farm_id` directly or has an unambiguous FK path to it.
- Cross-domain FKs reference canonical identity; modules do not duplicate masters.
- No module directly edits another module's authoritative ledger/history.
- Read projections may denormalize but are never authoritative.

### Feed Performance Intelligence / Analytics
- feed_performance_monitor
- feed_exposure_window (rebuildable analytical projection)
- feed_performance_assessment
- feed_batch_performance_score (rebuildable projection)
- supplier_feed_performance (versioned analytical projection)
- feed_performance_alert

These depend on Feed + Inventory + Procurement/Supplier + Livestock + Production + Health + Costing and therefore belong after those authoritative domains in migration/implementation order.

