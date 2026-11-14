# Origami FarmOS — staging API versus PostgreSQL database

## Critical distinction

The user-supplied URL **`https://leb-container-test-staging.azurewebsites.net`** is an
**Azure App Service HTTPS address**, **not** a PostgreSQL database connection string.

**Status (2026-11-14): candidate address only.** The repository review and
HTTP checks did **not** verify that this host is running Origami FarmOS FastAPI,
or that it is reachable from the farm tablets. Do not silently direct worker
credentials or production records to it until it has been verified as
an authorized Origami instance.

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
2. Check **`https://leb-container-test-staging.azurewebsites.net/health`** in a browser.
   The response must be the Origami FastAPI health payload, not a generic website,
   login page, 404, or unrelated application. Also verify **`/openapi.json`**
   identifies the Origami API and includes **`/api/v1/auth/login`**.
   An HTTP 200 alone is **not sufficient** proof of identity.
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

The existing emulator URL remains the fallback for development. A server URL
saved on the login screen is intentionally preserved and takes precedence over
the build-time default, so upgrading an app does not silently redirect an
existing farm user to a different server.

**This commit does not set the Azure hostname as the compiled-in default,
deploy a backend, create/change a GitHub Actions secret, migrate a database,
or prove connectivity.** Those actions require a verified authorized backend
and a real private PostgreSQL connection string.

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
