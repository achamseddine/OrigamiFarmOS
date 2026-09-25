# Traceability Matrix

Maps the tech spec (`Origami_FarmOS_Technical_Specifications_v0.3.pdf`,
extended by `Origami_FarmOS_Technical_Specifications_v0.5.pdf` for the
Mouneh & Farm Product Processing module and
`Origami_FarmOS_Technical_Specifications_v0.6.pdf` for the Farm Visits &
Agri-Tourism module) and `CONSTITUTION.md` to the code that implements each
requirement. Update this file whenever a requirement's implementation moves.

## Option C screens (tech spec §7/§8)

| # | Screen | Flutter implementation |
|---|---|---|
| 1 | Welcome / Start My Day | `mobile/flutter_app/lib/features/welcome/welcome_screen.dart` |
| 2 | Morning Briefing Dashboard | `mobile/flutter_app/lib/features/morning/morning_briefing_screen.dart` |
| 3 | Animal Status Overview | `mobile/flutter_app/lib/features/animals/animal_status_screen.dart` |
| 4 | Animal Digital Twin | `mobile/flutter_app/lib/features/animals/animal_digital_twin_screen.dart` |
| 5 | Feed & Inventory | `mobile/flutter_app/lib/features/feed/feed_inventory_screen.dart` |
| 6 | Milk Production | `mobile/flutter_app/lib/features/production/milk_production_screen.dart` |
| 7 | Egg Production | `mobile/flutter_app/lib/features/production/egg_production_screen.dart` |
| 8 | Health Intelligence | `mobile/flutter_app/lib/features/health/health_intelligence_screen.dart` |
| 9 | Produce & Harvest | `mobile/flutter_app/lib/features/produce/produce_harvest_screen.dart` |
| 10 | Sales, Expenses & Daily Summary | `mobile/flutter_app/lib/features/finance/sales_finance_screen.dart` |
| — | Tasks (nav item, tech spec §6) | `mobile/flutter_app/lib/features/tasks/tasks_screen.dart` |
| — | Settings (nav item, tech spec §6) | `mobile/flutter_app/lib/features/settings/settings_screen.dart` |

## CONSTITUTION.md principles

| Principle | Where it's enforced |
|---|---|
| Offline first | Local SQLite writes in `data/local/farm_write_service.dart` succeed with no backend call; `sync/sync_queue_controller.dart` models the deferred upload. |
| Tablet first | `core/widgets/app_shell.dart`, `core/widgets/nav_rail.dart` (1024–1366px target, 232px rail, 48px touch targets in `core/theme/spacing.dart`). |
| Morning first | `app/app.dart` `_RootRouter` routes `Start My Day` straight into `MorningBriefingScreen` at index 0. |
| Workers observe, workers do not diagnose | `features/animals/animal_quick_actions.dart` `_ObserveDialog` has no diagnosis field; `domain/entities/observation.dart` `Observation` has no diagnosis field. Backend: `schemas/observations.py` `ObservationCreate` — same. |
| Veterinarians diagnose and prescribe | `data/local/farm_write_service.dart` `recordTreatment` (mobile, UI-level gate via the Treat action). Backend: `api/deps.py` `require_diagnostic_role`, enforced in `api/v1/health.py`. |
| AI explains, never replaces judgement | `domain/entities/recommendation.dart` / backend `recommendations/engine.py` — every `RecommendationDraft` carries `rationale`, `evidence`, `confidence`, `suggested_action`; nothing auto-applies without a `PATCH .../decision`. |
| Every recommendation has evidence + confidence | `recommendations/engine.py` (backend, pure functions) + `providers`/`features/health/health_intelligence_screen.dart` (mobile display). |
| Every object has one digital twin | `domain/entities/animal.dart` `Animal` (mobile) / `domain/models.py` `Animal` (backend) — single row per animal, referenced by every other table via `entity_id`. |
| Every important change is an event | `data/local/farm_write_service.dart` `_writeEventAndQueue` (mobile) / `repositories/base.py` `write_event` (backend) — called by every mutating method/endpoint. |
| History is never silently deleted | `services/recommendation_service.py` `regenerate_recommendations` only clears `status='generated'` (undecided) rows; decided ones are preserved. |
| Arabic + RTL | `core/i18n/` (mobile) + `MaterialApp(locale:, supportedLocales: [en, ar])` in `app/app.dart`. |

## Offline-first sync requirements (tech spec §10/§11)

| Requirement | Implementation |
|---|---|
| REQ-SYNC-001 (core workflows work offline) | `data/local/farm_write_service.dart` — observations, milk, feed, tasks, treatments write to SQLite with no network call. |
| REQ-SYNC-002 (sync status visible in top bar) | `core/widgets/top_bar.dart` `_SyncPill`. |
| REQ-SYNC-003 (local + server timestamps) | `domain/entities/observation.dart` `FarmEvent.createdAt` (mobile) / `models.Event.created_at` + `server_created_at` (backend). |
| REQ-SYNC-004 (conflicts reviewable) | `api/v1/sync.py` `SyncItemResult.status` (`accepted`/`duplicate`/`rejected`) surfaces per-item outcome; full conflict-review UI is future work — see backend/README.md "What remains". |
| REQ-SYNC-005 (media upload failures don't block core writes) | No media capture is wired in this build (`core/widgets/photo_slot.dart` is a placeholder-only slot) — see README "What's mocked". |

## Validation rules (tech spec §14)

| Rule | Mobile | Backend |
|---|---|---|
| Observation requires entity/type/observer, no diagnosis field | `data/local/farm_write_service.dart` `recordObservation` | `schemas/observations.py` |
| Milk liters ≥ 0 | `animal_quick_actions.dart` `_MilkDialogState._submit` | `schemas/production.py` `MilkRecordCreate` |
| Milk + active withdrawal + destination=sold → blocked | `data/local/farm_write_service.dart` `recordMilk` | `api/v1/production.py` `record_milk` |
| Egg allocation ≤ total | `domain/entities/production.dart` `EggRecord.isValid` | `schemas/production.py` `EggRecordCreate.is_allocation_valid` |
| Feed stock can't go negative without override | `data/local/farm_write_service.dart` `recordFeedTransaction` | `api/v1/feed.py` `create_feed_transaction` |
| Treatment requires medication/dose/route/responsible user | `animal_quick_actions.dart` `_TreatDialogState._submit` | `schemas/health.py` `TreatmentCreate` |
| Recommendation requires evidence/confidence/rationale/priority/action | `domain/entities/recommendation.dart` (all fields required, non-null) | `recommendations/engine.py` `RecommendationDraft` (same) |
| Sync idempotency key dedup | — | `api/v1/sync.py` `push`, `models.SyncQueueItem.idempotency_key` (unique) |

## Recommendation engine rules (tech spec §15/§16)

| Rule | Function | Test |
|---|---|---|
| Health risk (milk↓ + feed↓ + fever + history) | `recommendations/engine.py` `evaluate_health_risk` | `tests/test_recommendations.py::TestHealthRisk` |
| Low feed / days remaining | `evaluate_low_feed` | `TestLowFeed` |
| Egg production down >20% | `evaluate_egg_drop` | `TestEggDrop` |
| Active withdrawal + sale destination | `evaluate_withdrawal_conflict` | `TestWithdrawal` |
| Harvest due within 48h | `evaluate_harvest_due` | `TestHarvestDue` |
| Feed cost share unusually high | `evaluate_feed_cost_insight` | `TestFeedCostInsight` |

All six are wired end-to-end against real (seeded) database state in
`services/recommendation_service.py::regenerate_recommendations`, exercised
by `tests/test_api.py::TestRecommendations`.

## API endpoints (tech spec §12)

Every endpoint in the spec's table is implemented — see
`backend/app/api/v1/*.py` and `api/openapi.yaml` for the generated
OpenAPI 3.1 spec. RBAC roles (tech spec §17) are enforced in
`backend/app/api/deps.py`.

## Mouneh & Farm Product Processing module (tech spec v0.5)

License-gated bounded context, kept out of the core domain — see
`backend/app/domain/mouneh_models.py`, `backend/app/mouneh/`,
`backend/app/api/v1/{modules,mouneh}.py`, and the mobile mirror under
`mobile/flutter_app/lib/{mouneh,features/mouneh}/`. Makdous is demo data
only (`backend/app/mouneh/seed.py`, `mobile/flutter_app/lib/data/demo/mouneh_demo_data.dart`)
— nothing in the module's code branches on a specific product name.

| Requirement | Backend | Mobile |
|---|---|---|
| REQ-MOU-001 License-controlled module, super user activates/deactivates per farm | `api/v1/modules.py`, `api/deps.py::require_module_license`, `domain/mouneh_models.py::ModuleLicense` | `providers/mouneh_provider.dart::setModuleActive`, `features/settings/settings_screen.dart` "Modules" section |
| REQ-MOU-002/003 Dynamic Product Builder — no hard-coded product types | `api/v1/mouneh.py::create_product/create_recipe`, `schemas/mouneh.py` (free-text `name`/`category`, enum only on `output_unit`) | `features/mouneh/product_builder_tab.dart`, `features/mouneh/recipe_setup_tab.dart` |
| REQ-MOU-004 Planned cost per batch and per unit | `app/mouneh/costing.py::compute_cost_breakdown` (pure), `services/mouneh_service.py` (DB-touching wrapper), `POST /mouneh/cost-preview` | `lib/mouneh/costing.dart` (Dart port), `features/mouneh/cost_preview_tab.dart` |
| REQ-MOU-005 Batch completion consumes stock and creates finished goods | `api/v1/mouneh.py::create_batch/consume_batch_inputs/complete_batch` | `providers/mouneh_provider.dart::createBatch/consumeBatchInputs/completeBatch`, `mouneh/mouneh_write_service.dart` |
| REQ-MOU-006 Sales reduce finished goods stock and calculate profit | `api/v1/mouneh.py::record_sale`, `app/mouneh/costing.py::compute_sale_margin` | `providers/mouneh_provider.dart::recordSale`, `features/mouneh/sales_profitability_tab.dart` |
| REQ-MOU-007 Dashboard: production, cost, sales, stock, profitability | `api/v1/mouneh.py::dashboard/product_profitability`, `services/mouneh_service.py::product_profitability` | `features/mouneh/mouneh_dashboard_tab.dart`, `providers/mouneh_provider.dart::allProfitability` |
| REQ-MOU-008 Works offline, syncs safely; never overwrites historical batch records | `mouneh_recipes.version` (new row per change, never mutated), `mouneh_events` mirror table | `mouneh/mouneh_write_service.dart` (local-first SQLite write + `events`/`sync_queue` row per action, same pipeline as `farm_write_service.dart`) |

Database entities match the names given in the v0.5 build prompt (as
plural SQLAlchemy/PostgreSQL table names, consistent with every other
table in this schema): `module_licenses`, `mouneh_products`,
`mouneh_recipes`, `mouneh_recipe_items`, `raw_materials`,
`cost_components`, `production_batches`, `batch_input_consumptions`,
`finished_goods_stock`, `mouneh_sale_lines` — see
`database/schema.sql` and `database/migrations/versions/..._mouneh_module.py`.

Tests: `backend/tests/test_mouneh_costing.py` (pure engine, mirrors
`mobile/flutter_app/test/mouneh/costing_test.dart`) and
`backend/tests/test_mouneh_api.py` (license gating, dynamic product
creation, recipe versioning, full batch lifecycle, sales, dashboard —
covering every acceptance criterion in the v0.5 build prompt).

## Farm Visits & Agri-Tourism module (tech spec v0.6)

A second license-gated bounded context, structured identically to the
Mouneh module — see `backend/app/domain/visits_models.py`,
`backend/app/visits/`, `backend/app/api/v1/visits.py`, and the mobile
mirror under `mobile/flutter_app/lib/{visits,features/visits}/`. Both
modules reuse the same generic `module_licenses` table (`ModuleLicense`)
rather than each defining their own. "Horse Ride" and opening on
Friday/Saturday/Sunday are demo data only (`backend/app/visits/seed.py`,
`mobile/flutter_app/lib/data/demo/visits_demo_data.dart`) — RULE-VIS-003
and RULE-VIS-010 both require that opening days and activities stay
dynamic, never hard-coded, and nothing in the module's code branches on
either.

| Rule | Backend | Mobile |
|---|---|---|
| RULE-VIS-001 License-controlled module (status active/trial), super user activates/deactivates per farm | `api/deps.py::require_module_license` (`LICENSE_ACTIVE_STATUSES`), `domain/mouneh_models.py::ModuleLicense` | `providers/visits_provider.dart::setModuleActive`, `features/settings/settings_screen.dart` "Modules" section |
| RULE-VIS-002 Booking cannot be confirmed if session capacity would be exceeded | `app/visits/analytics.py::validate_session_capacity`, checked in `api/v1/visits.py::confirm_booking` | `lib/visits/analytics.dart::validateSessionCapacity`, checked in `providers/visits_provider.dart::confirmBooking` |
| RULE-VIS-003 Opening days configurable per farm, never hard-coded | `domain/visits_models.py::VisitOpeningCalendar`, `POST /visit-calendar` | `features/visits/opening_calendar_tab.dart`, `providers/visits_provider.dart::upsertCalendarDay` |
| RULE-VIS-004 Activity capacity/duration/price + animal-welfare daily limit | `app/visits/analytics.py::validate_activity_capacity/validate_welfare_limit` | `lib/visits/analytics.dart::validateActivityCapacity/validateWelfareLimit`, `features/visits/activity_manager_tab.dart` |
| RULE-VIS-005 Ride/animal-interaction activities require a handler assigned to the session | `app/visits/analytics.py::validate_handler_assignment`, checked at confirm time | `lib/visits/analytics.dart::validateHandlerAssignment`, `providers/visits_provider.dart::confirmBooking` |
| RULE-VIS-006 Visitor POS sales deduct inventory and appear in Sales & Finance | `api/v1/visits.py::create_retail_sale` (deducts `InventoryTransaction` or `MounehSaleLine`, creates a core `Sale` row `product_type="visitor_retail"`) | `providers/visits_provider.dart::recordInventoryRetailSale/recordMounehRetailSale` (deducts via `FeedProvider`/`MounehProvider`'s own write service) |
| RULE-VIS-008 Booking status machine (draft→confirmed→checked_in→completed, cancelled/no_show/refunded) | `app/visits/analytics.py::validate_status_transition` | `lib/visits/analytics.dart::validateStatusTransition`, `providers/visits_provider.dart::_transition` |
| RULE-VIS-009 Offline walk-in bookings sync with conflict handling | `visit_bookings.idempotency_key` (unique per farm, dedup on repeated sync) | `visit_bookings.idempotency_key` column, `VisitsProvider.createBooking`'s dedup check |
| Analytics formulas (§9): visitor revenue, direct visit cost, gross margin, revenue/visitor, activity utilization, retail conversion, avg basket value, package profitability | `app/visits/analytics.py` (pure functions) + `services/visits_service.py::_profitability_for_bookings` (DB aggregation, recomputes from granular components rather than trusting `booking.total_amount`) | `lib/visits/analytics.dart` (Dart port) + `providers/visits_provider.dart::profitabilityFor` |

Database entities match the exact names given in the v0.6 build prompt:
`module_license` (reuses `module_licenses`), `visit_opening_calendar`,
`visit_session`, `visit_package`, `visit_activity`, `visitor_profile`,
`visit_booking`, `visit_booking_activity`, `visit_staff_roster`,
`visit_cost`, `visit_retail_sale`, `visitor_feedback`, `visit_incident` —
see `database/schema.sql` and
`database/migrations/versions/..._farm_visits_and_agritourism_module.py`.

Screens (tech spec v0.6 §6 — the build prompt's 10 named screens; the tech
spec PDF's UI table also lists an 11th, "Feedback & Follow-up", which is
folded into Visitor Check-in rather than added as a separate tab):
Visitor Module Dashboard, Opening Calendar, Package Builder, Activity
Manager, Booking Form (also hosts session creation), Visit-Day Briefing
(also hosts incident logging and session status), Visitor Check-in (also
hosts feedback capture), Farm Shop / Visitor POS, Staff Roster & Costs,
Visitor Profitability Report — all under
`mobile/flutter_app/lib/features/visits/`.

Tests: `backend/tests/test_visits_analytics.py` (pure engine, mirrors
`mobile/flutter_app/test/visits/analytics_test.dart`) and
`backend/tests/test_visits_api.py` (license gating, capacity/welfare/handler
rejection, booking lifecycle, idempotent walk-ins, POS deduction against
both inventory and Mouneh finished-goods stock, profitability).

## What remains

See `mobile/flutter_app/README.md` and `backend/README.md` "What's
complete / mocked / remaining" sections for the current implementation
boundary (per tech spec Definition of Done).
