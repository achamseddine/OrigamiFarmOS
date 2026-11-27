# Runbook — a PostgreSQL 16 staging server, its backup and its recovery

Master prompt Package 6. A staging server you can build from nothing, check end to end, back up, restore, restart and throw away, with **synthetic farm records only** (the demo farm of `backend/app/seed.py`). It never touches production or real farm data:
- it builds its own database (the names contain `staging`);
- it ignores `DATABASE_URL` and `PROD_DATABASE_URL`;
- the smoke test refuses any server except this machine (or, if you ask, a host whose name says staging).

Deploying to production stays the manual workflow `migrate-seed-db.yml`. This runbook does not change it.

## One command

```bash
PYTHON=backend/.venv/bin/python scripts/staging/staging.sh all
```

Each step's result goes into a report at `$STAGING_DIR/reports/summary-<time>.md`. The default `STAGING_DIR` is `/tmp/origami-staging`. A failing check fails its step and the exit code. The steps:

| Step | What it proves |
|---|---|
| **PostgreSQL 16**, a cluster of its own (`initdb`, port `STAGING_PG_PORT`, default 55440) | the version is 16; nothing else on the machine is touched |
| **migrations from empty** (`alembic upgrade head`), then `alembic current` = `alembic heads` | the migration chain builds the whole schema on a new server |
| **the synthetic farm** (`python -m app.seed`) | the seed command works as a script (see *Found by this runbook*) |
| **the API** (uvicorn; a random `FARMOS_SECRET_KEY` kept in `$STAGING_DIR/secret`, mode 600) and **`/health`** | the configured server starts and answers |
| **API smoke tests** (`python -m app.staging.smoke`) | see the list below |
| **backup**: `pg_dump --format=custom`, a SHA-256 checksum, a table snapshot (row count and row checksum of every table, the Alembic revision) | a restorable, verifiable backup |
| **restore** into `origami_staging_restore`: checksum verified, `pg_restore --exit-on-error`, the snapshot compared, at the head revision, then a second API on the restored copy finds every record the smoke test made | the backup restores to the same data, and a server can run on it |
| **restart persistence**: the API and PostgreSQL stopped (`pg_ctl stop -m fast`) and started again; the records found again; `alembic upgrade head` again is a no-op | nothing lives only in memory; migrating twice is safe |
| **reconciliation dry runs**: `python -m app.feed_stock_integrity --json` (exit 0: every feed product consistent with its movements); the Mouneh-sales reconciliation, the milk-safety review and the purchases reconciliation (where the server has it) are read in the smoke test | the reconciliations report and apply nothing |

**The client tools must be the server's own major version.** `pg_dump` and `pg_restore` are taken from the server's
version directory (`/usr/lib/postgresql/16/bin` on Debian/Ubuntu), never simply the first on the PATH
(`backend/app/staging/pg_tools.py`): a newer `pg_dump` writes settings the older server refuses on restore — pg_dump 17
writes `SET transaction_timeout`, which PostgreSQL 16 rejects, and `--exit-on-error` stops the restore. Install
`postgresql-client-16` next to a newer client, or set `PG_BIN`. CI does this, and sets `FARMOS_REQUIRE_PG_TOOLS=1` so the
backup and restore test fails rather than skips when the tools are missing.

The smoke test covers:
- health, and the published OpenAPI contract;
- a signed-out request refused (401);
- the manager signs in, then their profile, farm, access and farm settings;
- the reads the tablet starts with;
- an expense, a milk record and a feed delivery, each sent twice with the same `Idempotency-Key` and recorded once;
- the saleable milk counted once in the tank;
- the morning briefing;
- the reconciliation dry runs;
- a worker refused the manager's reconciliation (403).

## Step by step

```bash
scripts/staging/staging.sh up              # PostgreSQL, migrations, synthetic farm, API
scripts/staging/staging.sh smoke           # writes $STAGING_DIR/state.json (what it created)
scripts/staging/staging.sh backup          # $STAGING_DIR/backups/origami_staging-<time>.dump (+ .sha256, .snapshot.json)
scripts/staging/staging.sh restore [DUMP]  # the latest backup by default
scripts/staging/staging.sh restart-check
scripts/staging/staging.sh reconcile
scripts/staging/staging.sh down            # stop; `down --purge` also deletes $STAGING_DIR
```

Environment: `PYTHON` (a Python with `backend/requirements.txt`), `STAGING_DIR`, `STAGING_PG_PORT`, `STAGING_API_PORT` (8770), `STAGING_RESTORE_API_PORT` (8771), `STAGING_SCHEDULER` (false: the analytical cycles off for repeatable checks).

### Requirements

The PostgreSQL 16 server and client tools (`postgresql-16`), `curl`, and Python with the backend requirements.

When run as root, the cluster runs as the `postgres` user, which must be able to enter `STAGING_DIR`. Keep it under `/tmp`, not under a private home directory.

### With Docker instead

```bash
STAGING_MODE=docker scripts/staging/staging.sh all
```

This uses `deploy/staging/docker-compose.yml`: `postgres:16-alpine` and the API image from `deploy/staging/Dockerfile`. The image has the backend and the migrations, runs as an unprivileged user, and refuses to start without `FARMOS_SECRET_KEY`.

Both ports are bound to 127.0.0.1. Migrations, the seed, the smoke tests, the backup, the restore and the checks run from this machine against those ports, exactly as in local mode, so the Python and PostgreSQL client tools are still needed.

## Restoring a real backup elsewhere

The same commands restore any custom-format dump into a **new** database, and compare it with the snapshot taken at backup time:
- `pg_restore --no-owner --exit-on-error`
- `python -m app.staging.snapshot --compare`

Never restore over a live database. Restore beside it, check, then switch the server's `DATABASE_URL`.

For production backups, use the hosting provider's point-in-time restore (Azure Database for PostgreSQL keeps 7–35 days). Its restore should be rehearsed the same way: restore to a new server, compare, run the smoke test against a staging API pointed at it.

## Found by this runbook

The first staging run found that `python -m app.seed`, the README's own quick start, failed as a script: `NameError: name '_seed_rule_groups_and_responsibilities' is not defined`. The `__main__` block sat above a helper the seed calls, so the module stopped before creating the farm. The result was an empty farm nobody could sign in to. Every test imports the module, so none had seen it.

The block now sits at the end of `seed.py`, and `tests/test_seed_command.py` runs the command as a subprocess.

## Automated

`backend/tests/test_staging_chain_pg.py` runs the same chain in one test on the CI PostgreSQL 16 service and in `scripts/verify-all.sh` (PostgreSQL stage):
- migrations from empty, the seed and the smoke test;
- `pg_dump` and `pg_restore`, compared table by table;
- the records found on the restored copy and through a new connection pool;
- the feed stock check.

It skips the dump and restore only when the client tools are missing or older than the server. `tests/test_staging_tools.py` checks the smoke test's server guard and the snapshot comparison.

## Not covered here

- A production deployment, or any real farm data.
- The Azure App Service, its configuration and secrets, and its network rules (`docs/AZURE-BACKEND-CONNECTION.md`).
- Point-in-time recovery of a managed server.
- The physical tablets and browsers against the staging API: they are checked by hand (*Check API (no password sent)* on the sign-in screen).
- The Docker path was not run in the environment that built this runbook (no Docker daemon there); the local path was, end to end.
