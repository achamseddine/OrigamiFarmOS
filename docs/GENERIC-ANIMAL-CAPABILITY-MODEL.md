# Generic Animal Model & Dynamic Species Capabilities

*Design specification and implementation map. The specification came in as a
developer handoff; the "In this codebase" notes under each section say where
it lives and where the implementation deliberately differs.*

---

## 1. Core design decision

There is **one generic `Animal` entity** for every species. Nothing in the
schema, the API or the tablet is a "cow" table, a `Cow` class, or a branch on
`species == "cow"`. What an animal can do is not implied by its species; it is
**resolved** from configuration:

```
species → sex → life stage → management profile → capability set
```

and the capability set drives identification, reproduction, production, health
and management behaviour, on the server and on the tablet.

**In this codebase**

- `backend/app/domain/models.py::Animal` is the one entity. `species` is a
  foreign key to the `species` catalog by its natural code (`cow`,
  `layer_hen`, …), not an integer `species_id`. The specification allows this
  ("referential integrity is more important than forcing a specific ORM
  pattern"); the natural key keeps the published API contract — every
  response already carries `"species": "cow"` — and every Dart parser intact.
- `backend/app/services/capability_service.py::resolve` is the resolver.
- `mobile/flutter_app/lib/livestock/capability_resolver.dart` is the same
  algorithm in Dart, over the same rule rows, so the tablet resolves offline
  and cannot disagree with the server (`test/livestock_resolver_test.dart`
  checks every seeded animal both ways).

## 2. The catalog

Species, breeds, life stages, management profiles, capabilities and the rules
that connect them are **rows, not code**.

| Table | Purpose |
| --- | --- |
| `species` | `code` (PK), names EN/AR, `reproduction_mode` (viviparous / oviparous / unspecified), `icon`, `default_management` (individual / group / either), `terminology_json`, `profiles_json` (which profiles this species is offered), `active`, `sort_order` |
| `breeds` | per species, optional; a breed the catalog does not list is free text on the animal |
| `life_stages` | `adult`, `young`, … — global or per species |
| `management_profiles` | `dairy`, `meat`, `breeding`, `layer`, `broiler`, `work`, … |
| `capabilities` | the capability codes with a category and labels |
| `species_capability_rules` | one line of configuration: species × capability × (sex? life stage? profile?) → `enabled`, `required`, `configuration_json`, `priority` |

`backend/app/livestock/catalog.py` holds the shipped catalog;
`reference.py::ensure_reference_data` upserts it idempotently (seed, prod
seed) and `migration_rows()` feeds the migration so a fresh production
database is self-sufficient. **Nothing is deleted** by the upsert: a farm's
own rows survive a redeploy.

## 3. Capability codes

| Category | Codes |
| --- | --- |
| identification | `EAR_TAG` `RFID` `MICROCHIP` `LEG_BAND` `PASSPORT` `INDIVIDUAL_TRACKING` `GROUP_TRACKING` |
| reproduction | `BREEDING` `PREGNANCY` `LIVE_BIRTH` `INCUBATION` `HATCHING` |
| production | `MILK_PRODUCTION` `LACTATION` `EGG_PRODUCTION` `WOOL_PRODUCTION` `GROWTH_TRACKING` |
| management | `WEIGHT_TRACKING` `BODY_CONDITION` `HOOF_CARE` `FEED` `MORTALITY` |
| health | `HEALTH` |

The shipped configuration, by species, resolves to (adult female unless
stated):

| Species | Identification | Reproduction | Production | Care |
| --- | --- | --- | --- | --- |
| cow (dairy) | EAR_TAG **required** (expected — see §4a), RFID | breeding, pregnancy, live birth | milk, lactation, growth | hoof care |
| cow (meat) | same | same | growth only | hoof care |
| bull | same | breeding | growth | hoof care |
| sheep (dairy / meat / wool) | EAR_TAG required, RFID | breeding, pregnancy, live birth | milk+lactation only on `dairy`; wool on `wool` | hoof care |
| goat | as sheep, no wool | | | |
| horse | MICROCHIP **required** (expected — see §4a), PASSPORT; **no** EAR_TAG | breeding, pregnancy, live birth | growth | hoof care |
| layer hen / duck / turkey (layer) | LEG_BAND, group tracking | breeding | eggs, growth | — |
| poultry (broiler) | LEG_BAND, group tracking | — (vetoed) | growth only (eggs vetoed) | — |

Every adult-only rule also holds for the **senior** stage (`catalog.SENIOR_RULES`,
migration `a8d0c2e4f6b1`): an old cow still calves and is milked, an old mare
still foals. Before that, a female registered "senior" could not be recorded
pregnant or in milk.

### 4a. Registering with nothing to scan (decision 2026-11-13)

The table above marks the identifier a species is *expected* to carry. After
on-farm testing the farm decided — resolving the conflict between this
document's earlier "required identifier missing → 422" and
`database/LIVESTOCK-SCHEMA.md` §19 ("ear tag is not universally mandatory") —
that a missing expected identifier **does not block registration**:

- every new animal gets the farm's next **farm number** (`FARM_NUMBER`, one
  farm-level sequence for all species, zero-padded, never reused; a typed
  farm number is kept and the sequence continues after the highest in use) —
  `identifier_service.with_farm_number`;
- its QR label (`origami://animal/{uuid}`, ADR-003) is shown to print as soon
  as the server has saved it; a registration still in the offline outbox
  prints once synced, because the label must carry the id the server knows;
- the farm number is primary only when nothing else was given; a typed ear
  tag stays primary;
- the Digital Twin's identification list says "Not recorded yet: ear tag"
  (microchip, …) until the expected identifier is added;
- retiring the only expected identifier is still refused (add the
  replacement first), and uniqueness rules are unchanged (409).

## 4. Identification

`ear_tag` is **not** a column an animal must have. Identifiers are a child
collection — `animal_identifiers` — one row per ear tag, RFID, microchip, leg
band, passport, farm number, registration number, name or other:

- `identifier_type`, `identifier_value`, `issuing_authority`,
  `valid_from` / `valid_to`, `is_primary`, `status` (`active` | `retired`),
  `notes`.
- **Unique per (farm, type, issuing authority)** among active rows; a clash
  is a 409 naming the animal that has it.
- **Retired, never deleted.** A replaced tag stays on the record and still
  finds the animal in search.
- Which types an animal may carry, and which it must, come from the
  capability set: `EAR_TAG` → ear tag, `MICROCHIP` → microchip, … and
  `NAME`, `FARM_NUMBER`, `REGISTRATION_NUMBER`, `OTHER` are always allowed.
- `animals.tag` is kept as a **nullable denormalised copy of the primary
  identifier's value** for sorting, search and the `#744` on a card. It is
  written by the identifier service, never by hand.

`backend/app/services/identifier_service.py` does the collecting, the
uniqueness check, the primary election and the legacy `tag` → identifier
mapping (`EAR_TAG` if allowed, else `LEG_BAND`, else `FARM_NUMBER`).

## 5. Sex, life stage, management profile

- Sex is `F`, `M` or `U` (explicitly unknown). `FEMALE` / `MALE` / `UNKNOWN`
  are accepted on input and normalised.
- Life stage defaults to `adult` when unset — a rule with no life stage
  matches every stage.
- Management profile is optional. A species is offered only the profiles in
  its `profiles_json`; a horse is never offered "broiler".

## 6. Terminology

Events are generic; the words are the farm's. `species.terminology_json`
carries `birth`, `offspring`, `group`, `female`, `male` in EN and AR:
*Calving / Lambing / Kidding / Foaling*, *Cow / Ewe / Doe / Mare*, *Herd /
Flock*. The resolved capability set carries the species' terminology so a
screen never needs a second lookup.

## 7. Livestock subjects: animals and groups

Some species are managed per head, some per batch. `LivestockSubject` is
either an `Animal` or an `AnimalGroup`. Here `AnimalGroup` is the existing
`flocks` table, extended (`group_type`, `sex_composition`, `life_stage`,
`management_profile`) and exposed as `/animal-groups`; the polymorphic
subject is expressed as explicit foreign keys on the record tables rather
than a `livestock_subject` table. A group resolves capabilities like an
animal (`sex_composition` → sex). A group either counts heads or counts
its registered members (`tracking_mode`, LIVESTOCK-SCHEMA §6): a counted
flock needs the species' `GROUP_TRACKING`, a herd of registered cows only
needs its members to be individuals, so a horse cannot be a counted
group (422) but a pen of mares can be a membership group. See §16 for
memberships, the head-count ledger and the rest of the livestock record.

## 8. Dynamic UI

The tablet draws what the capability set allows and nothing else:

- **Add / Edit Animal** (`features/animals/add_animal_form.dart`): species
  from the catalog → sex → life stage → profile; the device resolves;
  identifier fields appear per allowed type, all optional ("nothing to scan",
  §4a); a "tracked" summary shows the consequence of the profile chosen.
  **Pregnancy & milk** (`animal_status_section.dart`) is asked of every
  female whose species has `PREGNANCY` / `LACTATION` under *some* stage and
  profile — on a new animal and on an existing one: *Not pregnant /
  Inseminated — not confirmed / Pregnant* with the insemination date and
  method, the expected birth and the farm's dry-off date; *Producing milk /
  Not milked — dried off*. An answer the current stage or profile does not
  allow moves them to the first combination that does (a goat with no
  profile said to be milked becomes `dairy`; a "young" female said to be
  pregnant becomes `adult`) and says so on the form. Nothing is saved as a
  flag: a new animal arrives with `service_date` / `service_type` /
  `pregnant` / `lactating` in one request (breeding event + pregnancy episode
  dated from the service + lactation episode); an edit turns each changed
  answer into the record the herd keeps — a NEGATIVE / POSITIVE pregnancy
  check, a breeding event, a lactation start, a dry-off — after the PUT, in
  that order, skipping what an earlier partial save already wrote. Saying
  an animal is milked opens the milk record straight after the save.
- **Digital Twin** (`animal_digital_twin_screen.dart`): identifiers (add /
  retire), life stage, profile, "Female · Cow", a pregnancy line only where
  it can exist, a milk quick action and milk trend only with
  `MILK_PRODUCTION`, and the tracked capabilities.
- **Herd, milk and egg screens** take species names, icons and the set of
  egg-laying species from the catalog; no screen lists species itself.

## 9. Validation rules

| Rule | Where |
| --- | --- |
| identifier type not allowed for the animal → 422 | `identifier_service.collect` |
| required (expected) identifier type missing at registration → **registered**, farm number generated, shown as missing (§4a) | `identifier_service.with_farm_number` |
| identifier value already used in the farm → 409 | `identifier_service.ensure_unique` |
| retiring the only required identifier → 422 | `DELETE /animals/{id}/identifiers/{iid}` |
| `pregnant` / `lactating` on an animal without `PREGNANCY` / `LACTATION` → 422 | `api/v1/animals.py::_check_state_against` |
| milk record for an animal without `MILK_PRODUCTION` → 422 | `api/v1/production.py` |
| egg record for a flock without `EGG_PRODUCTION` → 422 | same |
| unknown species → 422 | `_species_or_422` |
| species change once the animal has milk / treatment / observation history → 409 | `update_animal` |
| a group for a species without `GROUP_TRACKING` → 422 | `POST /animal-groups` |

The tablet applies the same identifier and state rules before the round
trip — and offline, where there is no round trip.

## 10. The resolver

```
resolve(species, sex, life_stage=None, management_profile=None) -> CapabilitySet
```

1. **Candidates**: every rule of the species whose `sex`, `life_stage` and
   `management_profile` are unset or equal to the animal's.
2. **Per capability, the most specific granting rule wins** — specificity is
   the number of dimensions the rule sets; `priority` breaks ties.
3. **A matching rule with `enabled = false` is a veto** and wins outright,
   whatever its specificity. This is how a broiler profile removes eggs and
   breeding from a species whose female-adult rules grant them.
4. **Biological invariants last**, not configurable: a male never has
   `PREGNANCY`, `LIVE_BIRTH`, `LACTATION`, `MILK_PRODUCTION`,
   `EGG_PRODUCTION`; an oviparous species never has `PREGNANCY`,
   `LIVE_BIRTH`, `LACTATION`, `MILK_PRODUCTION`; a viviparous one never has
   `EGG_PRODUCTION`, `INCUBATION`, `HATCHING`. Everything biology rules out
   is listed in `suppressed`, granted or not, so a screen can say *why* a
   tab is missing.

The result carries the capabilities (with `required` and per-rule
configuration), `allowed_identifier_types`, `required_identifier_types`,
`subject_kind` (individual / group / either), `reproduction_mode`,
`terminology` and `suppressed`.

## 11. API

| Method & path | Purpose |
| --- | --- |
| `GET /species` | active species, sorted |
| `GET /species/{code}/configuration` | species + breeds + life stages + the profiles it is offered + its rules — everything the Add Animal flow needs in one call, and everything the device resolver needs |
| `GET /capabilities` | the capability catalog |
| `POST /animal-capabilities/resolve` | resolve a hypothetical animal (`species`, `sex`, `life_stage`, `management_profile`) |
| `GET /animals/{id}/capabilities` | resolve an existing animal |
| `GET /animals/{id}/identifiers` | all identifiers, active and retired |
| `POST /animals/{id}/identifiers` | add one (type must be allowed; may take over primary) |
| `DELETE /animals/{id}/identifiers/{iid}` | retire one |
| `GET / POST /animal-groups`, `GET / PATCH /animal-groups/{id}`, `GET /animal-groups/{id}/capabilities` | groups |
| `POST /animals` | now takes `identifiers: [...]`, `life_stage`, `management_profile`, `breed_id`, `birth_date_estimated`; `tag` is optional and, when given, becomes the primary identifier |
| `GET /animals/{id}` | the digital twin now carries `capabilities` |

Full request and response shapes are in the API contract page.

## 12. Migration

`database/migrations/versions/7c2e9a41d5b8_generic_animal_model.py`:

1. creates the six reference tables and `animal_identifiers` and inserts
   the shipped catalog (so production needs no seed step);
2. makes `animals.tag` nullable, adds `breed_id`, `birth_date_estimated`,
   `life_stage`, `management_profile`, points `animals.species` and
   `flocks.species` at the catalog, extends `flocks` (SQLite-safe
   `batch_alter_table`);
3. backfills: every existing `tag` becomes an active primary identifier —
   `EAR_TAG` for viviparous species, `LEG_BAND` for oviparous; a lactating
   animal gets the `dairy` profile so its next milk record is not refused;
   flocks become `female` / `layer` groups.

The downgrade restores `tag` from the primary identifier and drops the
rest. Verified upgrade → downgrade → upgrade against legacy rows.

## 13. Build order and status

| Step | Status |
| --- | --- |
| 1 species / breed / capability / rule tables | done |
| 2 `AnimalIdentifier` | done |
| 3 resolver + endpoints | done |
| 4 dynamic Add Animal form | done |
| 5 dynamic animal-profile navigation | done (sections and quick actions gate on capabilities) |
| 6 identifier validation | done |
| 7 reproduction events model | done — breeding events, pregnancy episodes and checks, births with their newborns, lactation episodes; `pregnant` / `lactating` are a projection, never edited (§16) |
| 8 production gating | done for milk and eggs |
| 9 unified `production_records` | **not done** — the typed `milk_records` / `egg_records` tables are kept and gated; unifying them is a schema change with no user-visible gain yet |
| 10 animal groups | done — first-class: effective-dated memberships, group-type policies (exclusive herds/pens, overlapping cohorts), a head-count ledger (§16) |
| 11 incubation / hatching | done — incubation batches and hatch events, chicks counted into the destination flock's ledger (§16) |
| 12 admin UI for the catalog | **not done** — species are added by inserting rows (the resolver, the API and the tablet pick them up with no code change, which is what the acceptance test proves) |

## 14. Acceptance

`backend/tests/test_livestock.py::TestAnimalRegistration::test_adding_a_species_is_configuration`
inserts a *camel* — species row, a few rules, no code — and registers one
through the public API with the identifiers and capabilities the rules say.
Mirrored on the tablet, the resolver test asserts every seeded animal
resolves identically on the device and the server.

## 15. The non-negotiable rule

**Animal is the entity. Species is data. Capabilities are resolved.
Behaviour is driven by resolved capabilities, never by hard-coded species
checks.** The one permitted "check" is the biological invariant table in the
resolver — and it is keyed on `reproduction_mode` and sex, not on a species.

## 16. The livestock record: history, groups, reproduction

Implemented with migration `b5e7a9c1d3f8` from `database/LIVESTOCK-SCHEMA.md`
§5–§10, §14, `REPRODUCTION-SCHEMA.md` and `PRODUCTION-SCHEMA.md` §8.

**State history** (`animal_state_history`, `services/livestock_state_service.py`).
Status (lifecycle), life stage, management profile and location are current
values on `animals`, but a change to any of them closes the open history
range and opens a new one first — the edit form, a move and an exit all go
through `record()`. `GET /animals/{id}/history`.

**Exit** (`POST /animals/{id}/exit`: dead, sold, culled, slaughtered,
transferred). Behavioural model §14: the animal's group memberships, active
lactation and pregnancy and its feeding assignments close; a hybrid or
counted flock it belonged to records the loss in its ledger; milk, feeding
and reproduction records are refused afterwards; everything recorded before
stays. A death is recorded by anyone with Animals · edit, the others need
Animals · approve. An archive is the same workflow; only an archived animal
can be restored.

**Groups** (`services/group_service.py`). Memberships are effective-dated
and closed, never deleted; joining another exclusive group is a move.
`flocks.count` is the number of current members (MEMBERSHIP_DERIVED) or the
running total of `animal_group_quantity_events` (QUANTITY_MANAGED / HYBRID);
it is never typed over — an older client's "count = N" becomes a
COUNT_ADJUSTMENT. `animals.group_name` is the name of the animal's current
exclusive group, and the feeding resolver inherits a program from that
membership. A herd name in the edit form must name an existing group of the
species. `/animal-groups/{id}/members`, `/animal-groups/{id}/quantity-events`,
`/animal-group-types`.

**Reproduction and lactation** (`services/reproduction_service.py`,
`api/v1/reproduction.py`). Every action is checked against the resolved
capabilities (BREEDING, PREGNANCY, LIVE_BIRTH, LACTATION, INCUBATION,
HATCHING). Pregnancy is never inferred from a mating: a positive check opens
the episode, dated from the examiner's gestation or the likely service, and
the species' configured `gestation_days` gives the due date; a negative check
or a loss ends it. A birth closes the pregnancy, registers each newborn
marked for it through the normal registration path (so a calf needs its ear
tag) or counts it into a group, links DAM_OF / SIRE_OF, and starts the dam's
next lactation where she has the capability — one transaction, refused whole
if any newborn is refused. A newborn not registered at birth is registered
later from its birth row. `animals.pregnant`, `pregnancy_days` (computed from
the conception date at read time), `expected_due_date`, `lactating`,
`lactation_cycle`, `lactation_started_at` and `dried_off_at` are a projection
of the episodes; `PUT /animals` refuses to change pregnancy or lactation.
Every change that moves what the feeding resolver reads raises a feeding
review and re-reads feed performance. `GET /reproduction/overview` answers
who is due, who waits for a check, who is in milk and what is in the
incubator.

**Identifiers.** `GET /animals?search=` matches every identifier an animal
carries or carried; `GET /animals/lookup?value=` returns every exact match,
a retired tag flagged — an ambiguity is the person's to resolve.

**Migration.** Existing data becomes the records it stood for: opening state
history for every animal; a free-text herd name that named no group becomes
a membership-derived group of that name, with memberships; an existing flock
with registered members becomes HYBRID, its count an INITIAL_COUNT row;
`pregnant` and `lactating` become active episodes (`tests/test_livestock_backfill.py`,
on SQLite and PostgreSQL 16).

**Tablet.** The Digital Twin has a Reproduction & milking card (status, due
date, last service and check, the lactation, and only the actions that
apply, in the species' own words — "Calving", "Kidding"), the full
reproductive record with "Register" on an untagged newborn, a Herd & family
card (groups, dam, sire, offspring, history, an exited banner), and "Record
exit". The Animals screen shows the reproduction day; every group opens its
members, head-count ledger and, for poultry, the incubator. All of it works
offline and in the standalone build through `cache_effects.dart`.

**Deviations recorded here.** `flocks` remains the AnimalGroup table (no
separate `code`; the id is identity, the name display). Due and hatch dates
are `timestamptz` like every date in this schema, not `date`. Quantities stay
`Float` like the rest of the schema; the move to `numeric` is one
cross-cutting change, not this one. `lactation_episodes` lives in
`reproduction_models.py` beside the births that start it, and remains a
production state read by production and feed.
