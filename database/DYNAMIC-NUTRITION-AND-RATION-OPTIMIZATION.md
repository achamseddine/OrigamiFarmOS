# Dynamic Nutritional Requirements & Ration Optimization

**Status:** Canonical design requirement — not yet implemented
**Dependencies:** Animal/AnimalGroup digital twins, lifecycle/reproduction/health, milk/production, Feed formulas/nutrient profiles, inventory/lot genealogy, procurement/pricing, feeding events, Feed Performance Intelligence.
**Scope:** Species-configurable; first validated calculation profile is dairy cattle. Other species require separately validated nutritional models and constraints; never reuse cattle coefficients for horses, sheep or poultry.

## 1. Purpose
For each animal, compute estimated daily nutrient requirements from current animal state and production, then produce a feasible, safe, economically efficient proposed ration using available farm ingredients and/or existing numbered finished feed mixes. Re-evaluate when relevant facts change; an AI proposal never becomes a feeding order without authorized approval.

The following are separate, versioned objects:
1. **Animal requirement snapshot** (what the animal needs).
2. **Feed nutrient/quality snapshot** (what ingredients can supply).
3. **Ration optimization run** (candidate solution and feasibility).
4. **Ration proposal** (reviewable, costed recommendation).
5. **Approved feeding program/version** (authorized plan).
6. **Actual feeding event** (what was offered, refused, estimated consumed).
7. **Feed performance assessment** (observed response, with uncertainty).

## 2. Required animal inputs
- Animal ID, species, breed, sex, age, estimated/measured body weight and weight timestamp.
- Physiological state: lactating/dry, days in milk, parity, pregnancy stage, days to expected calving, growth stage.
- Milk volume by animal and time; rolling trend; milk fat/protein if measured; production measurement provenance.
- Body condition score, body weight trajectory and target condition where applicable.
- Health status: active clinical cases, appetite/intake abnormalities, veterinary feeding restrictions, medication/treatment context, metabolic risk flags.
- Feeding group membership and individual overrides.
- Activity, housing, temperature/heat stress, terrain or other species-specific conditions where available.
- Estimated dry-matter intake capacity, measured/estimated actual intake, refusals and feed sorting when available.
- Explicit missing-data flags, source timestamps and confidence; never silently invent missing measurements.

## 3. Feed inputs
- Canonical feed item/product and lot; supplier/receipt lot; numbered manufactured mix and immutable formula version.
- Nutrient analysis and basis (as-fed vs dry matter), sample date, method/source (LAB_MEASURED, DECLARED, CALCULATED), and uncertainty.
- Dry matter, energy, crude protein and appropriate metabolizable protein measures, NDF/physically effective fiber, starch, sugars, fat, calcium, phosphorus, magnesium, sodium, potassium, trace minerals and vitamins where relevant.
- Price and delivered cost per unit, inventory eligible available quantity, expiry/quarantine, purchase lead time and substitution permissions.
- Ingredient min/max inclusion, toxicity/antinutritional limits, forage minimums, physical form, processing/grind characteristics and species/life-stage restrictions.
- For a finished mix, its actual batch composition and source lots override formula targets when known; avoid double counting premix/mineral additions.

## 4. Nutrient requirements engine
Use an explicitly versioned, reviewed species/stage model, with NASEM Nutrient Requirements of Dairy Cattle (8th revised edition, 2021) as a dairy-cattle reference. Model implementation must document source equations, units, applicable population, assumptions and tests; do not insert unverified coefficients into this specification.

Calculate an individual requirement vector, including:
- maintenance + milk production + pregnancy + growth + body reserve changes + activity/environment where applicable;
- dry matter intake estimate and capacity;
- energy, protein and amino-acid system as supported;
- fiber/rumen-health constraints, starch/fat constraints and minerals/vitamins;
- upper bounds, ratios and risk-based restrictions as applicable.

Requirements are recomputed when relevant animal facts change, and carry model version, timestamp, input snapshot, evidence quality and warnings.

## 5. Least-cost / constrained ration optimization
Optimize a cost objective subject to hard nutritional, safety, physical intake, stock and management constraints. Cost is not allowed to override animal health. Include:
- minimum nutrient requirements and safe maxima;
- dry matter intake and as-fed conversion;
- species/age/physiological stage policy;
- ingredient availability and quality;
- minimum forage/physical fiber, processing and inclusion restrictions;
- allowed existing numbered mixes and the fact that an existing batch cannot have its formula changed;
- palatability/transition limits and feeding schedule;
- supplement/premix label dose constraints and no double counting;
- farmer constraints: available machinery, group feeding, labor, budget, inventory and desired production.

When no feasible ration exists, return an explicit **INFEASIBLE** result listing violated constraints and missing feed/nutrients. Do not fabricate a 'balanced' ration. Use deterministic optimization with auditable inputs and solver version; generative AI explains results but does not invent nutrient arithmetic.

## 6. Individual requirements versus group delivery
Requirements are computed per animal, even if operational feeding occurs by group. Group proposals aggregate individual needs and disclose compromises, high/low-risk outliers, separate supplements and group-splitting recommendations. Do not assert that a shared group ration meets each animal's requirements merely because the group mean meets them.

For the user's dairy farm, support twice-daily concentrate/finely chopped straw feeding at milking and a separate midday silage/long straw offering, without assuming actual midday quantities are known. Feeding schedules are configurable, not globally hardcoded.

## 7. Canonical schema extensions
```sql
nutrition_model (
 id uuid primary key,
 species_id uuid not null references species(id),
 code varchar(100) not null,
 version varchar(50) not null,
 reference text not null,
 applicability jsonb not null,
 model_configuration jsonb not null,
 approved_at timestamptz,
 approved_by uuid references user_account(id),
 status varchar(30) not null,
 unique(species_id,code,version)
);

animal_nutrient_requirement (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid not null references animal(id),
 nutrition_model_id uuid not null references nutrition_model(id),
 calculated_at timestamptz not null,
 effective_for_date date not null,
 animal_input_snapshot jsonb not null,
 requirement_values jsonb not null,
 missing_data jsonb not null,
 confidence_code varchar(30) not null,
 warnings jsonb not null
);

ration_optimization_run (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 run_at timestamptz not null,
 objective_code varchar(40) not null,
 solver_name varchar(100) not null,
 solver_version varchar(60) not null,
 input_snapshot jsonb not null,
 constraints_snapshot jsonb not null,
 result_status varchar(30) not null,
 objective_value numeric(20,8),
 infeasibility_explanation jsonb,
 check (num_nonnulls(animal_id,animal_group_id)=1)
);

ration_proposal (
 id uuid primary key,
 optimization_run_id uuid not null references ration_optimization_run(id),
 proposed_at timestamptz not null,
 proposed_daily_components jsonb not null,
 nutrient_supply jsonb not null,
 nutrient_gaps jsonb not null,
 cost_per_head_day numeric(20,6),
 transition_plan jsonb,
 warnings jsonb not null,
 explanation text not null,
 status varchar(30) not null,
 reviewed_by uuid references user_account(id),
 reviewed_at timestamptz,
 approved_feeding_program_version_id uuid references feeding_program_version(id)
);
```
Requirements/proposals are historical snapshots, not mutable current state. Actual feed use remains in feeding events and inventory transactions. Implement normalized nutrient-line child tables or validated structured JSON as needed, but enforce units and per-nutrient semantics.

## 8. Recalculation triggers
- New milk record or meaningful rolling yield change.
- New weight/BCS, growth, parity, calving, pregnancy, drying-off or days-in-milk progression.
- New health case, appetite/refusal issue, treatment or veterinarian restriction.
- Ingredient lot/nutrient analysis, price, stock eligibility or feed-mix batch change.
- Approved feeding program change.
- Daily scheduled reevaluation plus event-driven invalidation.

Use persistence/debounce and configurable materiality thresholds to prevent excessive notifications. A new recommendation is not an actual feeding event and does not deduct inventory.

## 9. Integration with Feed Performance Intelligence
The optimizer estimates what *should* be fed. Feed Performance Intelligence measures what *was* fed and the observed production/health/economic response. Feed performance findings may trigger recalculation, but correlation is not proof of causation. Expose a single manager view:
**cow → requirement → proposed ration → approved program → actual dated feed/mix exposure → milk/health response → cost and alerts**.

## 10. Safety, approval and explainability
- Health-related restrictions from an authorized veterinarian override optimization objectives.
- The system must not diagnose illness or prescribe treatment from feed/milk signals.
- Any proposed change requires farm-authorized review/approval; nutritional/veterinary professional review is required for high-risk or clinically restricted animals.
- Never silently change an approved formula, numbered mix, feeding program or actual ledger.
- Record source/version of equations, ingredient quality evidence, missing variables, constraints, infeasibility, rationale and confidence.
- Provide cautious gradual transition guidance only within reviewed nutritional protocols; no automatic abrupt ration switches.
- Allow worker-friendly as-fed kg per meal while preserving dry-matter nutrient arithmetic.

## 11. Acceptance criteria
1. Two cows with different milk yield/lactation/weight/health may receive different requirement vectors and ration proposals.
2. Recalculation follows changed milk production or health state, without auto-applying the proposal.
3. Missing body weight, silage quantity or nutrient analysis is visible and reduces confidence; never invent measured values.
4. Ingredient lots from different suppliers and numbered mixes remain individually traceable.
5. Existing mix stock can be allocated, but its historical recipe cannot be rewritten by the optimizer.
6. Solver respects nutrient, safety, intake, stock, species and veterinary constraints; infeasible scenarios are reported.
7. Supplement/premix inclusion respects reviewed label dosing and does not double count nutrients.
8. Group rations show individual coverage and outliers, not just averages.
9. Cost/head/day and cost/litre are derived from actual price and production data with transparent assumptions.
10. Approved feeding program and actual feeding event remain separate from the AI recommendation.
11. Regression tests cover units, dry matter/as-fed conversion, milk yield changes, pregnancy/lactation changes, health restrictions, low stock, unavailable nutrients, and unsafe inclusion.
12. UI shows per-cow requirements, proposed daily kg and meal split, nutritional gaps, total cost, approval status and monitoring history.

## 12. Authoritative technical reference
National Academies of Sciences, Engineering, and Medicine (2021), *Nutrient Requirements of Dairy Cattle*, Eighth Revised Edition, National Academies Press, https://doi.org/10.17226/25806. Actual equation implementation requires source verification and professional validation.
