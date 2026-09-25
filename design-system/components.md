# Origami FarmOS — Design System Components

Source of truth for tokens is `tokens.json` in this folder (copied from the Option C brand kit).
Flutter implementations live in `mobile/flutter_app/lib/core/theme/` and
`mobile/flutter_app/lib/core/widgets/`. Reference screen mockups live in
`Branding kit/screens/high-res/`.

## Tokens → Flutter mapping

| Token file key | Flutter symbol |
|---|---|
| `colors.*` | `FarmColors` (`core/theme/colors.dart`) |
| `typography.scale_px` | `FarmTypography` (`core/theme/typography.dart`) |
| `radii_px` | `FarmRadii` (`core/theme/spacing.dart`) |
| `spacing_px` | `FarmSpacing` (`core/theme/spacing.dart`) |
| `shadow.*` | `FarmShadows` (`core/theme/spacing.dart`) |
| `status_colors.*` | `FarmColors.statusHealthy/Watch/Alert/Offline` |

Typography fallback: Fraunces is not bundled (no offline-safe license file shipped in this
kit), so `FarmTypography.display` uses the platform serif fallback (which resolves to
Georgia/Noto Serif) exactly as the brand guideline's fallback rule specifies. UI text uses
the platform default (Inter-equivalent system UI stack). Arabic text automatically falls back
to the platform's Noto Sans Arabic via Android/iOS font-fallback — no extra wiring needed as
long as no non-covering `fontFamily` is force-set on Arabic runs.

## Core layout components

- **AppShell** (`core/widgets/app_shell.dart`) — left nav rail (224px) + top bar + scrollable
  content canvas. Landscape tablet target 1024–1366px. Falls back to a drawer under 900px so
  the shell still works on a phone-sized debug window.
- **TopBar** (`core/widgets/top_bar.dart`) — sync pill (Synced / Syncing / Offline / Error),
  EN/AR toggle, notification bell with badge, manager avatar.
- **NavRail** (`core/widgets/nav_rail.dart`) — Morning Briefing, Animals, Feed & Inventory,
  Milk, Eggs, Health Intelligence, Produce & Harvest, Sales & Finance, Tasks, Settings.

## Cards

- **KpiCard** — icon, label, value, unit, trend, optional status tint.
- **AlertCard** — priority pill, icon, title, evidence lines, chevron; used for animal alerts,
  feed warnings, harvest reminders, health alerts.
- **SectionCard** — generic rounded card wrapper (title + trailing action + child) used to
  keep every panel's radius/shadow/padding consistent.
- **AnimalCard** — health-score badge, id/tag, species/group, location, production line,
  status pill. Used in Animal Status Overview.
- **ChartCard** — `SectionCard` + `TrendChart`/`BarTrendChart` (custom-painted, data driven,
  no static images per REQ in tech spec §19).
- **DataTableCard** — used for feed inventory, sales/expense breakdown tables.
- **PhotoSlot** — replaceable image slot (asset/file/network) with a graceful icon+gradient
  placeholder when no photo exists yet, per tech spec §19 ("avoid hardcoding generated
  images").
- **BekaaBackdrop** — an original, lightweight vector illustration (ridge line, terraces,
  cedar silhouette, sun) evoking the Bekaa Valley, painted with `CustomPainter` in brand
  tones. Used on Welcome and as the nav-rail footer card background. The flattened mockup
  PNGs are reference-only and are never shipped inside the app (tech spec §19, §24).

## Interaction rules

- Minimum touch target 48×48.
- Status is never color-only: every status pill carries an icon + label.
- Worker-facing capture flows never expose a "diagnosis" field; only manager/vet-gated flows
  (Treatment) do.
- Every `RecommendationCard` shows evidence, confidence and a suggested action before any
  "Create Task" action is enabled.
