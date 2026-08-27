# Origami FarmOS — Tablet App (Flutter)

Tablet-first farm operating system for Origami Farms (Bekaa Valley,
Lebanon). See the repo root `CONSTITUTION.md` and `product/MVP_SCOPE.md`
for the product principles this app follows, and
`product/TRACEABILITY.md` for a requirement-by-requirement map into this
codebase.

This is an operational app, not a demo. There is no demo mode and no
sample dataset: every screen reads and writes the real FastAPI backend,
and what a given person sees is decided by the module responsibilities
their farm manager gave them.

**Online the first time, then usable in the field.** Signing in needs the
farm network; after that the tablet keeps working with no signal, and
everything recorded out there is sent automatically when it comes back
into range — see "Working offline" below.

## Run it

```bash
cd mobile/flutter_app
flutter pub get
flutter run -d <android-tablet-or-emulator-id>   # landscape tablet, 1024–1366px target
flutter test
flutter analyze
```

The app needs a reachable backend. It defaults to `http://10.0.2.2:8000/api/v1`
(the Android emulator's route to the host machine); on real hardware, tap
**"Connecting to a different server?"** on the login screen and enter the
deployment's URL, which is then remembered.

## Signing in

The landing page is a single login. **Start My Day** authenticates against
`POST /auth/login` and opens the signed-in user's own dashboard; the
bearer token is stored in `shared_preferences` and silently re-validated
against `/auth/me` on the next launch, so a farm worker sees the login
screen once per install.

Accounts are created by a farm manager under **Employees &
Responsibilities**, or seeded for a new deployment by
`backend/app/seed_production.py`.

## What each person sees

Navigation, screens and action buttons are all built from the signed-in
user's module permissions (`GET /me/access`), so the app is a different
app for each role:

| Signed in as | Sees |
| --- | --- |
| Farm owner / manager | Every module, every action, plus Employees & Responsibilities and Audit History |
| Animal care employee | Morning Briefing, Animals, Feed & Inventory, Milk, Eggs, Health, Tasks, Settings |
| Agriculture employee | Morning Briefing, Produce & Harvest, Tasks, Settings |
| Mouneh employee | Morning Briefing, Mouneh & Products, Tasks, Settings |
| Visits coordinator | Morning Briefing, Farm Visits, Sales, Tasks, Settings |

Those are only the shapes the seeded accounts happen to start with. The
model underneath is many-to-many: a manager can give one employee Animals
+ Agriculture + Feed, or Mouneh + Sales, and set a different depth
(view / create / edit / delete / approve / export / assign / configure)
for each module independently. There is no fixed "Cow Worker" role.

## Architecture

```
lib/
  main.dart                       Entry point
  app/
    app.dart                      Provider wiring, MaterialApp, locale/RTL, session gate
    app_navigator.dart            Which shell tab is showing — so a notification or a
                                   priority card can drive navigation, not just the rail
    nav_config.dart               Builds (nav entries, screens, module→tab map) from
                                   the signed-in user's permissions
  api/api_client.dart             JSON/HTTP client + WriteResult (success/error) shape
  auth/session_controller.dart    One-time login, token persistence, silent re-validation
  core/
    theme/                        Brand tokens (colors, typography, spacing/radii/shadows)
    i18n/                         EN/AR string table (462 keys, both complete) + LocaleController
    widgets/                      AppShell, NavRail, TopBar, KpiCard, AlertCard, SectionCard,
                                   StatusPill, FarmDataTable, PhotoSlot, BekaaBackdrop,
                                   charts/ (LineTrendChart, BarTrendChart)
  domain/entities/                Plain Dart models mirroring the backend's schemas —
                                   access.dart (permissions), employee.dart, notification.dart,
                                   crop.dart, animal.dart, visits.dart, mouneh.dart, …
  mouneh/costing.dart             Pure Dart port of the backend's cost/pricing/margin engine
  visits/analytics.dart           Pure Dart port of the backend's capacity/profitability engine
  providers/                      One ChangeNotifier per area, each calling ApiClient directly:
                                   AccessProvider, NotificationsProvider, EmployeesProvider,
                                   AgricultureProvider, AnimalsProvider, FeedProvider,
                                   ProductionProvider, TasksProvider, RecommendationsProvider,
                                   SalesProvider, MounehProvider, VisitsProvider
  features/                       One folder per screen area (auth, morning, animals, feed,
                                   production, health, produce, finance, tasks, settings,
                                   employees, notifications, priorities, profile, navigation)
                                   plus features/mouneh/ (7 screens) and features/visits/
                                   (10 screens) behind one nav entry each
```

### Permissions

`AccessProvider` loads `GET /me/access` and `GET /modules/catalog` once at
sign-in, and every screen reads it synchronously:

```dart
if (context.watch<AccessProvider>().canCreate(FarmModule.animals))
  FilledButton.icon(onPressed: () => showAnimalForm(context), …)
```

Hiding a button is a courtesy, never the guard: the backend re-checks the
same permission on every request (`require_permission` in
`backend/app/api/deps.py`), so an employee who reaches an endpoint another
way still gets a 403 with a message naming what to ask their manager for.

Owners and managers hold every module implicitly and need no permission
rows at all — a farm can never be locked out of its own data, and a
manager can always do any job personally when nobody is assigned to it.

### Notifications and priorities

The backend derives both from live farm state (`services/signals_service.py`)
rather than storing hand-written alerts: an open recommendation, stock
below its reorder level, an animal under withdrawal, an overdue task, a
Mouneh batch left open, tomorrow's bookings, unpaid sales. Every signal
carries an `entity_type`/`entity_id`, which is what makes the cards work
as links — `features/navigation/entity_router.dart` turns that pair into
either a pushed detail route (an animal opens its Digital Twin) or a tab
switch (a low-stock alert opens Feed & Inventory). A signal that stops
being true stops being shown; read/unread state persists.

**Today's Priorities** merges those alerts with the farm's open tasks and
scopes the result to the modules the viewer holds, so an Animals employee
is never shown the farm's finance alerts. **Expand** opens the full list
filtered by urgency, module, type (alert/task) and assignment
(mine / the team's / unassigned).

### Modules

Mouneh and Farm Visits are licensed per farm (`module_licenses`), so they
are hidden unless the farm has bought them *and* the user holds them.
Both are structured the same way: one nav entry opening an internal tab
row — Mouneh's 7 screens (tech spec v0.5 §6) and Visits' 10 (v0.6 §6).
Nothing in either hard-codes a product type, an activity or an opening
day.

## Data entry

Every module's responsible employee can actually run their area, not just
read it:

- **Animals** — Add Animal (the full §13 record: identity, provenance,
  location, physical, health, production, and financial fields for anyone
  who also holds Finance), full edit, plus the existing Observe / Treat /
  Feed / Milk / Move quick actions on the Digital Twin.
- **Agriculture** — Add Field, Add Crop Type (crops are farm data; the
  platform ships no crop list), Record Planting, and **Record Harvest**,
  which splits the day's pick into sellable and waste and moves the
  sellable part into real produce inventory.
- **Tasks** — a manager creates, assigns, reassigns and deletes; an
  employee sees and completes their own.
- **Employees** — create staff accounts, edit them, and set their module
  responsibilities in a permission matrix.

## Working offline

Farm workers collect data in fields with no coverage and reach the office
hours later, so the tablet is built to keep working the whole time and
reconcile on its own afterwards.

**Signing in needs the network.** There is no way to verify a password or
issue a token offline, so the login screen is the app's one online
requirement. It is also the only one: after a successful sign-in the
token, the user profile and the permission set are all cached, and later
launches restore the session from that cache.

**Reads** come from the server when it is reachable and every response is
cached as it arrives (`data/local/local_store.dart`, keyed by the request
itself, so a new endpoint is cached the day it is added). When the server
can't be reached, the cached answer is served.

**Writes** go straight through when the server is reachable. When it
isn't, the HTTP request itself is queued in an outbox and the cached
lists are updated locally, so the record the worker just entered appears
immediately with a **Not synced** chip against it. Storing the request
rather than a translated "event" is what makes this general: every
endpoint the app calls works offline without a matching branch on the
server.

**Reconnecting syncs by itself.** Reachability is judged from actual
request outcomes plus a backing-off health ping — never from the WiFi
radio, which happily reports "connected" on an access point with no route
to the farm server. On the offline → online edge the queue is replayed in
the order it was recorded, and every provider then reloads so the farmer
sees server truth rather than the local prediction.

Two details that stop the obvious ways this goes wrong:

- **A replayed write can't record the work twice.** Each queued request
  carries an `Idempotency-Key`, reused from the attempt that failed. If
  the original actually committed and only its response was lost, the
  server returns that original response instead of writing again
  (`backend/app/core/idempotency.py`).
- **Records created offline get real IDs on the way up.** A field created
  in a dead spot gets a temporary ID; a crop planted in it ten minutes
  later refers to that ID. As the queue drains, the server's real IDs are
  substituted into everything still waiting.

The **sync pill** in the top bar is never hidden while anything is
waiting, and an offline strip sits under it while the tablet is out of
contact. Tapping either opens the sync panel: what is queued, when the
last sync was, a manual **Sync now**, and anything the server rejected —
shown with the server's own words and kept until a person retries or
deliberately discards it. Signing out with unsent records asks first.

The queue is scoped to the user who recorded it, so a tablet shared
between shifts never replays one worker's entries under another's token.

On a device without working SQLite (the `flutter test` VM, a desktop
debug run) the store reports itself unavailable and the app behaves
exactly as an online-only client.

## Audit trail

Every employee, permission, animal, field, crop, planting and harvest
change writes an `audit_log` row recording who did it, when, and the
actual before/after values. **Audit History** (Employees screen, or any
record's own history) renders those as `old → new` diffs and links back to
the record that changed.

## What's simplified

- **A screen never visited online has nothing to show offline.** The
  cache is filled by use: whatever the tablet loaded while connected is
  what it can serve in a field. Opening a module for the very first time
  out of range shows an explanatory empty state, not data.
- **No bundled Fraunces/Inter/Noto Sans Arabic font files.** Typography
  uses the platform serif/UI-font fallback tier the brand guideline
  specifies for exactly this case — see `core/theme/typography.dart`.
- **`PhotoSlot` never shows a real photo** — it's a replaceable slot with
  a calm brand-toned placeholder (tech spec §19 asks for this rather than
  hardcoded/generated images) and isn't yet wired to the tablet camera.
  Animal and employee records carry a `photo_path` the API accepts, but
  there is no upload flow yet.
- **Breeding events have no backend model**, so the Digital Twin has no
  breeding panel. Weight is recorded through Edit Animal, and a
  vaccination through the existing Treat action.

## On imagery

The Bekaa Valley visuals (login screen, nav-rail footer card) are an
original vector illustration painted by `core/widgets/bekaa_backdrop.dart`
(`CustomPainter` — ridge line, terraces, a cedar silhouette), not a photo
and not a crop of the provided Option C mockup PNGs. The tech spec is
explicit that those flattened mockups are reference-only and must never
ship as in-app backgrounds (§19, §24 anti-patterns table).

## Verification status

No Flutter SDK is available in the environment this was authored in, so
`flutter analyze` / `flutter build` are run by
`.github/workflows/build-apk.yml` on GitHub-hosted runners instead, and
that build is the gate — it has repeatedly caught real compile errors a
careful hand review missed (a null-safety promotion-scope bug in
`cost_preview_tab.dart`, a missing import in `opening_calendar_tab.dart`,
a stale entity shape in `produce_harvest_screen.dart`). Each was fixed and
the following run produced an installable release APK, published to the
rolling `tablet-apk-latest` GitHub Release.

The backend's 227 tests do run here and all pass, including the
permission, employee, notification, priority, audit and agriculture
suites that back these screens.
