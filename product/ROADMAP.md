# Implementation Roadmap

## Phase 0: Engineering Repository Setup
Outputs: GitHub repository, Constitution, Concept note, Engineering handbook structure, ADR folder, MVP scope, Roadmap, Initial glossary

## Phase 1: Core Farm Setup
Outputs: Farm profile, Users and roles, Locations, Basic offline database, Language structure, Initial sync architecture

## Phase 2: Animal and Flock Foundation
Outputs: Animal registry, Flock registry, QR code support, Animal profile, Timeline, Basic health status

## Phase 3: Morning Routine MVP
Outputs: Morning briefing, Feeding workflow, Milk workflow, Egg workflow, Observation workflow, Task completion

## Phase 4: Health and Veterinary
Outputs: Medical records, Treatments, Vaccinations, Withdrawal periods, Health recommendations, Follow-up reminders

## Phase 5: Inventory, Produce, Sales, Expenses
Outputs: Feed stock, Medicine stock, Product inventory, Fresh produce harvest, Simple sales, Simple expenses, Basic profitability

## Phase 6: Intelligence and Reports
Outputs: Rule-based alerts, Health recommendations, Feed shortage forecast, Production trends, Daily/weekly/monthly reports, Recommendation feedback loop

## Phase 7: Origami Farms Pilot
Outputs: Daily use on farm, Worker feedback, Bug fixing, Workflow refinement, Feature removal where unused, MVP stabilization

## Phase 8: Commercial Readiness
Outputs: Multi-farm support, Onboarding flow, Farm templates, Subscription model, Customer support model, Commercial documentation

## Feed Performance Intelligence roadmap
1. Preserve supplier/lot and actual mixing lineage in all feed transactions. — **done** (numbered mixes, `GET /feed-mixes/{n}`).
2. Establish milk/production baseline monitoring and persistent anomaly detection. — **done, deterministic** (monitors, explicit baselines, deduplicated self-resolving alerts).
3. Add formula-compliance and batch performance scoring. — **done** (mix score cards; compliance deviation is its own alert).
4. Add ingredient-lot and supplier-specific performance comparisons with confidence thresholds. — **done, first increment** (supplier × ingredient rows with confidence; cross-lot anomaly attribution pending).
5. Add feed cost/output and effective supplier-value analytics. — **partly** (feed cost per litre week over week; supplier value analytics pending).
6. Add versioned AI/statistical models with explicit confounders, explanations and review workflows. — **pending**; the deterministic model already carries the evidence / confounder / confidence / review-task contract they must keep.

