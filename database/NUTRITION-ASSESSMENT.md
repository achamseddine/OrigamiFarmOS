# Nutrient requirements and formula assessment (master prompt Package 11)

Status: implemented in v0.8.18. Code: `backend/app/domain/nutrition_models.py`,
`backend/app/services/nutrition_service.py`, `backend/app/api/v1/nutrition.py`;
app: Feed → Nutrition (`mobile/flutter_app/lib/features/feed/tabs/nutrition_assessment.dart`).

## 1. What it is, and what it is not
An **assessment** explains whether a formula, as the farm actually makes it, fed in a stated ration, meets a stated
set of requirements. It is not a ration, not a prescription and not a milk prediction:

- it never writes a formula, a formula version, a batch, a feeding program or a feeding event;
- it never assumes an analysis, an intake, a forage or a weight that was not given — the result is then
  **insufficient data**, with each missing input named, and **no recommendation**;
- it never predicts milk yield from a recipe.

## 2. Inputs (all canonical, none copied)
| Input | Source |
|---|---|
| The mix | the formula version's own components and quantities (`feed_formula_components`), converted to kg — the farm's base concentrate is **350 corn + 260 soybean ingredient + 200 barley + 200 wheat bran + 100 cottonseed + 100 beet pulp = 1,210 kg before any premix**, and stays 1,210 kg |
| A premix (optional) | a feed product and kg **on top** of the base: a what-if; the base total is kept and the inclusions are recomputed over the new total. The premix passes the feed usage policy for the set's species (a cattle-only premix is refused for sheep) and its maximum inclusion |
| Each ingredient's analysis | the existing nutrient profiles (`feed_nutrient_profiles`): the newest **lab** result, else the **declared** one (`latest_profile`). Its basis (as fed / dry matter) and its DM % are used as recorded |
| The ration | concentrate kg as fed per head per day; each forage and its kg as fed; or *this feed only*; the animals' weight |
| Requirements | one **version** of a requirement set (§3) |

## 3. Requirement sets
`nutrition_requirement_sets` + `nutrition_requirement_values`:

- per farm, a **code** and a **version** (unique together); a species (`species.code`) — other species have their
  own sets, and a formula made for one species is not assessed against another's; a production stage (configured
  words: early lactation, dry, late gestation…); a reference body weight, milk yield and expected dry-matter intake
  (each optional);
- per nutrient of the catalog a **minimum and/or maximum on the ration's dry matter**, in the catalog's unit;
- a **source** (`source_type`: published, nutritionist, veterinarian, farm; `source_reference`: the table, the person,
  the date) — **required**: a requirement without a source is not used;
- a revision is a **new version** with its own source; the old version is retired (kept, and still what its
  assessments read). Two managers revising the same version at once: the version's row lock lets one through, the
  other is told it was already revised.

The catalog gains **PENDF** (physically effective NDF, %) for effective fibre.

## 4. The arithmetic
- **Basis.** A value per kg as fed is `value ÷ (DM ÷ 100)` per kg of dry matter, and back (`to_dry_matter`,
  `to_as_fed`). An analysis without DM cannot be put on dry matter: *dry matter unknown*.
- **Units.** A profile value in another unit than the catalog's is never added up (*unit mismatch*).
- **The mix.** Per nutrient: the as-fed value `Σ kgᵢ · vᵢ ÷ Σ kgᵢ` and the dry-matter value `Σ DMkgᵢ · vᵢ(DM) ÷ Σ DMkgᵢ`,
  only when every ingredient's analysis gives it; otherwise its **coverage** (the share of the mix analysed) is shown
  and the value is left empty. Each nutrient lists what each ingredient brings.
- **The ration.** The concentrate's DM per head (its kg × the mix's DM share) plus each forage's DM is the day's
  dry-matter intake; each required nutrient is `Σ DMkgⱼ · vⱼ ÷ intake`, compared with the set: **met**, **below**,
  **above**. The intake is compared with the set's expected intake (±10 %).
- **Insufficient data** when any of: an ingredient (or the premix) without an analysis, without DM, or without a
  required nutrient; no concentrate intake; no forage (unless *this feed only*); a forage without its analysis; no
  weight while the set has a reference weight, or a weight more than 15 % from it. Then every requirement reads
  *insufficient data* and there is no recommendation.
- **Status:** *meets*, *does not meet* (with an explanation naming each nutrient, its value, the bound and the set's
  source — "an assessment, not a ration: review it with the nutritionist"), or *insufficient data*.

## 5. Stored as computed
`nutrition_assessments` keeps the inputs, the analyses used (profile ids, source, basis), the mix, the ration, what
was missing and the recommendation, as JSON, with the set's id and version. It is never recomputed: a later analysis
or a later version makes a new assessment, and the old one reads as it was. Events `nutrition_requirements_recorded`,
`nutrition_requirements_revised`, `nutrition_assessed`; audit entries for each.

## 6. Who
Feed view reads sets and assessments; Feed create (or approve) runs an assessment; requirement sets are the
manager's (Feed approve). Another farm sees nothing (404). A retry with the same `Idempotency-Key` is one assessment.
Offline, an assessment waits in the outbox and is computed when it reaches the farm server.

## 7. Not yet
Least-cost formulation (Package 12) builds on these sets and analyses. Not modelled: amino acids, DCAD, trace
minerals beyond the catalog, intake prediction from weight and milk (the expected intake is the set's, given).
