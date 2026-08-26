# Origami FarmOS — Backend (FastAPI)

Offline-first, tablet-first farm operating system API. See the repo root
`CONSTITUTION.md`, `CONCEPT_NOTE.md`, and `product/MVP_SCOPE.md` for the
product principles this API enforces, and `product/TRACEABILITY.md` for a
requirement-by-requirement map to the code below.

## Quick start (SQLite, no Postgres needed)

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate   # optional but recommended
pip install -r requirements.txt

# Seed the Option C demo dataset (creates origami_farmos.db in this folder)
python -m app.seed

# Run the API
uvicorn app.main:app --reload
```

Open http://127.0.0.1:8000/docs for interactive OpenAPI docs, or import
`api/openapi.yaml` (repo root) into your API client of choice.

Demo login (from the seed data):

| Email | Password | Role |
|---|---|---|
| `rami@origami.farm` | `farmos123` | manager |
| `owner@origami.farm` | `farmos123` | owner |
| `layla.vet@origami.farm` | `farmos123` | veterinarian |
| `karim.worker@origami.farm` | `farmos123` | worker |
| `nadine.acct@origami.farm` | `farmos123` | accountant |
| `super@origamifarms.com` | `farmos123` | super_user (Mouneh/Visits module license admin) |

```bash
curl -s -X POST http://127.0.0.1:8000/api/v1/auth/login \
  -H 'content-type: application/json' \
  -d '{"email":"rami@origami.farm","password":"farmos123"}'
```

Try `GET /api/v1/morning-briefing?farm_id=farm-origami` (with the returned
bearer token) — it re-evaluates the rule engine against the seeded history
and returns real, evidence-backed priorities (Bella's mastitis risk, the
duck flock's egg drop, low Corn Silage/Layer Feed stock, Willow's
withdrawal period, and the Field 2 harvest reminder — see
`app/seed.py` for how each scenario's history was built).

The Mouneh & Farm Product Processing module (tech spec v0.5) is seeded
already active with a Makdous example product, one completed batch and
one in-progress batch. Try:

```bash
TOKEN=$(curl -s -X POST http://127.0.0.1:8000/api/v1/auth/login \
  -H 'content-type: application/json' \
  -d '{"email":"rami@origami.farm","password":"farmos123"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

curl -s http://127.0.0.1:8000/api/v1/mouneh/dashboard -H "Authorization: Bearer $TOKEN"
```

A super user (`super@origamifarms.com`) can deactivate/reactivate the
module (every other Mouneh endpoint 403s while inactive):

```bash
SUPER_TOKEN=$(curl -s -X POST http://127.0.0.1:8000/api/v1/auth/login \
  -H 'content-type: application/json' \
  -d '{"email":"super@origamifarms.com","password":"farmos123"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -s -X POST http://127.0.0.1:8000/api/v1/modules/mouneh/deactivate -H "Authorization: Bearer $SUPER_TOKEN"
```

The Farm Visits & Agri-Tourism module (tech spec v0.6) is seeded already
active with a weekend-only (Friday/Saturday/Sunday) opening calendar,
two example activities (Horse Ride, Cheese Making Workshop) and bookings
spanning every status. Try:

```bash
curl -s http://127.0.0.1:8000/api/v1/visits/dashboard -H "Authorization: Bearer $TOKEN"
curl -s http://127.0.0.1:8000/api/v1/reports/visit-profitability -H "Authorization: Bearer $TOKEN"
```

## Running against PostgreSQL

```bash
createdb origami_farmos
psql origami_farmos -f ../database/schema.sql
export DATABASE_URL=postgresql://USER:PASS@localhost:5432/origami_farmos
python -m app.seed        # or: psql origami_farmos -f ../database/seed_demo_data.sql
uvicorn app.main:app --reload
```

`database/schema.sql` and `database/seed_demo_data.sql` are both verified
to apply cleanly to a real PostgreSQL 16 instance (including every CHECK
constraint) as part of this build.

## Migrations (Alembic)

`database/migrations/` (repo root, per the tech spec's repo layout) holds
the Alembic environment; `backend/alembic.ini` points at it.

```bash
cd backend
DATABASE_URL=postgresql://USER:PASS@localhost:5432/origami_farmos alembic upgrade head
# after changing backend/app/domain/models.py:
DATABASE_URL=postgresql://USER:PASS@localhost:5432/origami_farmos alembic revision --autogenerate -m "describe the change"
```

The initial migration (`database/migrations/versions/..._initial_schema.py`)
was generated from the SQLAlchemy models and verified with a real
`alembic upgrade head` / `alembic downgrade base` round-trip against
PostgreSQL 16.

## Tests

```bash
cd backend
DATABASE_URL=sqlite:///./ci.db pytest -q   # DATABASE_URL only affects the FastAPI app's
                                            # module-level startup table creation; tests
                                            # use an isolated tmp-path SQLite DB per test
                                            # (see tests/conftest.py) regardless.
```

149 tests, all passing as of this build: 16 pure unit tests for the
recommendation engine (`tests/test_recommendations.py`, no DB/HTTP
involved) and 34 API tests (`tests/test_api.py`) covering auth, RBAC,
every validation rule, the recommendation lifecycle (generate → decide →
survives refresh), sync push idempotency, and both report endpoints —
plus 41 tests for the Mouneh & Farm Product Processing module (21 pure
costing-engine unit tests in `tests/test_mouneh_costing.py` and 20 API
tests in `tests/test_mouneh_api.py`) — plus 58 tests for the Farm Visits
& Agri-Tourism module: 30 pure analytics/validation unit tests
(`tests/test_visits_analytics.py`) and 28 API tests
(`tests/test_visits_api.py`) covering license gating, opening-calendar
configuration, session/package/activity/visitor CRUD, the full booking
lifecycle (including capacity-exceeded rejection and idempotent
walk-ins), activity capacity/animal-welfare/handler-assignment
rejection, POS retail sales against both inventory and Mouneh
finished-goods stock, staff/cost recording, feedback/incidents, and
profitability reporting.

## Architecture

```
app/
  main.py                    FastAPI app, router wiring, CORS, lifespan (create_all for dev)
  core/config.py             Settings (env-driven DATABASE_URL, JWT secret, etc.)
  core/security.py           bcrypt password hashing, JWT issue/verify
  db/base.py                 SQLAlchemy engine/session, get_db dependency
  domain/models.py           SQLAlchemy ORM models — one per tech spec §9 table
  schemas/                   Pydantic request/response models + field validators
  repositories/base.py       Shared helpers: new_id(), write_event(), write_audit_log(), ensure_utc()
  recommendations/engine.py  Pure, unit-tested rule functions (no DB access)
  mouneh/
    costing.py               Pure, unit-tested cost/pricing/margin functions (tech spec v0.5 §7)
    seed.py                  Makdous demo data — built the same way a manager would through the API
  visits/
    analytics.py              Pure, unit-tested capacity/status/profitability functions (tech spec v0.6 §9)
    seed.py                    Weekend-calendar + Horse Ride/Cheese Workshop demo data
  services/
    recommendation_service.py  Reads DB state, calls engine.py, persists RecommendationDraft rows
    mouneh_service.py          Reads DB state (recipes, cost components), calls mouneh/costing.py
    visits_service.py          Reads DB state (bookings, sessions, costs), calls visits/analytics.py
    reports_service.py         Morning-briefing + daily-summary aggregation
  api/
    deps.py                  get_current_user, require_roles(...), require_module_license(...) RBAC/license dependencies
    v1/*.py                  One router per resource, matching tech spec §12's endpoint table
    v1/modules.py             Super-user module license activate/deactivate (tech spec v0.5 REQ-MOU-001)
    v1/mouneh.py               Products, recipes, raw materials, batches, finished goods, sales, dashboard
    v1/visits.py                Opening calendar, sessions, packages, activities, visitors, bookings + lifecycle, staff roster, costs, retail sales, feedback, incidents, profitability
  domain/mouneh_models.py    SQLAlchemy models for the Mouneh module (separate bounded context)
  domain/visits_models.py    SQLAlchemy models for the Visits module (separate bounded context)
  schemas/mouneh.py          Pydantic request/response models for the Mouneh module
  schemas/visits.py          Pydantic request/response models for the Visits module
  seed.py                    Idempotent demo-data seeder (also the tests' fixture data source)
```

Engine-agnostic by design: `domain/models.py` uses plain `String` ids and
`sqlalchemy.JSON` (not Postgres-specific `UUID`/`JSONB` types) so the exact
same code runs against SQLite for local dev/demo/tests and PostgreSQL for
pilot/staging/production. `database/schema.sql` is the hand-authored
PostgreSQL-specific source of truth (proper `UUID`, `TIMESTAMPTZ`, `JSONB`,
`CHECK` constraints) for environments that provision the database directly
rather than through the ORM.

### A note on datetimes and SQLite

SQLite has no native timezone-aware timestamp type, so a
`DateTime(timezone=True)` column round-trips as a **naive** Python
`datetime` on SQLite even though it stays timezone-aware on PostgreSQL.
Every datetime this app writes is UTC; `repositories/base.ensure_utc()`
normalizes a possibly-naive value back to aware-UTC before any in-Python
comparison against `datetime.now(timezone.utc)` (see
`services/recommendation_service.py` and `api/v1/production.py`). This was
caught and fixed by the test suite during development — see git history.

## What's complete

- All 15 endpoints from tech spec §12, matching the OpenAPI export in `api/openapi.yaml`.
- Full SQLAlchemy schema (23 core tables + 11 Mouneh module tables + 13 Visits module tables) + matching hand-authored PostgreSQL DDL, both verified.
- Alembic migrations, verified upgrade/downgrade against real PostgreSQL — including the Mouneh and Visits modules' migrations.
- Rule-based recommendation engine: all 6 rules from tech spec §15/§16, pure-function unit tested, and wired end-to-end against real seeded database history (not hardcoded output).
- Validation rules from tech spec §14 (milk, eggs, feed, treatment, observation, sync idempotency) enforced at the API layer with tests for both the accept and reject paths.
- RBAC: JWT auth + role dependency, tested for manager/vet allow and worker/accountant deny on the diagnosis-gated treatment endpoint.
- Event log + audit-log tables written by every mutating endpoint (Constitution: "every important change is an event").
- **Mouneh & Farm Product Processing module (tech spec v0.5):** license-gated per farm by a super user (`api/v1/modules.py`); a manager can define any product type through the Product Builder (no code changes — `POST /mouneh/products`); recipes (raw materials + packaging + labor + optional overhead costs) are versioned, never mutated in place; `POST /mouneh/cost-preview` and batch creation compute planned unit cost via the pure `app/mouneh/costing.py` engine; completing a batch consumes remaining raw-material stock and creates finished-goods stock at a frozen unit cost; sales deduct from that stock and compute profit against the batch's actual (not recomputed) cost; the dashboard aggregates cost, sales, remaining stock and a continue/slow-mover/review-pricing recommendation per product. Makdous is seeded purely as example data (`app/mouneh/seed.py`) — the module has no hard-coded product types anywhere.
- **Farm Visits & Agri-Tourism module (tech spec v0.6):** license-gated the same way, reusing the same `module_licenses` table; opening days are a configurable per-weekday calendar, never hard-coded (RULE-VIS-003); packages and activities (Horse Ride, Cheese Making Workshop are seed examples only — RULE-VIS-010) are created dynamically; a booking's status machine (draft → confirmed → checked_in → completed/cancelled/no_show → refunded) is enforced by `app/visits/analytics.py::validate_status_transition`; session guest capacity is checked at confirm time and activity-slot capacity + animal-welfare daily limits are checked at booking time (RULE-VIS-002/004); a ride/animal-interaction activity requires a handler with the matching role already rostered on the session before it can be confirmed (RULE-VIS-005); a Farm Shop / Visitor POS sale deducts either plain inventory or Mouneh finished-goods stock and posts a core `Sale` row so it shows up in Sales & Finance (RULE-VIS-006); every analytics formula in tech spec §9 (visitor revenue, direct visit cost, gross margin, revenue/visitor, activity utilization, retail conversion, average basket value, package profitability) is recomputed from granular components rather than trusted off a booking's stored total, specifically to avoid double-counting activity revenue.

## What's mocked / simplified

- **Sync push reconciliation is partial.** `POST /sync/push` durably records every item (event + `sync_queue` row, idempotent via `idempotency_key`) and materializes the write types the mobile app's `FarmWriteService` already produces (task status, milk records, feed transactions) back into their domain tables. Less common event types are accepted and event-logged but not yet replayed into a domain-table write — see the docstring on `api/v1/sync.py::push`. Adding a new entity type follows the same pattern as the three already there.
- **Conflict resolution UI does not exist.** `SyncItemResult.status` distinguishes `accepted`/`duplicate`/`rejected`, satisfying REQ-SYNC-004's "conflicts must be visible", but there's no manager-facing conflict review screen yet (tracked as pilot-hardening work, tech spec milestone M9).
- **No refresh-token flow.** `POST /auth/login` issues a single long-lived (8h default) access token; a refresh-token endpoint is straightforward follow-on work.
- **No media/photo upload endpoint.** Matches the mobile app's `PhotoSlot` being a placeholder-only widget in this build.
- **`GET /animals` search is a simple `ILIKE`**, not a full-text index — fine at demo/pilot scale, would want a proper index before commercial scale.

## Known limitations

- The bundled `bcrypt`/`python-jose` combination depends on the `cryptography`
  package's compiled Rust extension. If you see `ModuleNotFoundError: No
  module named '_cffi_backend'` on import, reinstall `cffi`:
  `pip install --force-reinstall --no-deps cffi`. This was hit and fixed
  during this build's own verification pass in a minimal container image;
  a normal `pip install -r requirements.txt` on a standard machine should
  not need this.
