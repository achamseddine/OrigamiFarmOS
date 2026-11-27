# ADR-010 — Least-cost formulation with a small in-house simplex

**Status:** Accepted (v0.8.19, master prompt Package 12; migration `c9e1a3b5d7f0`)
**Builds on:** database/NUTRITION-ASSESSMENT.md (Package 11), database/LEAST-COST-FORMULATION.md

## Context
Package 12 asks for least-cost drafts of a concentrate: minimise its cost at today's prices subject to the
ration meeting a requirement set on dry matter, within each ingredient's limits and the feed usage policy. That
is a linear programme. The backend has no numerical library, and CLAUDE.md asks for an ADR before a foundational
dependency is introduced.

## Decision
- A **dense two-phase simplex with Bland's rule** in `backend/app/feeding/lp.py` (about 150 lines, no dependency).
  A farm's problem has a dozen ingredients and a dozen bounds; the solver is tested on known optima, infeasible
  and unbounded problems, redundant equalities and Beale's cycling example (`tests/test_lp_solver.py`).
- The formulation is linear because every requirement is multiplied out by the ration's dry-matter intake:
  `Σ k·DMᵢ·(vᵢ − min)·xᵢ ≥ min·DM_fixed − N_fixed` (and the same for a maximum), with the batch `Σ xᵢ = B`.
- Up to **three drafts**: **A** the cheapest; **B** the cheapest with a safety margin (default 3 %) inside every
  bound; **C** the closest to the current formula (least total kg changed, an L1 objective with auxiliary rows).
- Every bound is solved **0.1 % inside**, so a draft rounded to 0.1 kg still meets the bound it is reported against;
  infeasibility is reported against the real bounds.
- **No optimisation on unknowns:** a missing analysis, dry matter, required nutrient, price, intake, forage or
  weight stops the run as *insufficient data* (the Package 11 rules).
- **Infeasible** runs name each bound that cannot be reached even alone, else say the bounds conflict together.

## Consequences
- No new dependency; the solver's behaviour is ours to test and explain.
- Floats with tolerances (1e-9 pivots, 1e-7 feasibility) are adequate at this size; a much larger problem
  (hundreds of ingredients) would justify revisiting this with a library under a new ADR.
- A run stores its prices (with the lot or the price they came from) and its drafts as computed. A later price
  never rewrites it, nor any batch, whose costs come from the ledger.
- A draft is a plan: approving one (manager, with a reason, once per run) adds a **draft** formula version through
  the formula service — species and policy checks included — to be activated by the existing formula approval.
