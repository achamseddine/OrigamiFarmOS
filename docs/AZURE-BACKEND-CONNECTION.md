# Origami FarmOS — staging API versus PostgreSQL database

## Critical distinction

The user-supplied URL **`https://leb-container-test-staging.azurewebsites.net`** is an
**Azure App Service HTTPS address**, **not** a PostgreSQL database connection string.

**Status (2026-11-14): publicly reachable multi-tenant staging service.**
A read-only GitHub Actions network probe verified that the hostname resolves
and responds over HTTPS, with:
- `GET /` → HTTP 200, a Next.js web front end (HTML, not a FastAPI JSON root).
- `GET /health` → HTTP 200, JSON status `ok`, server version `1e4634b`
  built `2026-10-23T13:30:37Z`.
- `GET /openapi.json` → HTTP 200, `Origami Server API` with 251 routes.
- `POST /api/v1/auth/login`, `GET /api/v1/auth/me`,
  `GET /api/v1/me/access` and `GET /api/v1/modules/catalog`
  are described in OpenAPI. The published login schema accepts email and
  password and returns an access token and user object.

This establishes the **API route contract and network reachability from the
GitHub runner**, **not** ownership, acceptance of any individual user's
credentials, the correct farm tenant, database migrations, or identical
responses for all the tablet's modules. Review the [read-only API probe](https://github.com/achamseddine/OrigamiFarmOS/actions/runs/43573038332).
Do not send live farm credentials until the Azure subscription owner confirms
this staging host is authorized for them.

| Purpose | Setting | Example | Where it belongs |
| --- | --- | --- | --- |
| Tablet -> FastAPI API | `FARMOS_API_BASE_URL` | `https://leb-container-test-staging.azurewebsites.net/api/v1` **only after ownership/health verification** | Android `--dart-define`, or the tablet's **Connecting to a different server?** login field |
| FastAPI -> PostgreSQL | `DATABASE_URL` | `postgresql://USER:PASSWORD@POSTGRES_HOST:5432/DBNAME?sslmode=require` | Azure App Service application settings / managed secret store |
| Alembic migration runner -> same PostgreSQL | `PROD_DATABASE_URL` | Same private PostgreSQL DSN as `DATABASE_URL`, with appropriate permissions | **GitHub Actions repository secret**, never in Git or Flutter APK |

**Never commit a real PostgreSQL username, password or DSN.** Do not change
`PROD_DATABASE_URL` to the website URL. The migration workflow now explicitly
rejects HTTP/HTTPS URLs with a clear error rather than attempting a connection.

## How to verify that the proposed Azure host belongs to Origami

1. In Azure Portal, identify the authorized **Origami FarmOS** backend App Service
   and confirm its **Default domain** matches the proposed hostname and that
   the staging site is intended to receive test farm accounts.
2. Check **`https://leb-container-test-staging.azurewebsites.net/health`** and
   **`/openapi.json`**. The Azure deployment has a legitimate Next.js
   website at `/` and a separate API documented as **Origami Server API**;
   a non-JSON home page does not mean the `/api/v1` endpoints are absent.
   Inspect the full login response and permission/module endpoints. The
   tablet's **Check API (no password sent)** diagnostic checks health and
   the OpenAPI route contract; an HTTP 200 alone is not enough.
3. Check Azure App Service application settings, deployment logs, database
   connectivity, and the specific Alembic revisions required by the installed
   APK. Confirm `FARMOS_SECRET_KEY` and production/demo settings are appropriate.
4. Only after verification, set the tablet login's server field to
   **`https://leb-container-test-staging.azurewebsites.net/api/v1`**.
   Do not send real farm credentials to an unverified staging host.
5. Preserve all device-local records and pending outbox writes when switching
   servers or APK versions. Do not uninstall or clear app data as a first step.

## Building an APK with an approved server preselected

The app now accepts an optional, **non-secret**, build-time default:

```bash
cd mobile/flutter_app
flutter build apk --release \
  --dart-define=FARMOS_API_BASE_URL=https://YOUR-VERIFIED-FARMOS-HOST/api/v1
```

For the 2026-11-14 recovery builds, Azure staging is the compiled-in
default `FARMOS_API_BASE_URL`; Android still allows a verified host override
with `--dart-define` or manual entry on the login screen. The tablet does
**not** reuse the previous session or previously entered host automatically,
to keep the credential form visible on every launch. Locally cached farm
records and offline outbox entries are deliberately not deleted.

A build or public API probe does **not** deploy the backend, confirm tenant
credentials, apply a database migration or configure a PostgreSQL secret.
Those actions require Azure administrative access and an actual database DSN.

## If `PROD_DATABASE_URL` is still missing

Open the repository's **Settings -> Secrets and variables -> Actions** and add a
repository secret named `PROD_DATABASE_URL` containing the actual PostgreSQL
DSN obtained from the authorized database administrator or Azure PostgreSQL
resource. Confirm secure network/firewall access before manually triggering
the workflow **Migrate & seed the production database**. Prefer
`migrate_only` for an existing populated database; do not automatically
seed users or reset data without checking the existing database.

Related sources:
- [App config](../mobile/flutter_app/lib/auth/session_controller.dart)
- [Migration workflow](../.github/workflows/migrate-seed-db.yml)
- [Backend database config](../backend/app/core/config.py)
- [Android install and login guidance](../mobile/flutter_app/README.md)
