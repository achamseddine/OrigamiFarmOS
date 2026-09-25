# Generic Feed, Formula, Batch & Feeding Program Architecture

*Design specification and implementation map. Companion to
`GENERIC-ANIMAL-CAPABILITY-MODEL.md`. The specification came in as a
developer handoff; the "In this codebase" notes under each section say where
it lives and where the implementation deliberately differs.*

---

## 1. Core design decision

Feeding is **one generic subsystem for every species**. There is no dairy feed
module, no poultry feed module, and no `if species == "cow"` in any feed code.
Five concepts are kept apart and are never collapsed into one another:

| Concept | Question it answers | Table |
| --- | --- | --- |
| **Feed product** | What *can* be fed or mixed? | `feed_products` |
| **Feed formula (+ version)** | How is a farm-made feed *meant* to be mixed? | `feed_formulas`, `feed_formula_versions`, `feed_formula_components` |
| **Feed batch** | What was *actually* mixed, from which lots, at what cost? | `feed_batches`, `feed_batch_components` |
| **Feeding program (+ version)** | What *should* a kind of animal get, and which animals does that apply to? | `feeding_programs`, `feeding_program_versions`, `feeding_program_components`, `feeding_program_rules` |
| **Feeding event** | What *was* fed, to whom, from which lot? | `feeding_events`, `feeding_event_components` |

Species, sex, life stage, management profile, reproductive and lactation
state and production level are **matching dimensions on rules**, never
branches in code. A feeding program for a lactating mare and one for a
high-yield cow are two rows in the same table, resolved by the same function.

**In this codebase**

- `backend/app/domain/feed_models.py` — the 23 tables (listed in §20).
- `backend/app/services/feeding_program_service.py::resolve_state` is the
  resolver (§7); `feed_inventory_service.py` the stock ledger (§3, §11, §13,
  §14); `feed_policy_service.py` the usage policies (§12);
  `feed_batch_service.py` formulas, batches and nutrient profiles (§4, §5,
  §8); `feed_forecast_service.py` cover, forecast, reorder and reconciliation
  (§15–§17).
- `backend/app/api/v1/feeding.py` — 59 endpoints under `/api/v1`
  (`FEED_NUTRITION` module permissions: view / create / edit / approve).
- `database/migrations/versions/b4d7e2f9a1c3_generic_feed_architecture.py`
  creates everything, inserts the nutrient catalog and backfills existing
  feed inventory into products and opening-balance lots (round-trip
  verified up and down).
- `mobile/flutter_app/lib/features/feed/` is the tablet workspace;
  `lib/features/animals/animal_feeding_section.dart` the animal profile's
  feeding section.

## 2. Feed products

A feed product is anything that can be put in front of an animal or into a
mixer: bought hay, a purchased premix, a farm-made total mixed ration. It
has a `source_type` (`purchased` | `farm_produced`), two flags —
`is_ingredient` (may go into a formula) and `is_feedable` (may be fed as it
is) — a category (`forage`, `concentrate`, `premix`, `mineral`,
`complete_feed`, `byproduct`, `other`), a unit and a default unit cost.

**In this codebase**

- Every feed product owns **exactly one `inventory_items` row**; the item
  is the stock ledger and the product is the feed semantics. There is no
  shadow stock. The existing Feed & Inventory screen keeps working on the
  item and now shows the lot behind each movement.
- The specification's *feed item* / *feed product* pair is collapsed into
  one `feed_products` row with the two flags; nothing in the spec needed
  them to be separate rows.
- Medicines and other non-feed inventory categories are left on the plain
  ledger (`api/v1/feed.py::_NOT_FEED`).
- Units are a code catalog, not a table: `backend/app/feeding/uom.py`
  normalises `kg`/`g`/`t`, `L`/`ml`, `head`, `bale`, `bag` and converts
  within a family; mixing families is refused with the reason.

## 3. Lots and the ledger

Physical stock is held in **lots** (`feed_lots`): a delivery, a farm-made
batch's output, or an opening balance. A lot carries its supplier, received
/ accepted / rejected quantities, expiry, unit cost and a status —
`active`, `quarantined`, `blocked`, `recalled`, `expired`, `depleted`.

Every movement is an `inventory_transactions` row **with a `lot_id`**.
Consumption is drawn **FIFO from usable lots** unless a lot is named.

```
available = on_hand − unusable lots (quarantined | blocked | recalled | expired)
                    − quantity reserved for other purposes (§13)
```

**In this codebase**

- `feed_inventory_service.receive` creates the lot and the `in` movement;
  `consume` draws FIFO (or from a chosen lot) and writes one `out` movement
  per lot touched, returning the draws so callers can price them;
  `availability` computes the formula above per product and per purpose.
- `allow_negative` is a legacy override (`POST /feed/transactions` on a
  non-lot item) recorded against no lot; nothing in the new endpoints uses
  it silently.
- `reconcile_opening_balance` pins an item's figure into an opening lot
  only when the product has no lots yet, so a backfilled farm starts clean.

## 4. Formulas and versions

A formula belongs to a farm-produced product and says how it is mixed:
components (ingredient products with target quantities per batch size) and
an optional species scope. Versions are numbered; **a version that any
batch has used is `locked` and can never change** — a new version is
created instead, and `activate` moves the formula's pointer.

`GET /feed-formulas/{id}/versions/{v}/scale?batch_size=` returns the
targets scaled to a batch; `…/nutrients` returns the calculated nutrient
profile from the components' own profiles (§8).

## 5. Batches

A batch is started from a formula version with a target quantity
(`feed_batch_started`). Completing it takes the **actual** quantity of each
ingredient and which lot it came from (FIFO if unsaid), consumes those lots,
prices the batch from the lot unit costs, and receives the output as a new
lot of the produced product with `source_type = farm_produced`
(`feed_batch_completed`). Variance per component and against the planned
cost is kept on the batch. A batch can be quarantined, which quarantines
its output lot.

## 6. Feeding programs

A program is a named ration for a kind of subject: components as
quantity per head per feeding or per day, `feedings_per_day`, and
**applicability rules**. A rule may set any of: species, sex, life stage,
management profile, reproductive state, lactation state, a production band
(`production_metric` `production_min`/`production_max`, e.g. milk litres
per day), a weight band, an age band, and a priority. A dimension a rule
leaves unset matches anything. A program with no rules is **manual
assignment only**.

Programs are versioned like formulas; the version an assignment points at
is the one that was current when the assignment was made, and activating a
new version moves open assignments onto it (`feeding_program_activated`).

## 7. The resolver

```
resolveFeedingPrograms(species, sex, lifeStage, profile, reproductiveState,
                       lactationState, production, weight, age)
```

- A rule **matches** when every dimension it sets equals the subject's.
- A range on a metric the subject does not have (a milk band for an animal
  with no milk records) is a **warning and no match**, never a silent pass.
- Among matching programs the best is the highest **(specificity,
  priority)** — specificity is how many dimensions the rule sets.
- The answer is **explainable**: every eligible program comes back with
  its matched rule's reasons, and `requires_review` is set when the best
  match differs from the subject's current program.

`POST /feeding-programs/resolve` runs it on a described subject (the
programs tab's "Which program would apply?" panel); the same function runs
behind every plan and every review.

**In this codebase** — `feeding_program_service.subject_state` builds the
`SubjectState` from an animal (or a group, see §9) and its records: milk
per day is the last seven days' average from `milk_records`, age from
`birth_date`, lactation from the animal's flag.

## 8. Nutrients

The nutrient catalog is rows (`feed_nutrients`: dry matter, crude protein,
NDF, ADF, fat, ash, calcium, phosphorus, ME, NEL, starch, sugar, lysine,
methionine, sodium, vitamin A, selenium — 17 to start; adding one is an
insert). A **nutrient profile** (`feed_nutrient_profiles` +
`feed_nutrient_values`) belongs to a product or a formula version, on an
`as_fed` or `dry_matter` basis, from a `declared`, `calculated` or `lab`
source. A lab result **never overwrites** a declaration — they sit side by
side, newest first.

## 9. Groups, inheritance and individual exceptions

A subject is an `animal` or a `group` (the animal model's
`LivestockSubject`). A program assigned to a group applies to every animal
in it; an animal's effective program is:

1. its own explicit assignment, if any;
2. otherwise the program of the group it is in (`group_name`, same species)
   — **computed at read time, never copied onto the animal**.

On top of that an animal may carry individual assignments of type
`supplement` (an extra quantity of a product), `override` (a different
quantity for a product the program already gives) or `restriction` (a
product it must never get, which the feeding endpoint refuses). The plan
shows each with its reason and validity.

A group's own state for the resolver is aggregated from its members:
lactation state by majority, milk by average, life stage and profile from
the group row.

## 10. Lifecycle changes → review, never silent reassignment

When an animal's sex, life stage, management profile, pregnancy, lactation
or group changes, when a milk record moves it across a production band, or
when a group's head count / life stage / profile / sex composition changes,
the resolver runs again. If the best program is not the current one the
system raises **`feeding_program_review_required`** and opens **one** Task
(`source_type = feeding_review`) per subject — it never swaps the program
itself. An explicit assignment closes the task. The animal's profile shows
the banner with the recommended program and the reasons; only a user with
`approve` on the feed module can assign it.

**In this codebase** — hooks in `api/v1/animals.py` (relevant fields
only), `api/v1/production.py` (after a milk record) and
`api/v1/livestock.py` (group edits) call
`feeding_program_service.review_animal_if_relevant` / `review_after_milk`
/ `review_feeding`.

## 11. Feeding events

`POST /feeding-events` records what was put in front of a subject:
`offered`, `delivered`, `consumed_estimate` or `refusal`, with components
(product, quantity offered, optional quantity consumed, optional lot). Each
component is drawn from stock (FIFO or the named lot), the lot is written on
the component, and the event is **priced from the lots it drew**. A
refusal or a consumption estimate moves no stock. Events are reversed, not
deleted: `POST /feeding-events/{id}/reverse` writes a compensating
`reversal` event and returns the stock to the lots.

The event's `program_version_id` is the plan that was in force, so history
is auditable against what should have happened.

## 12. Usage policies

A product (and, more tightly, a lot) may carry a usage policy: `allow`,
`block` and `limit` rules over species / management profile / life stage /
reproductive state / age, a maximum inclusion percentage in a formula,
`requires_approved_formula` (may only be fed through a formula) and
`cross_species_transfer` (whether an allocation may move to another
species). Product and lot policies are **ANDed** — a lot can only tighten.

Policies are enforced at four moments: composing a formula, completing a
batch, assigning a program and recording a feeding. A refusal is a 422 with
a sentence a farmer can act on, and a `feed_usage_blocked` event.

**In this codebase** — `feed_policy_service.evaluate(product, target)`;
`Target.partial = True` for authoring-time checks (a formula knows the
species but not the profile, so unset dimensions match) and `False` for a
real subject.

## 13. Allocations

`POST /feed-allocations` reserves a quantity of a product (optionally of a
lot) for a **purpose** — a species, a subject or a program. Reserved stock
is invisible to every other purpose's availability and is drawn only by a
consumer with that purpose; `transferable` says whether an approver may
move it (`…/transfer`, checked against `cross_species_transfer`). Releasing
returns the remainder to the pool.

## 14. Quantity control

Ordered / received / accepted / rejected are four numbers on a receipt,
kept apart. A lot's status change (`quarantine`, `block`, `recall`,
`release`) records the reason and its own event. Adjustments
(`POST /feed-inventory/adjustments`) require an explanation and are the
only way to change a figure without a movement behind it.

## 15. Reconciliation and variance

`POST /feed-reconciliations` computes, **from the ledger**, opening +
received − issued to batches − issued to feeding − other issues − waste +
returned ± adjustments = expected closing for a product (or lot) over a
period, takes the counted closing, and stores the variance. A variance past
the product's reorder policy threshold raises
`feed_inventory_variance_detected`. Closing with `post_adjustment` writes an
explained `reconciliation_adjustment` movement so the ledger meets the
count; the explanation is mandatory when there is a variance.

## 16. Days of cover and forecast

Daily demand per product comes from today's plan: every group and
individually assigned animal × its program × head count, expanded through
the active formula's proportions when the product is farm-made. Where no
program demands a product the last 30 days of feeding history stand in
(`demand_source = history`), and a product nobody needs says `no_demand`
rather than inventing a number. Days of cover = eligible available ÷ daily
demand; the eligible figure respects usage policies per species, so a
premix only cattle may eat is not counted as covering goats.
`GET /feed-inventory/forecast` projects the horizon and persists it.

## 17. Reorder

A reorder policy per product (minimum, reorder point, safety stock,
preferred quantity, maximum, lead time, cover margin, variance threshold)
turns cover into recommendations with **reasons**: below reorder point,
would run out inside lead time + margin, below minimum. Each carries a
suggested quantity and the programs it would starve. A recommendation is a
signal in the notification bell until acknowledged;
`…/acknowledge` opens a `feed_reorder` Task and the recommendation is
suppressed while that task is open.

## 18. Traceability, both ways

`GET /feed-lots/{id}/trace` returns, for one lot: where it came from
(supplier or the batch that made it, and that batch's ingredient lots),
where it went (the batches that used it and their output lots), every
feeding event that drew on it, and the **exposed subjects** — each animal
or group, with quantity, event count and first/last date. A recall is one
call.

## 19. Costs

`GET /feed-costs?days=` totals feeding cost for the period from the priced
events, by subject (with cost per litre where milk records exist) and by
product, plus each batch's planned versus actual cost and unit cost.

## 20. Tables

| Table | Holds |
| --- | --- |
| `feed_products` | the feed semantics over one `inventory_items` row |
| `feed_lots` | physical stock with origin, quantities, cost, expiry, status |
| `feed_usage_policies`, `feed_usage_policy_rules` | product / lot policies and their allow / block / limit rules |
| `feed_formulas`, `feed_formula_versions`, `feed_formula_components` | recipes, immutable once used |
| `feed_batches`, `feed_batch_components` | what was mixed, from which lots, with actuals and cost |
| `feed_nutrients`, `feed_nutrient_profiles`, `feed_nutrient_values` | the catalog and declared / calculated / lab values |
| `feeding_programs`, `feeding_program_versions`, `feeding_program_components`, `feeding_program_rules` | rations and applicability |
| `feeding_assignments` | explicit / supplement / override / restriction per subject |
| `feeding_events`, `feeding_event_components` | what was fed, from which lot, at what cost |
| `feed_allocations` | reservations by purpose |
| `feed_reorder_policies` | thresholds and lead times |
| `feed_demand_forecasts` | persisted horizon projections |
| `feed_reconciliations` | ledger versus count |

`inventory_transactions.lot_id` is the one column added to an existing
table.

## 21. Events

`feed_lot_received`, `feed_lot_quarantined` / `blocked` / `recalled` /
`expired` / `released` / `status_changed`, `feed_inventory_consumed`,
`feed_inventory_adjusted`, `feed_allocation_created` / `released` /
`transfer_requested` / `transferred`, `feed_usage_policy_set`,
`feed_usage_blocked`, `feed_formula_version_activated`,
`feed_batch_started` / `completed` / `quarantined`,
`feed_nutrient_profile_recorded`, `feeding_program_activated` /
`assigned` / `changed`, `feeding_program_review_required`,
`feeding_event_recorded` / `reversed`, `feed_reorder_required` /
`acknowledged`, `feed_inventory_variance_detected`,
`feed_reconciliation_completed`. Names are snake_case like every other
event in the log (the specification's `FeedBatchCompleted` is
`feed_batch_completed`).

## 22. The tablet

`FeedWorkspaceScreen` replaces the single Feed screen in the navigation
and holds nine tabs over one `FeedingProvider`: **Stock** (the previous
screen, embedded), **Feeds & lots** (availability, lots, receive a
delivery with ordered / received / rejected, reserve, lot status),
**Formulas** (versions, scaling, calculated nutrients), **Mixing** (start
a batch with scaled targets, complete it with actuals and lot choice),
**Programs** (rations, rules, the resolver panel), **Today** (the feed-room
list: every group and animal, planned against fed, one-tap record),
**Nutrition** (declared and lab profiles side by side), **Costs**, and
**Trace & control** (lot trace both ways, days of cover, reorder
recommendations with acknowledge, reconciliations with close).

The animal profile gains a **Feeding** section: the effective program with
an *assigned directly* / *from group* pill, the review banner with the
recommended program and its reasons (Assign for approvers), today's
targets, this animal's supplements / overrides / restrictions, the last
seven days and their cost, and Record feeding. The Feed quick action opens
the same feeding dialog, whose refusals show the server's sentence as it
came.

Offline: feed writes queue like every other write. `cache_effects.dart`
predicts what is safe to predict — a feeding appears on the event list, the
subject's history and its plan; a delivery becomes a lot; batches and
reconciliations change status — and deliberately predicts **no stock
figure**, because the server picks the lots and prices from them.
`outbox_labels.dart` names each queued feed write in the sync panel.
Entities: `lib/domain/entities/feeding.dart`.

## 23. Deviations from the specification, and what is not done

- **Feed item and feed product are one row** (`is_ingredient` /
  `is_feedable`), see §2.
- **No unit-of-measure table**; `uom.py` is the catalog.
- **No procurement / purchase-order module.** Acknowledging a reorder opens
  a Task; the requisition itself lives outside this system.
- **No LIMS integration.** Lab profiles are entered by hand on the
  Nutrition tab.
- **Refusal and consumption-estimate events move no stock** — they are
  records of behaviour, not movements.
- **Group membership is the animal's `group_name` within the same
  species**, as the animal model defines it; there is no separate
  membership table.
- **The tablet predicts no stock offline** (§22); availability comes back
  with the next refresh.
- Formula and program **versions are created and activated, not edited**;
  there is no draft editing UI beyond creating the next version.

## 24. Acceptance criteria (specification §22 / §34)

`backend/tests/test_feeding.py` — 44 tests — covers: a purchased product
and a farm-made product with lots; formula version locking on first batch
use; a batch consuming FIFO, pricing from lots and producing a
`farm_produced` lot; the resolver choosing the most specific program and
explaining it, warning on a missing metric; group inheritance with an
individual supplement and a restriction refused at feeding time; a milk
record crossing a band raising a review and opening exactly one task, and
an explicit assignment closing it; an event reversed back into its lots;
usage policies blocking a species at formula, batch, assignment and feeding
time; allocations invisible to other purposes and transferable only when
the policy allows; days of cover, a reorder recommendation with reasons
suppressed by its task, and a reconciliation whose variance is explained
and posted. `mobile/flutter_app/test/domain/feeding_entities_test.dart`
parses every feed response in the bundled snapshot; `test/widget_test.dart`
covers the offline effects and outbox labels.

## 25. The four questions (specification §35)

1. **Can a new species be fed without new code?** Yes — a program with a
   rule naming the species, or none at all for manual assignment. The seed
   feeds cows, goats, sheep, horses, layer hens and broilers from one table.
2. **Can a farm-made feed be traced to the animals that ate it?** Yes —
   `GET /feed-lots/{id}/trace` on the output lot lists the exposed
   subjects; on an ingredient lot it lists the batches, their output lots
   and, through them, the same subjects.
3. **Does a lifecycle change ever change a ration silently?** No — it
   raises a review and opens a task; a person assigns.
4. **Is stock ever counted twice or drawn from a lot that may not be fed?**
   No — one ledger, lots as the only physical quantities, availability net
   of unusable and reserved, and policies enforced at consumption.
