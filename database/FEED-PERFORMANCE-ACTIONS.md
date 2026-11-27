# Feed performance → manager action → measured outcome (master prompt Package 13)

Status: implemented in v0.8.20. Code: `backend/app/services/feed_action_service.py`, `backend/app/domain/feed_action_models.py`;
API under `/feed-performance/actions` and `/feed-performance/alerts/{id}/actions`; app: Feed → Performance, on each alert.
Builds on the Feed Performance Intelligence (database/FEED-PERFORMANCE-INTELLIGENCE.md) and never duplicates its facts.

## What already holds (and is relied on)
- An alert is raised only with enough evidence: an evaluation with too few recorded days is *insufficient*, not an alert.
- Confidence is lowered for every confounder and for the context the farm does not record.
- One alert per condition (deduplication key), one bell signal per open alert; acknowledging takes it off the bell.

## The loop added
1. **Action** (`feed_performance_actions`, Feed approve): on an open or acknowledged alert that has an assessment and a
   subject (one animal or one group), the manager says what was done (change the lot or the supplier, sample the lot,
   revise the formula, adjust the feeding, a health check, other), what the production should do (go up, go down, stay),
   and how many days to wait (3–60; the same number of days before is the baseline). The alert is acknowledged by it.
   One action at a time per alert (the alert's row is locked; a second is refused until the first is measured or
   cancelled). An action is a decision, never a transaction: the lot, formula or feeding is changed in its own workflow
   and only linked (`linked_entity_type/id`).
2. **Outcome**, measured **once** when the window has passed, by the daily cycle (`run_cycle` → `measure_due`) or on
   request: the canonical daily values (`daily_values`: milk per milked head per day, eggs, growth) — the mean of the
   baseline days before the decision against the mean of the days after. Fewer than 5 recorded days on either side is
   **insufficient data**, never "no change".
   - **as expected** / **no clear change** (under 3 % of the baseline) / **opposite**.
   - **Confidence** 0.80, less 0.15 for health events in the window, 0.10 for an open health case, a withdrawal, a
     dry-off, moved animals, management changes or a change in the milked herd, 0.15 for a calving, 0.05 for another feed
     change, and 0.02 per unrecorded context (at most 0.10); never below 0.10. Every reduction is stored and shown.
   - The explanation always says it is an association with the action, not proof that it caused it.
3. **Notification:** one bell signal per measured outcome (source `feed_action_outcome`), until a manager marks it
   reviewed — never twice.
4. **Cancel** with a reason while measuring; the next action may then be recorded.

## Linked to its source
Each action keeps its alert, the assessment and monitor that raised it, the subject and the metric; its evidence keeps
both windows' daily values and the confounders as the Feed Performance Intelligence saw them.
