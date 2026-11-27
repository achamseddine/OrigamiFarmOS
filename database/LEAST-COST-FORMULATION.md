# Least-cost formulation drafts (master prompt Package 12)

Status: implemented in v0.8.19. Code: `backend/app/services/least_cost_service.py`, `backend/app/feeding/lp.py`
(ADR-010), `backend/app/domain/formulation_models.py`; API under `/nutrition/least-cost`; app: Feed → Nutrition.

## Inputs
- one **active** requirement set version (Package 11) — its species is the feed's species;
- the **ingredients allowed** (default: the base formula's), each with optional min/max % of the batch; the feed usage
  policy blocks an ingredient not allowed for the species and caps its inclusion;
- the **batch size** (default: the base formula version's, e.g. 1,210 kg) and an optional **premix on top**, fixed;
- the **ration**: concentrate kg per head, forage(s) or *this feed only*, the animals' weight;
- **today's prices**: for each ingredient the lot that would be used next (FIFO; its supplier and cost), else the
  feed's price. A missing price is *insufficient data*, never zero.

## Output (`formulation_runs`, stored as computed)
- `drafts`: up to three — A *least cost*, B *with margin*, C *least change* — each with kg and % per ingredient,
  cost and cost per kg, the ration's dry-matter intake and each requirement's value and status (all *met*), and the
  saving against the base formula at today's prices; C also says how many kg it changes;
- `infeasible`: each requirement bound that cannot be reached, or that they cannot all be met together;
- `missing`: what is not known (no draft at all);
- `prices` with their source, `priced_at`.

## Approval
`POST /nutrition/least-cost/{id}/approve` (Feed approve) with the draft and a reason (required): once per run (the
run's row is locked), the draft becomes a new **draft** version of the base formula (or the formula named), through
`feed_batch_service.add_version(activate=False)` — its components and policy checks as any version. The active
version is untouched; activating the new one is the usual formula approval. Event `least_cost_draft_approved`, audit
entry.

## Never
- a stock movement, a feeding, a changed formula, batch or price;
- an optimisation on a guessed analysis or price;
- a draft for another species' requirements, or with a blocked ingredient or premix.
