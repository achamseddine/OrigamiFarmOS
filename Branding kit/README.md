# Origami FarmOS Option C UI Kit

This ZIP contains the reusable components and source references for the **Option C manager tablet demo**.

## Included

- `screens/high-res/` — the 10 high-resolution tablet mockup screens.
- `screens/Origami_FarmOS_Manager_Demo_Tablet_Screens_10pages.pdf` — the compiled 10-page demo PDF.
- `branding/logo/` — Origami FarmOS SVG and PNG logo assets.
- `branding/colors/` — color palette, design tokens, CSS variables, and palette swatches.
- `icons/svg/` — reusable line SVG icon set matching the UI language.
- `icons/png/` — PNG icon exports for quick use.
- `styles/` — CSS theme, component library, and design tokens.
- `components/` — implementation notes and component specs.
- `data/` — mock data for the demo screens and sample English/Arabic strings.
- `layouts/` — screen map, tablet grid specification, and Option C demo flow.
- `prompts/` — generation prompts and screen descriptions.
- `styleguide/` — simple HTML preview page for colors, icons, and components.

## Important note about generated images

The tablet mockups are AI-generated flattened raster images. The cow photos, field photos, charts, and background scenery inside those images are not separate editable layers. To support product development, this kit provides reusable SVG icons, CSS tokens, component specs, layout rules, and mock data that developers/designers can use to recreate the screens in Figma, Flutter, React, or a web prototype.

## Recommended next step

Import this kit into the GitHub repository under:

```text
/design-system/origami-farmos-option-c-ui-kit/
```

Then point Codex to:

```text
styles/farmos-theme.css
components/component-spec.md
data/option-c-demo-data.json
layouts/option-c-flow.md
```

## Screen list

1. Welcome / Start My Day — `screens/high-res/01-welcome-start-my-day.png`
2. Morning Briefing Dashboard — `screens/high-res/02-morning-briefing-dashboard.png`
3. Animal Status Overview — `screens/high-res/03-animal-status-overview.png`
4. Animal Digital Twin — `screens/high-res/04-animal-digital-twin-bella-744.png`
5. Feed & Inventory — `screens/high-res/05-feed-inventory.png`
6. Milk Production — `screens/high-res/06-milk-production.png`
7. Egg Production — `screens/high-res/07-egg-production.png`
8. Health Intelligence — `screens/high-res/08-health-intelligence.png`
9. Produce & Harvest — `screens/high-res/09-produce-harvest.png`
10. Sales, Expenses & Daily Summary — `screens/high-res/10-sales-finance-daily-summary.png`
