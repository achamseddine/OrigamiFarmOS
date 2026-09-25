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
| cow (dairy) | EAR_TAG **required**, RFID | breeding, pregnancy, live birth | milk, lactation, growth | hoof care |
| cow (meat) | same | same | growth only | hoof care |
| bull | same | breeding | growth | hoof care |
| sheep (dairy / meat / wool) | EAR_TAG required, RFID | breeding, pregnancy, live birth | milk+lactation only on `dairy`; wool on `wool` | hoof care |
| goat | as sheep, no wool | | | |
| horse | MICROCHIP **required**, PASSPORT; **no** EAR_TAG | breeding, pregnancy, live birth | growth | hoof care |
| layer hen / duck / turkey (layer) | LEG_BAND, group tracking | breeding | eggs, growth | — |
| poultry (broiler) | LEG_BAND, group tracking | — (vetoed) | growth only (eggs vetoed) | — |

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
animal (`sex_composition` → sex), and a species without `GROUP_TRACKING`
cannot have a group (422).

## 8. Dynamic UI

The tablet draws what the capability set allows and nothing else:

- **Add Animal** (`features/animals/add_animal_form.dart`): species from the
  catalog → sex → life stage → profile; the device resolves; identifier
  fields appear per allowed type with required ones marked; *pregnant* and
  *lactating* exist only with `PREGNANCY` / `LACTATION`; a "tracked" summary
  shows the consequence of the profile chosen.
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
| required identifier type missing at registration → 422 | same |
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
| 7 reproduction events model | **not done** — pregnancy / lactation remain flags on the animal; a `reproduction_events` table (with species terminology) is the next step |
| 8 production gating | done for milk and eggs |
| 9 unified `production_records` | **not done** — the typed `milk_records` / `egg_records` tables are kept and gated; unifying them is a schema change with no user-visible gain yet |
| 10 animal groups | done (as extended flocks) |
| 11 incubation / hatching | **not done** — the capabilities exist and resolve; there is no incubation record type yet |
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
