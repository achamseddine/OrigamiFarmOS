# Origami FarmOS — Farm-Wide Interactive Prototype V3

The standalone, self-contained browser prototype is **[origami-farmos-v3.html](origami-farmos-v3.html)**. Download it and open in a modern desktop or mobile browser. No build step or external service is needed.

## Scope / Modules
- **Overview:** entered milk, animal registry, farm-task and financial summaries, rule-based attention signals; previously reported farm reference figures explicitly separate from demo data.
- **My Day:** routine milking/feeding checklist and assigned work orders, with separate actual event recording.
- **Animal Registry & Digital Twin:** role-dependent animal creation/editing, photo upload, species, animal status, milking, feed offered/refused, weight/BCS, reproduction, clinical findings, medicine/withdrawal context, chronological timeline, JSON export.
- **Feed & Nutrition:** ingredient receipt lots, supplier genealogy, formulas as references, numbered mix manufacturing with actual source lot quantities, batch output/waste/variance, estimated ingredient costs, finished-mix balance, animal feeding and exposure linkage, readiness checklist for future individual ration optimizer.
- **Inventory:** suppliers, traceable receipts/lot ID, costs, quality/expiry status, mix withdrawals, direct feeding and other stock issues. Calculated browser-local balances and overdraw checks.
- **Production:** individual cow milk history and 7-day trend, eggs, other products and milk dispatch; no false financial linkage.
- **Health & Veterinary:** clinical cases, follow-ups, observations, medication records, conservative withdrawal warning display.
- **Crops & Greenhouses:** field/greenhouse registration; crop operations, irrigation and harvest journals.
- **Finance:** separately entered actual income/expense transactions, 30-day net journal difference, expense analysis; excludes unpaid bills/inventory costs unless recorded.
- **Operations:** assigned work orders, equipment registry, service history.
- **Origami Intelligence:** transparent **rule-based demo** signals for milk trend, withdrawal/follow-up and stock. Clearly distinguishes missing nutritional data and prohibited clinical inference.

## Open and test

1. Open **origami-farmos-v3.html** in Chrome, Edge, Firefox or Safari.
2. Choose **Owner / Admin** from the demonstration role dropdown.
3. Under **Inventory → Suppliers**, create a supplier, then receive two feed ingredient lots measured in kg with unit costs.
4. Under **Feed & Nutrition → Mix production**, produce a `MIX-000001` using ingredient lots and their actual quantities; inspect consumed inputs, finished quantity, cost, variance and remaining stock.
5. Under **Feed intake**, feed a registered animal from that numbered mix. The finished balance must decrease; larger issues must be rejected. Open the mix details to see the individual animal exposure.
6. Record milk, body weight, reproductive and health events in the **Animal Digital Twin**. Use **Production**, **Health & Vet**, **Crops**, **Finance** and **Operations** to create their records.
7. Use the **Overview** and **Origami Intelligence** screens for summaries, then export all local data from the Overview or About menu.

## Data model and continuity

Records are browser-local, namespaced under the V2 local-storage key so existing V2 animal profiles are retained. V3 adds arrays for suppliers, inventory lots/issues, formulas, extra production, fields and crop events, finance, work orders, equipment/service, and health cases.

- Physical numbered mixes use a **browser-local sequential** `MIX-000001` style ID. Production-grade farm-wide uniqueness requires backend allocation and offline synchronization.
- Finished-stock quantity is derived from output less linked non-voided individual feeding records. Source lots are derived from receipts less ingredient quantities used in mixes, direct animal offerings and issue/write-off events.
- The browser demo does **not** enforce multi-user atomic transactions, authenticated permissions or a compliant inventory ledger.
- Animal-specific nutritional requirements, validated least-cost ration optimization and automatic AI/feed-performance causality are **design requirements**, not working services.

## Explicit safety boundaries

**Do not use this prototype** for production inventory reconciliation, medication prescribing, withdrawal clearance, unreviewed nutrition advice, livestock food-safety release or official financial reporting. 'Veterinarian' and 'Admin' selectors are visual demo roles, not identity verification. Data may be lost when browser storage is cleared. Export local records regularly.

The canonical forward-looking references are:
- [Dynamic nutrition & ration optimization](../database/DYNAMIC-NUTRITION-AND-RATION-OPTIMIZATION.md)
- [Feed performance intelligence](../database/FEED-PERFORMANCE-INTELLIGENCE.md)
- [Feed schema / numbered mixes](../database/FEED-SCHEMA.md)

## Next engineering milestones
1. Adopt existing FastAPI/PostgreSQL/Alembic and Flutter application components as appropriate; avoid replacing the working architecture with prototype localStorage.
2. Build backend identity/authorization, canonical UUIDs and robust server/offline mix-number allocation, audited transactions and ingredient genealogy.
3. Add atomic stock postings, farm/member scoping, idempotent offline synchronization and conflict resolution.
4. Connect animal, production, veterinary and crop forms to validated domain models and API contracts.
5. Add nutrition calculations/solver only after professional model validation, ingredient-quality evidence and tests.
6. Establish bilingual Arabic/English strings (current Arabic toggle previews RTL but **is not a full translation**), accessibility and automated integration tests.
