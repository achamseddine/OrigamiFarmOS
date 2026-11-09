# Database Baseline v1 — Migration Order

1. PostgreSQL prerequisites.
2. organization, farm, site, location.
3. user_account, role, permission, role_permission, farm_user_role.
4. uom_dimension, uom.
5. species, breed, life_stage, management_profile, capability, species_capability_rule.
6. audit_log, idempotency_record, outbox_event.
7. livestock.
8. inventory.
9. feed.
10. reproduction.
11. health/veterinary, medicine/pharmacy masters/policies, and veterinarian-approved emergency protocol/clinical decision-support structures.
12. production.
13. supplier/procurement.
14. operational costing.
15. crops/harvest/silage.
16. assets/maintenance.
17. customer/sales.
18. operational finance/AR/cash.
19. analytics/projections, including feed performance intelligence projections/assessments/alerts after feed + procurement + production + health dependencies are available.

Each slice gets reviewed migration SQL and automated migration tests. Never create duplicate masters to break dependency order. Conceptual LivestockSubject remains explicit animal_id/animal_group_id FKs with exactly-one checks where applicable.

**Nutrition/optimization dependency:** after animal/health/reproduction/production, feed nutrient/lot, procurement/pricing and inventory schemas, introduce `nutrition_model`, `animal_nutrient_requirement`, `ration_optimization_run`, and `ration_proposal` as defined in `DYNAMIC-NUTRITION-AND-RATION-OPTIMIZATION.md`. Approved program and actual feeding events remain the authoritative operational records.

