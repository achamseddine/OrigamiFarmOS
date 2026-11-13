# Releases

## v0.7.1 — Corrections from on-farm testing

From testing the v0.7.0 build on the farm (`docs/QR-ANIMAL-QUICK-ENTRY.md`, *Corrections after on-farm testing*).

**Delivered:**
- **Add an animal with nothing to scan.** The ear tag (cattle) and microchip (horse) no longer block registration; the server gives every new animal the farm's next farm number (one sequence for all species, never reused) and the form shows its QR label to print right after saving. The Digital Twin lists an expected identifier as "Not recorded yet" until it is added. This resolves the conflict between `docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md` and `database/LIVESTOCK-SCHEMA.md` §19 in favour of "ear tag is not universally mandatory" (§4a).
- **Pregnancy and milk on the animal form**, new and existing animals: *Not pregnant / Inseminated — not confirmed / Pregnant* with the insemination date and method, the expected birth and the dry-off date; *Producing milk / Not milked — dried off*. Answers become records (breeding event, pregnancy check, lactation start, dry-off), never flags; saying she is milked opens the milk record. An answer the stage or profile does not allow adjusts them and says so (a goat with no profile → dairy). Senior females keep the adult reproduction and milk capabilities.
- **Farm setting: dry-off before birth** (days, default 60) in Settings; the twin and the reproduction overview show *dry off from* for every pregnant animal in milk and flag it when due.
- **Animal feed record fixed.** The production farm had no feed products, so the form had nothing to choose; the feeding form now opens with three optional rows — Concentrate, Corn silage, Wheat straw — each already pointing at the farm's feed (`GET /feed-products/standard-slots`), plus *Add another feed*. The farm gets the three standard feeds with an empty ledger (migration, production seed, or the form's *Set up* button). Feeding more than the stock entered is no longer a dead end: the form says so and records it only when the worker ticks *Stock not entered yet — record anyway*. The quick-entry screen uses the same rows and override.
- Fixed: the Add Animal form's dropdowns overflowed ("Female · Cow") on narrower tablets.
- Migration `a8d0c2e4f6b1` (farm setting, senior rules, standard feeds) — **run it on the server before using this build.**
- Tests: backend +13 (registration, farm numbers, pregnancy from an insemination, dry-off setting and permission, standard feeds, the stock override), four updated for the new identifier rule; Flutter 247 (+7). PostgreSQL migration parity, downgrade and re-upgrade verified, including the data step on a farm that already has a silage.

**Next:** the health requests from the same testing.

## v0.7.0 — Scan-first worker rounds (QR)

Merges PR #11's QR quick entry (withheld milk enforced server-side, medicine only through the pharmacy, no guessed routes, Arabic/Persian digits) and builds its follow-ups, from a workflow analysis of the 06:00 round (`docs/QR-ANIMAL-QUICK-ENTRY.md`).

**Delivered:**
- Camera QR scanning on the tablet, offline (ADR-003: `mobile_scanner`, `pdf`, `printing`, `barcode`); the camera permission is optional in the manifest.
- QR labels for animals and pens printed or shared as an A4 PDF from the tablet; Arabic names print correctly.
- Pen/group labels (`origami://group/{id}`) open the group's feeding round and members, never one animal.
- The worker screen shows what is already recorded today; a second milking in the same session needs a tick.
- Feed rows from the animal's own program with planned amounts as hints and *Fill planned amounts*; the worker confirms every figure.
- Rounds from My Day (morning/evening milking, individual feeding) with who is done and who is left; *Scan next automatically*.
- Entry points: *Scan an animal* on My Day and in the Record sheet opens the camera; *Print QR labels* on the Animals screen; *Quick entry* and *QR label* in the Digital Twin's Record sheet.
- Tests: Flutter 240 (+18 including PR #11's); backend unchanged and passing.

**Next:**
- Photo attachments with private storage; body-condition scoring; cross-device duplicate reconciliation; barn-light device testing of labels.

## v0.6.1 — Health and Mouneh in the V3 layout

**Delivered:**
- Health: the prototype's command centre (open cases and follow-up, withdrawal review with its caveat, the clinical record), header actions for opening a case, recording an observation and emergency triage, and real tabs in place of three "coming soon" placeholders. Health cases reach the tablet for the first time — list, detail with the veterinarian's diagnoses and plans, open / monitoring / close, offline through cache rules — and on each animal's Health tab. Fixed: the recommendations view crashed its layout on a wide tablet (`IntrinsicHeight` around a `LayoutBuilder`).
- Mouneh: every screen translated to Arabic (196 strings), the module header with *Start a batch* / *Record a sale* / *New product*, figures, underlined tabs, empty states and caveats; the add-material dialog no longer hides a refusal.
- Shared: a header band with an eyebrow over a two-line subtitle no longer overflows on the plain (no-artwork) header.
- Demo data: Bella's two earlier mastitis treatments now sit in closed health cases with the veterinarian's diagnosis and plan; the snapshot carries the cases and the farm's observations.
- Tests: Flutter 222 (+9); backend suite unchanged and passing.

## v0.6.0 — The V3 prototype's layout on the tablet

Brings the farm-wide V3 prototype's UX (`prototypes/origami-farmos-v3.html`) into the Flutter tablet on the real backend, as the prototype's own README asks, starting with animals, My Day and feed.

**Delivered:**
- Shared page anatomy: eyebrow headers on every top-level screen, section headings, dashed empty states, caution notices, record tiles, fact lists and underlined tabs (`core/widgets/ux_blocks.dart`).
- Animal Digital Twin rebuilt as header card + four figures + capability-gated tabs (Overview, Milk, Feed, Weight, Reproduction, Health & medicines, Timeline) with a grouped *Record* sheet; dated weights recorded from the tablet (offline too); a ration-readiness card that calculates nothing; a merged timeline; a missing or not-yet-loaded animal no longer crashes the screen.
- Animal registry with search by any identifier and status filters including animals that left the farm.
- My Day: today's milking, feeding and egg-collection routine, ticked off only from today's records.
- Feed & nutrition: *Make feed mix* / *Record feeding*, ledger-derived figures, the prototype's tab order, rounds recorded today per plan line. Fixed: five feed tabs hid their tap ripple behind a coloured box (a debug-mode assertion).
- Health: the AI caveat and an honest empty state.
- Demo snapshot now carries each animal's weights. 197 strings added in English and Arabic (observation types and event names among them, which were English-only).
- Tests: Flutter 213 (+17, including screens drawn over the bundled snapshot through a new test harness); analyzer unchanged at 0 errors.

**Next:**
- The prototype's Overview and Intelligence pages, Inventory / Crops / Operations / Finance restyles, and body-condition scoring (a capability with no record yet).

## v0.5.0 — The livestock record: history, groups and reproduction

Completes the generic animal model's remaining steps (docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md §13: reproduction, groups, incubation) from LIVESTOCK-SCHEMA, REPRODUCTION-SCHEMA and PRODUCTION-SCHEMA §8.

**Delivered:**
- Backend: migration `b5e7a9c1d3f8` (animal state history; group type policies, memberships, head-count ledger, relationships; breeding events, pregnancy episodes and checks, births and offspring, lactation episodes, incubation batches and hatches; species gestation / incubation days) with a backfill of existing flags, herd names and flock counts. 27 new endpoints. Pregnancy and lactation are a projection of their episodes; an exit closes memberships, lactation, pregnancy and feeding and blocks later milk and feeding; feed inheritance follows real memberships. Identifier search and lookup.
- Tablet: Reproduction & milking and Herd & family on the Digital Twin, the full reproductive record with registration of untagged newborns, Record exit, the reproduction day on the Animals screen, group sheets (members, ledger, incubator) from the Animals and Egg screens, a group picker in the animal form; Milk and Egg screens now load for animal-care staff. Offline and standalone through cache effects; 142 new AR/EN strings.
- Tests: backend 478 (SQLite; the parity and backfill tests also on PostgreSQL 16); Flutter 196.

**Next:**
- Unified production records (§13 step 9) and an admin UI for the species catalog (step 12).
- The cross-cutting move of quantities and money to `numeric`.

## v0.4.0 — Feed intelligence, farm pharmacy, emergency protocols and the specification gap closure

Adds the generic animal and feed architectures' later increments (numbered
mixes, feed performance intelligence), the medicine & pharmacy module, the
clinical decision support / emergency protocol engine, and then closes every
gap the merged database specifications (PR #10) still listed against them.

**Delivered:**
- Backend: `units_of_measure`, `farm_assets`, `notification_routes`, `scheduled_job_runs`, `health_cases`, `diagnoses`, `treatment_plans`, `animal_health_conditions`, `animal_weight_records`, `purchase_requisitions` (+ lines, approvals), `inventory_reservations` and the referencing columns on feed batches, feeding events, lots, administrations, treatments, observations and emergency tables (migration `a7c9e1f3b5d7`, downgradable). New routers: `/units-of-measure`, `/assets`, `/notification-routes`, `/scheduler`, `/health/cases`, `/animals/{id}/conditions`, `/animals/{id}/weights`, `/procurement/requisitions`; `/pharmacy/reservations`, `/pharmacy/transfers`; `/emergency/offline-runs`, `/emergency/reassessments/check`; `/feed-mix-settings`; `/feed-performance/ingredient-lots`, `/feed-performance/effective-feed-value`.
- Feed performance 2.0: lactation-curve, peer-group and production-curve baselines, the full alert catalogue with structured suggested actions, effective feed value, ingredient-lot and supplier signals, re-evaluation on every feeding, lot and context change, a daily scheduled cycle. Pharmacy: unit-referenced quantities, reservations that reduce eligible stock, paired-transaction transfers, requisitions that go through submit / approve / reject with the approving authority snapshotted and that count as incoming supply, prescription-product binding on administrations, per-person routed notifications, a daily expiry scan. Emergency: the engine opens and closes its own health cases, reads recorded allergies and open diagnoses, refuses a weight older than the protocol allows, routes its tasks by role, checks reassessments every 15 minutes, and revalidates protocols executed offline from the signed package, recording every discrepancy.
- Cross-cutting: `database/schema.sql` is rendered from the ORM (`python -m app.export_schema`), `api/openapi.yaml` exported from the application (`python -m app.export_openapi`), and both are checked by tests; `tests/test_migrations.py` proves migration ↔ ORM parity, the demo seed and a downgrade/upgrade round trip on SQLite and on PostgreSQL 16; a backend CI workflow runs the suite with a PostgreSQL service on every push. Found and fixed on the way: boolean literals in two migrations and foreign-key ordering in the seeders that only PostgreSQL rejects, a notification id column too narrow for routed copies, and SQLAlchemy 2.1's change of default PostgreSQL driver (now pinned by the application).
- Tablet: Give medicine and Assess animal from the animal profile; the care record on the Digital Twin (doses with their lots, withdrawal in force, standing conditions, latest weight, open case, live emergency); entity routes for every pharmacy, emergency, health-case, feed and procurement record, with the Health screen opening the right tab; **offline protocol execution** — triage on the device from the signed package with the server's own scoring, eligibility and dose arithmetic (`lib/emergency/offline_engine.dart`), the protocol walked step by step at the animal, and the run queued for the server's revalidation. 176 Flutter tests.

**Next:**
- Versioned statistical / AI feed-performance models behind the same assessment, evidence and confidence contract.
- Push / SMS channels on notification routes; a separate worker when the API runs as more than one process.
- Procurement beyond requisitions (purchase orders, receipts, invoices) and costing attribution.

## v0.3.0 — Farm Visits & Agri-Tourism Module

Adds the license-gated Farm Visits & Agri-Tourism module (tech spec v0.6)
on top of v0.2.0, structured the same way as the Mouneh module.

**Delivered:**
- Backend: `visit_opening_calendar`, `visit_session`, `visit_package`, `visit_activity`, `visitor_profile`, `visit_booking`, `visit_booking_activity`, `visit_staff_roster`, `visit_cost`, `visit_retail_sale`, `visitor_feedback`, `visit_incident`, `visit_events` tables (reusing the existing `module_licenses` table for the license itself) + a pure, unit-tested analytics/validation engine (`app/visits/analytics.py`) + all 15 spec API endpoints plus a few extensions (`/modules/visits/status`, `/visit-calendar`, `/visit-sessions`, `/visit-packages`, `/visit-activities`, `/visitors`, `/visit-bookings` + lifecycle actions, `/visit-staff-roster`, `/visit-costs`, `/visit-retail-sales`, `/visitor-feedback`, `/visit-incidents`, `/reports/visit-profitability`), all license-gated and RBAC-checked (`visitor_coordinator`, `activity_staff`, `cashier` roles added).
- Configurable opening calendar (never hard-coded to any specific weekday), dynamic package/activity builders (Horse Ride and Cheese Making Workshop are seeded examples only), a full booking state machine (draft → confirmed → checked_in → completed, plus cancelled/no_show/refunded) with session-capacity and activity-capacity/animal-welfare/handler-assignment checks enforced at the right step, offline-safe idempotent walk-in bookings, a Farm Shop / Visitor POS that deducts either plain inventory or Mouneh finished-goods stock and posts into core Sales & Finance, and a profitability report computing every §9 formula (visitor revenue, direct visit cost, gross margin, revenue/visitor, activity utilization, retail conversion, average basket value, package profitability) from granular components rather than a booking's stored total.
- 149 backend tests passing (30 new pure-engine tests + 28 new API tests on top of the prior 91); `database/schema.sql` and a new Alembic migration verified against real PostgreSQL 16 (upgrade + downgrade), including a cross-module demo sale that debits real Mouneh Makdous stock.
- Mobile: all 10 screens from the build prompt (Dashboard, Opening Calendar, Package Builder, Activity Manager, Booking Form, Visit-Day Briefing, Visitor Check-in, Farm Shop/POS, Staff Roster & Costs, Profitability Report) behind one new "Farm Visits" nav entry, wired to a real `VisitsProvider` + offline-first `VisitsWriteService` (SQLite + event log + sync queue, same pipeline as the rest of the app), a Dart port of the analytics engine with its own unit tests, and live cross-module POS deduction through the existing `FeedProvider`/`MounehProvider`. Verified via a green GitHub Actions APK build — see `mobile/flutter_app/README.md` "Verification status".

**Next:**
- Wire `VisitsProvider` to read its state back from SQLite on launch (currently write-only persistence, like every other provider in this build).
- Feedback & Follow-up as its own screen if a future spec revision splits it back out of Visitor Check-in.
- Non-goals explicitly deferred per the build prompt: public booking website, online payment gateway, automated WhatsApp sending, QR ticket generation, CRM campaign automation, advanced tax/accounting integrations.

## v0.2.0 — Mouneh & Farm Product Processing Module

Adds the license-gated Mouneh & Farm Product Processing module (tech spec
v0.5) on top of the v0.1.0 MVP.

**Delivered:**
- Backend: `module_licenses`, `mouneh_products`, `mouneh_recipes`, `mouneh_recipe_items`, `raw_materials`, `cost_components`, `production_batches`, `batch_input_consumptions`, `finished_goods_stock`, `mouneh_sale_lines`, `mouneh_events` tables + a pure, unit-tested costing engine (`app/mouneh/costing.py`) + 17 new API endpoints (`/modules/*`, `/mouneh/*`), all license-gated and RBAC-checked.
- Super-user module activation, dynamic product creation (no hard-coded product types — verified in tests by creating a non-Makdous product), versioned recipes (never mutated in place), planned + actual cost calculation, full batch lifecycle (create → consume → complete → finished goods), sales with automatic FIFO stock draw-down and profit calculation, and a profitability dashboard with a continue-production/slow-mover/review-pricing recommendation per product.
- Makdous seeded as example data only, via the same dynamic mechanism a manager would use — 41 new backend tests (costing engine + API), all passing; `database/schema.sql` and a new Alembic migration verified against real PostgreSQL 16 (upgrade + downgrade).
- Mobile: all 7 screens from tech spec v0.5 §6 (Dashboard, Product Builder Wizard, Recipes & Materials, Cost Preview, Production Batches, Finished Goods, Sales & Profitability) behind one new "Mouneh & Products" nav entry, wired to a real `MounehProvider` + offline-first `MounehWriteService` (SQLite + event log + sync queue, same pipeline as the rest of the app), plus a Dart port of the costing engine and its own unit tests. Not yet verified against a real Flutter build — see `mobile/flutter_app/README.md` "Verification status".

**Next:**
- Verify the Mouneh mobile UI against a real Flutter build/APK.
- Wire `MounehProvider` to read its state back from SQLite on launch (currently write-only persistence, like the rest of the app's providers — see `mobile/flutter_app/README.md`).
- Real super-user login/role switching in the mobile UI, replacing the Settings-screen `Switch` stand-in.

## v0.1.0 — Tablet MVP Prototype

First implementation pass following the AI Agent Build Prompt / Technical
Specifications v0.3 build order (design tokens → AppShell → 10 Option C
screens with mock data → local SQLite → core workflow writes → FastAPI
backend + PostgreSQL schema → sync skeleton → rule-based recommendation
engine → tests + docs).

**Delivered:**
- All 10 Option C screens (Flutter) + Animal Digital Twin detail screen, on-brand and data-driven.
- EN/AR + RTL support, offline-first local write pipeline for the core animal/task/feed workflows.
- FastAPI backend: every endpoint from tech spec §12, PostgreSQL schema + Alembic migrations (verified against real PostgreSQL 16), rule-based recommendation engine (6 rules, unit tested and wired to real seeded data), RBAC.
- 66 backend tests passing; mobile widget/unit tests written but unverified (no Flutter SDK in the build environment — see `mobile/flutter_app/README.md`).

See `backend/README.md` and `mobile/flutter_app/README.md` for the detailed
completion boundary, and `product/TRACEABILITY.md` for the requirement map.

**Next (tech spec milestones M4–M9):**
- Wire remaining dashboards (Milk/Egg/Produce/Sales trend panels) to the local SQLite repository layer instead of the static demo dataset.
- Network the sync queue to the backend's `/sync/push` / `/sync/pull` (currently simulated on-device).
- Mobile login/role-switching UI on top of the already-implemented backend RBAC.
- Pilot hardening: exports, onboarding, conflict-review UI.
