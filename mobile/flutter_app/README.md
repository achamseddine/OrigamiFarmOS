# Origami FarmOS — Tablet App (Flutter)

Offline-first, tablet-first farm operating system for Origami Farms
(Bekaa Valley, Lebanon). See the repo root `CONSTITUTION.md` and
`product/MVP_SCOPE.md` for the product principles this app follows, and
`product/TRACEABILITY.md` for a requirement-by-requirement map into this
codebase.

## Run it

This build was authored without access to the Flutter SDK (no
`flutter`/`dart` binary in the build environment), so none of the
commands below have been executed here — see "Verification status"
below for exactly what was and wasn't checked.

```bash
cd mobile/flutter_app
flutter pub get
flutter run -d <android-tablet-or-emulator-id>   # landscape tablet, 1024–1366px target
```

Widget/unit tests:

```bash
flutter test
```

Static analysis:

```bash
flutter analyze
```

## What you'll see

1. **Welcome** — practical greeting, Start My Day / View Demo Farm, a
   morning-briefing preview panel, and an original vector Bekaa Valley
   illustration (see "On imagery" below — never a screenshot).
2. Tapping **Start My Day** seeds the local SQLite database (idempotent —
   safe to call on every launch) and opens the tablet shell: a left nav
   rail (Morning Briefing, Animals, Feed & Inventory, Milk, Eggs, Health
   Intelligence, Produce & Harvest, Sales & Finance, Tasks, Settings) and
   a top bar with sync status, EN/AR toggle, notifications, and the
   manager avatar.
3. From **Animal Status**, tapping any animal card opens its **Digital
   Twin** — profile, quick actions (Observe / Treat / Feed / Milk / Move /
   View History), life-history timeline, milk & feed trend charts, health
   history, breeding, financial snapshot, and an AI recommendation panel
   with evidence and a confidence score.
4. The **Observe**, **Milk**, **Treat**, **Feed**, and **Move** quick
   actions are real: they write to a local SQLite database, log an
   immutable event, and queue a sync-queue row — the same "save locally →
   event → sync queue → update UI" flow the tech spec specifies for
   offline-first writes. Toggle "Simulate offline" from the sync pill (top
   bar) to see the sync status change while those writes keep working.

## Architecture

```
lib/
  main.dart                       Entry point
  app/app.dart                    Provider wiring, MaterialApp, locale/RTL, root router
  core/
    theme/                        Brand tokens (colors, typography, spacing/radii/shadows)
    i18n/                         EN/AR string table + LocaleController
    widgets/                      Shared components: AppShell, NavRail, TopBar, KpiCard,
                                   AlertCard, SectionCard, StatusPill, FarmDataTable,
                                   PhotoSlot, BekaaBackdrop, charts/ (LineTrendChart, BarTrendChart)
  domain/entities/                Plain Dart models mirroring the backend's domain model
  data/
    demo/demo_data.dart           Rich Option C demo dataset (all 10 screens' data)
    local/                        SQLite schema (database.dart), FarmWriteService (validated
                                   writes + event log + sync queue), DemoSeed (seed loader)
  providers/                      ChangeNotifier controllers: AnimalsProvider, FeedProvider,
                                   TasksProvider — call FarmWriteService + SyncQueueController
  sync/sync_queue_controller.dart Sync status simulation (see "What's mocked" below)
  features/                       One folder per screen (welcome, morning, animals, feed,
                                   production, health, produce, finance, tasks, settings)
```

## What's complete

- All 10 Option C screens implemented as real, data-driven Flutter widgets
  (no screenshots as backgrounds — tech spec §19/§24 explicitly forbids
  that) plus the Animal Digital Twin detail screen, matching the mockups
  in `Branding kit/screens/high-res/` closely.
- Full brand theme (`core/theme/`) sourced from `design-system/tokens.json`.
- EN/AR toggle with RTL support wired through `flutter_localizations`;
  ~150 UI strings translated (nav, KPI labels, screen headers, common
  actions) — see `core/i18n/strings.dart`. Deep mock-data content (animal
  names, evidence sentences) stays English-only, matching the tech spec's
  "partial Arabic translation is acceptable at first" allowance.
- Local SQLite schema (`data/local/database.dart`) mirroring the backend's
  tables, with a validated write pipeline (`FarmWriteService`) enforcing
  the same rules as the backend (milk liters ≥ 0, withdrawal blocks sale,
  feed can't go negative without override) and writing an event +
  sync-queue row for every change.
- Observe / Milk / Treat / Feed / Move quick actions on the Animal Digital
  Twin are wired end-to-end to that write pipeline, not just visual mocks.
- Charts (`core/widgets/charts/`) are custom-painted from real data
  arrays, never static images.

## What's mocked / simplified

- **Most dashboards read from `data/demo/demo_data.dart`, not the SQLite
  repository layer.** Per tech spec milestone ordering (M3 "screens with
  mock data" → M4 "screens read from local data"), this build completes
  M3 fully and M4 for the highest-value vertical slice (animals, tasks,
  feed inventory quick actions — see above). Wiring every remaining
  dashboard (Milk/Egg/Produce/Health/Sales trend panels) to read
  historical records from SQLite instead of the static demo dataset is
  the next milestone; the repository/provider pattern already in place
  (`AnimalsProvider`, `FeedProvider`, `TasksProvider`) is the template to
  extend.
- **Sync is simulated, not networked.** `sync/sync_queue_controller.dart`
  models queue depth, status transitions, and a debug offline toggle so
  the offline-first UX is demonstrable end-to-end, but it does not call
  the FastAPI backend's `/sync/push` / `/sync/pull` endpoints yet. The
  local write pipeline (SQLite + event log + sync-queue table) is real
  and ready for a networked sync worker to be added on top.
- **No login screen / role switching in the UI.** The app assumes a
  single manager session (matching the "first user is the farm manager"
  framing); backend RBAC (owner/manager/worker/veterinarian/accountant) is
  fully implemented and tested but not yet surfaced as a mobile login flow.
- **No bundled Fraunces/Inter/Noto Sans Arabic font files.** Typography
  uses the platform serif/UI-font fallback tier the brand guideline
  specifies for exactly this case — see `core/theme/typography.dart` for
  how to upgrade once licensed font files are added.
- **`PhotoSlot` never shows a real photo** — it's a replaceable slot with
  a calm brand-toned placeholder (tech spec §19 explicitly asks for this
  rather than hardcoded/generated images) and isn't yet wired to the
  tablet camera.

## On imagery

The Bekaa Valley visuals (Welcome screen, nav-rail footer card) are an
original vector illustration painted by `core/widgets/bekaa_backdrop.dart`
(`CustomPainter` — ridge line, terraces, a cedar silhouette), not a photo
and not a crop of the provided Option C mockup PNGs. The tech spec is
explicit that those flattened mockups are reference-only and must never
ship as in-app backgrounds (§19, §24 anti-patterns table).

## Verification status

- **Not run**: `flutter pub get` / `flutter analyze` / `flutter test` /
  `flutter run` — no Flutter SDK was available in the environment this was
  built in. Every file was written and cross-checked by hand (import
  resolution, const-context correctness, `num`-vs-`double` clamp() return
  types, enum-switch exhaustiveness, generic type inference on
  `Database.transaction<T>()`), but this is not a substitute for a real
  build. Run `flutter pub get && flutter analyze` first after cloning.
- **`sqflite`/`shared_preferences` calls fail gracefully with no platform
  channel** (e.g. certain CI/desktop test targets): `_RootRouter._start()`
  and `LocaleController._restore()` both catch and fall back rather than
  crash, so the app should still render even where local persistence
  isn't available (see `app/app.dart`).
