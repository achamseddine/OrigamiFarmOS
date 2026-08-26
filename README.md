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
  database/                             schema.sql, migrations/, optional sample_data.sql and setup_with_sample_data.sql
  api/openapi.yaml                      Generated OpenAPI 3.1 spec for the backend
```

## Getting Started

Please refer to the `handbook/` and `product/` directories for detailed information on the vision, knowledge model, operational workflows, and product roadmap.

* `CONSTITUTION.md`: The non-negotiable principles of FarmOS.
* `CONCEPT_NOTE.md`: The full concept note for the project.
* `product/MVP_SCOPE.md`: The defined scope for the Minimum Viable Product.
* `product/TRACEABILITY.md`: Maps every tech-spec requirement to the code that implements it.

To run the backend API with an empty local SQLite database:

```bash
cd backend
pip install -r requirements.txt
uvicorn app.main:app --reload
```

To run the tablet app, see `mobile/flutter_app/README.md` (requires the
Flutter SDK, which was not available while building this MVP — see that
README's "Verification status" section).

## MVP Status

This tablet MVP uses database-backed empty states, the full brand theme,
EN/AR + RTL support, and a local-first write pipeline (SQLite + event log + sync queue)
for the core animal/task/feed workflows. The FastAPI backend implements
every endpoint from the tech spec, a rule-based recommendation engine
(6 rules, unit tested and wired end-to-end against real seeded data), and
role-based access control — 66 backend tests pass. See
`backend/README.md` and `mobile/flutter_app/README.md` for the detailed
"what's complete / what's mocked / what remains" breakdown, and
`product/TRACEABILITY.md` for the full requirement map.
