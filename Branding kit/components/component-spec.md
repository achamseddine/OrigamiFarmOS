# Origami FarmOS Option C Component Specification

This package converts the Option C manager-demo screens into reusable implementation assets.

## Core Layout Components

### AppShell
Tablet-first application shell with a left navigation rail, top status controls, and scrollable content canvas.

- Width target: 1024–1366 px landscape tablet.
- Sidebar: 200–240 px.
- Content padding: 32–40 px.
- Background: warm off-white with subtle agricultural imagery only where operationally useful.

### TopBar
Contains sync status, language toggle, notifications, and manager profile.

States:
- Synced
- Offline
- Sync pending
- Error

### SidebarNav
Used for manager navigation across Morning Briefing, Animals, Feed, Production, Health, Produce, Sales, Reports, and Settings.

### KPI Card
A compact metric card with icon, label, value, and trend.

Required properties:
- icon
- label
- value
- unit
- trend
- status color

### Alert / Recommendation Card
Used for animal alerts, feed warnings, health intelligence, harvest reminders, and financial insights.

Required properties:
- priority
- entity
- evidence
- recommended action
- confidence, when AI-generated

### Animal Card
Used in Animal Status Overview.

Required properties:
- animalId
- name
- species
- group
- healthScore
- location
- production summary
- status badge

### Digital Twin Timeline
Central component for animal history.

Events include:
- Milk recorded
- Treatment completed
- Weight recorded
- Pregnancy confirmed
- Feed change
- Observation recorded

### Data Table
Used for feed inventory, sales breakdown, expenses, and reports.

### Chart Card
Used for production trends, feed consumption, milk trend, egg trend, and profit trend.

## Interaction Rules

- Use large touch targets: minimum 48 px height.
- Avoid dense text entry during morning workflow.
- Every alert must explain evidence.
- Worker-facing pages should avoid diagnosis language.
- Manager pages can show recommendations, confidence, and suggested actions.
- Arabic RTL must mirror layout where appropriate.
