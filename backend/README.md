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

66 tests, all passing as of this build: 16 pure unit tests for the
recommendation engine (`tests/test_recommendations.py`, no DB/HTTP
involved) and 50 API tests (`tests/test_api.py`) covering auth, RBAC,
every validation rule, the recommendation lifecycle (generate → decide →
survives refresh), sync push idempotency, and both report endpoints.

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
  services/
    recommendation_service.py  Reads DB state, calls engine.py, persists RecommendationDraft rows
    reports_service.py         Morning-briefing + daily-summary aggregation
  api/
    deps.py                  get_current_user, require_roles(...) RBAC dependencies
    v1/*.py                  One router per resource, matching tech spec §12's endpoint table
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
- Full SQLAlchemy schema (23 tables) + matching hand-authored PostgreSQL DDL, both verified.
- Alembic migrations, verified upgrade/downgrade against real PostgreSQL.
- Rule-based recommendation engine: all 6 rules from tech spec §15/§16, pure-function unit tested, and wired end-to-end against real seeded database history (not hardcoded output).
- Validation rules from tech spec §14 (milk, eggs, feed, treatment, observation, sync idempotency) enforced at the API layer with tests for both the accept and reject paths.
- RBAC: JWT auth + role dependency, tested for manager/vet allow and worker/accountant deny on the diagnosis-gated treatment endpoint.
- Event log + audit-log tables written by every mutating endpoint (Constitution: "every important change is an event").

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
