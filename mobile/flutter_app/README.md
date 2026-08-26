# Origami FarmOS Flutter application

The tablet client is local-first. Runtime screens read the device SQLite
projection and show explicit empty states until authentication/bootstrap sync
has supplied farm records. No farm identity, credentials, operational history,
or sample records are embedded in the application bundle.

## Run

```bash
flutter pub get
flutter run
```

## Data flow

- `lib/data/local/database.dart` defines the SQLite projection.
- `lib/data/local/farm_read_service.dart` maps stored animals, inventory, and
  tasks into domain entities.
- `lib/data/local/farm_write_service.dart` persists changes with an immutable
  event and sync-queue entry.
- PostgreSQL is the server source of truth; the FastAPI backend owns its API.

The repository root `database/schema.sql` is production-safe and contains no
sample rows. Developers who explicitly want disposable sample records can use
`database/setup_with_sample_data.sql`; that SQL is not bundled or executed by
the Flutter application.

## Verification

```bash
flutter analyze
flutter test
```
