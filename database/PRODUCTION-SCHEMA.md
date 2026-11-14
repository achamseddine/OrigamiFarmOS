# Database Pass 4C — Livestock Production & Measurements

**Status:** Canonical implementation baseline  
**Depends on:** Foundation, Livestock  
**Integrates with:** Health withdrawals, Inventory, Sales/Quality later

## 1. Principle
Production is generic and capability-driven. Do not add `daily_milk`, `eggs_today`, `weight` or `wool` columns to Animal.

## 2. production_type
```sql
production_type (
 id uuid primary key,
 code varchar(60) not null unique,
 name varchar(120) not null,
 required_capability_code varchar(100),
 default_uom_id uuid references uom(id),
 aggregation_method varchar(30) not null,
 active boolean not null default true
)
```
Starter codes: MILK, EGGS, WOOL, LIVE_WEIGHT, WEIGHT_GAIN. Growth/weight can be measurement-oriented rather than saleable output.

## 3. production_record
```sql
production_record (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 production_type_id uuid not null references production_type(id),
 occurred_at timestamptz not null,
 period_start timestamptz,
 period_end timestamptz,
 quantity numeric(20,6) not null,
 uom_id uuid not null references uom(id),
 head_count integer,
 quality_status varchar(30),
 disposition_status varchar(30),
 source_type varchar(40) not null,
 source_reference_id uuid,
 recorded_at timestamptz not null,
 recorded_by uuid references user_account(id),
 reversal_of_id uuid references production_record(id),
 correlation_id uuid,
 check (num_nonnulls(animal_id,animal_group_id)=1),
 check (quantity >= 0),
 check (period_end is null or period_start is null or period_end > period_start)
)
```
Capability validation is mandatory. Posted records are corrected by reversal/replacement.

## 4. milk_session
Milk needs richer operational detail without creating a separate Cow entity.
```sql
milk_session (
 id uuid primary key,
 production_record_id uuid not null unique references production_record(id),
 session_code varchar(30),
 milking_method varchar(40),
 withdrawal_restricted boolean not null default false,
 tank_or_destination_location_id uuid references location(id)
)
```
An active MILK withdrawal can mark output restricted/rejected; it does not erase measured production.

## 5. egg_collection
```sql
egg_collection (
 id uuid primary key,
 production_record_id uuid not null unique references production_record(id),
 eggs_count integer not null,
 cracked_count integer default 0,
 rejected_count integer default 0,
 average_weight numeric(20,6),
 weight_uom_id uuid references uom(id),
 check (eggs_count >= 0)
)
```
Typically references AnimalGroup through production_record, but individually tracked layers are also valid if configured.

## 6. wool_harvest
```sql
wool_harvest (
 id uuid primary key,
 production_record_id uuid not null unique references production_record(id),
 grade_code varchar(40),
 moisture_percent numeric(8,4),
 check (moisture_percent is null or moisture_percent between 0 and 100)
)
```

## 7. animal_measurement
General physiological/management measurement separate from commodity production.
```sql
animal_measurement (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid references animal(id),
 animal_group_id uuid references animal_group(id),
 measurement_type varchar(60) not null,
 measured_at timestamptz not null,
 value numeric(20,6) not null,
 uom_id uuid not null references uom(id),
 method_code varchar(50),
 confidence_code varchar(30),
 recorded_by uuid references user_account(id),
 recorded_at timestamptz not null,
 check (num_nonnulls(animal_id,animal_group_id)=1)
)
```
Examples: LIVE_WEIGHT, BODY_CONDITION_SCORE, HEIGHT. Feeding resolver may consume recent measurements without owning them.

## 8. lactation_episode
Lactation is a production state, linked to birth where applicable.
```sql
lactation_episode (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 animal_id uuid not null references animal(id),
 birth_event_id uuid references birth_event(id),
 started_at timestamptz not null,
 ended_at timestamptz,
 status varchar(30) not null,
 lactation_number integer,
 check (ended_at is null or ended_at > started_at)
)
```
Only animals with LACTATION capability may have an episode. Milk production records can reference the effective lactation through a future optional FK/mapping.

**Milk needs an open lactation.** A milk record is accepted only for an animal that is in milk (an active episode): the milking round, days in milk, the peak window and the dry-off plan all read "in milk" from the episode, so milk from an animal recorded as dry would be a second, contradicting idea of who is milked. The server answers 409 with what to do (start her milking); the tablet's milk action asks for that start — with the calving date — and then opens the record. Milk is not dated before the lactation began (correct the calving date instead), sessions are `morning` / `midday` / `evening`, and one milking is at most 100 L.

**Dry-off plan (farm setting).** `farm.dry_off_days_before_birth` (integer, default 60, 0–200; `PATCH /farms/me`, Settings permission) is how many days before an expected birth a lactating animal is dried off. For every active pregnancy the reproduction overview and the animal's reproduction summary expose `dry_off_from = expected_due_date − dry_off_days_before_birth`, `days_to_dry_off`, and `dry_off_due` (in milk and the date has come). It is a plan, never a record: the dry-off is recorded as `LactationEnded` (reason `DRY_OFF`) when milking actually stops. Changing the setting is an audited `farm_settings_changed` event with the old and new value.

**The calendar after a birth (farm settings).** `farm.milk_peak_start_days` (40), `milk_peak_end_days` (70), `breeding_wait_days` (50, the voluntary waiting period) and `heat_cycle_days` (21) — migration `c3e5a7b9d1f4`, Settings → *Breeding & milk calendar*. From the calving that started the current lactation (`lactation_episode.started_at`; else the last recorded birth) the reproduction summary and overview derive: `days_in_milk`, `milk_peak_from/to` and `in_milk_peak`; `breeding_from` and `ready_for_breeding` (not pregnant, past the wait, not served since calving); and, after a service not yet confirmed either way, `heat_watch_from/to` (service + cycle ± 3 days) and `heat_watch_now`. The overview lists who is at her peak, who is ready to inseminate and who to watch for a return to heat — read in a few farm-wide queries, not one summary per animal.

**Calving date.** Registration takes `lactation_started_at` (the calving that started the lactation). A lactation recorded before its calving date was known is corrected with `PATCH /animals/{id}/lactation` (`started_at`, reason) — a `lactation_corrected` event and an audit entry with the old and new date; a lactation a recorded birth started is dated by that birth (409).

## 9. Current metrics projections
Rebuildable projections may expose:
- latest weight;
- milk today / 7d / lactation total;
- eggs today / flock laying rate;
- average daily gain;
- current lactation state.

These are not editable source facts.

## 10. Health/quality interaction
Production recording and product disposition are distinct. A cow under milk withdrawal may still produce 24 L; the record captures 24 L while disposition/quality marks it restricted and prevents sale/eligible tank transfer downstream.

## 11. Events
ProductionRecorded, ProductionCorrected, MilkRecorded, EggCollectionRecorded, WoolHarvestRecorded, AnimalMeasurementRecorded, LactationStarted, LactationEnded, ProductionRestrictionApplied.

## 12. Acceptance
Cattle/sheep/goats can record milk without species-specific tables; poultry groups can record eggs; sheep can record wool; horses can record weight without commodity-production UI; health withdrawal does not falsify production; feeding can consume current production/weight metrics through projections.
