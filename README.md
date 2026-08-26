# Origami FarmOS

**The Intelligent Operating System for Origami Farms**

Origami FarmOS is an offline-first, tablet-first digital operating system designed to manage the daily operations, production, health, inventory, finance, and decision-making needs of Origami Farms.

## Philosophy

FarmOS helps farmers make better decisions with less effort.

Unlike traditional farm management software that primarily stores records, FarmOS is designed as a knowledge-driven platform. It captures observations from workers, production data from daily activities, health records, feeding information, inventory movements, sales, expenses, and farm events. It then transforms this information into evidence-based insights and recommendations for the farm manager.

## Core Features

* **Offline First:** Farm operations cannot stop because internet connectivity is unavailable. FarmOS works fully offline for all critical workflows.
* **Tablet First:** The primary device is an Android tablet used in the barn, stable, field, or storage area.
* **Workers Observe, Managers Decide:** FarmOS separates observation from diagnosis. Workers record what they see, and the system correlates observations to support the manager and veterinarian.
* **Evidence Before Opinion:** Every recommendation is supported by evidence.
* **One Digital Twin per Object:** Every physical object on the farm (animals, flocks, fields, etc.) has one digital representation.

## Repository Structure

```
origami-farmos/
  CONSTITUTION.md, CONCEPT_NOTE.md      Product principles and concept note
  handbook/                             Vision, ontology, knowledge model, operational workflows
  product/                              MVP scope, roadmap, requirement-to-code traceability
  design-system/                        Brand tokens, component spec, icons, logo (source of truth for both apps)
  Branding kit/                         Full Option C UI kit: mockup screenshots, tokens, icons, styleguide
  mobile/flutter_app/                   Tablet app (Flutter) — see mobile/flutter_app/README.md
  backend/                              API (FastAPI) — see backend/README.md
  database/                             schema.sql (PostgreSQL DDL), migrations/ (Alembic), seed_demo_data.sql
  api/openapi.yaml                      Generated OpenAPI 3.1 spec for the backend
```

## Getting Started

Please refer to the `handbook/` and `product/` directories for detailed information on the vision, knowledge model, operational workflows, and product roadmap.

* `CONSTITUTION.md`: The non-negotiable principles of FarmOS.
* `CONCEPT_NOTE.md`: The full concept note for the project.
* `product/MVP_SCOPE.md`: The defined scope for the Minimum Viable Product.
* `product/TRACEABILITY.md`: Maps every tech-spec requirement to the code that implements it.

To run the backend API (seeded demo data, no PostgreSQL required):

```bash
cd backend
pip install -r requirements.txt
python -m app.seed
uvicorn app.main:app --reload
```

To run the tablet app, see `mobile/flutter_app/README.md` (requires the
Flutter SDK, which was not available while building this MVP — see that
README's "Verification status" section).

## MVP Status

This is the first tablet MVP build. All 10 Option C manager-demo screens
are implemented in Flutter with the full brand theme, EN/AR + RTL support,
and a real local-first write pipeline (SQLite + event log + sync queue)
for the core animal/task/feed workflows. The FastAPI backend implements
every endpoint from the tech spec, a rule-based recommendation engine
(6 rules, unit tested and wired end-to-end against real seeded data), and
role-based access control — 149 backend tests pass. See
`backend/README.md` and `mobile/flutter_app/README.md` for the detailed
"what's complete / what's mocked / what remains" breakdown, and
`product/TRACEABILITY.md` for the full requirement map.

### Mouneh & Farm Product Processing module (v0.5)

A license-gated module (activated per farm by a super user) letting a
manager turn any farm harvest into a priced, sellable product — Makdous,
Labneh, Kishk, Jam, or a custom item, with no code changes. Covers the
full loop: Dynamic Product Builder → recipe (raw materials, packaging,
labor, optional overhead costs) → automatic planned/actual cost per unit
→ production batches → finished-goods stock → sales → profitability
dashboard (cost per unit, margin, sales velocity, and a
continue-production / slow-mover / review-pricing call per product).
Backend: `backend/app/mouneh/`, `backend/app/api/v1/{modules,mouneh}.py`,
`backend/app/domain/mouneh_models.py` — 41 tests (`backend/tests/test_mouneh_*.py`),
verified against real PostgreSQL (schema + Alembic migration). Mobile:
`mobile/flutter_app/lib/{mouneh,features/mouneh}/` — 7 screens behind one
"Mouneh & Products" nav entry, a Dart port of the costing engine, and the
same offline-first SQLite write pipeline as the rest of the app. Makdous
is demo data only; see `product/TRACEABILITY.md` for the full
requirement-to-code map.

### Farm Visits & Agri-Tourism module (v0.6)

A second license-gated module, structured the same way as Mouneh, letting
a farm owner open the farm to visitors on a configurable set of days
(never hard-coded to any specific weekday) and manage the full loop:
opening calendar, dynamic package/activity builders (any activity, not
just a ride or a workshop), visitor bookings with a full status machine
(draft to confirmed to checked_in to completed, or cancelled/no_show to
refunded), session-capacity/activity-capacity/animal-welfare/handler
checks enforced at the right step, staff roster & direct costs, a Farm
Shop / Visitor POS that deducts real inventory or Mouneh finished-goods
stock and posts into Sales & Finance, and a profitability report covering
every formula in the spec (visitor revenue, direct visit cost, gross
margin, revenue per visitor, activity utilization, retail conversion,
average basket value, package profitability). Backend:
`backend/app/visits/`, `backend/app/api/v1/visits.py`,
`backend/app/domain/visits_models.py` — 58 tests
(`backend/tests/test_visits_*.py`), verified against real PostgreSQL
(schema + Alembic migration), including a cross-module demo sale that
debits real Mouneh Makdous stock. Mobile:
`mobile/flutter_app/lib/{visits,features/visits}/` — 10 screens behind
one "Farm Visits" nav entry, a Dart port of the analytics engine, and the
same offline-first SQLite write pipeline as the rest of the app. Horse
Ride and the weekend-only opening calendar are demo data only; see
`product/TRACEABILITY.md` for the full requirement-to-code map.
