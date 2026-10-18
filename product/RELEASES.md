# Releases

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
