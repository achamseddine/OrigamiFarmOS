"""Reproduction and lactation (database/REPRODUCTION-SCHEMA.md, PRODUCTION-
SCHEMA.md §8, behavioural model §3).

Mammals:  breeding → pregnancy check → pregnancy → birth → offspring
Poultry:  incubation → hatch → chicks into a flock

Invariants this module owns:
- every action is checked against the animal's resolved capabilities
  (BREEDING, PREGNANCY, LIVE_BIRTH, LACTATION, INCUBATION, HATCHING); a hen
  is never offered a pregnancy, a bull never a birth;
- pregnancy is never inferred from a mating — only a positive check opens
  a pregnancy episode, and at most one is active per animal;
- a birth closes the pregnancy, registers individually tracked newborns
  through the normal registration path (identifiers, capabilities) or
  counts them into a flock, links parentage, and starts the dam's next
  lactation where she has one;
- `animals.pregnant`, `pregnancy_days`, `expected_due_date`, `lactating`,
  `lactation_cycle`, `lactation_started_at` and `dried_off_at` are a
  projection refreshed here from the episodes ([refresh_projection]); no
  edit sets them.

Every change that moves what the feeding resolver reads raises a feeding
review (feed architecture §10) and re-reads feed performance (§12) — a
review, never a silent ration change.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.domain import livestock_models as lm
from app.domain import models
from app.domain import reproduction_models as rm
from app.livestock.catalog import Cap
from app.repositories.base import ensure_utc, new_id, now, write_event
from app.services import capability_service
from app.services.livestock_state_service import LivestockError, ensure_on_farm

BREEDING_TYPES = ("HEAT_OBSERVED", "NATURAL_MATING", "ARTIFICIAL_INSEMINATION", "EMBRYO_TRANSFER")
# The breedings that can start a pregnancy (a heat is a sign, not a service).
SERVICE_TYPES = ("NATURAL_MATING", "ARTIFICIAL_INSEMINATION", "EMBRYO_TRANSFER")
ASSESSMENT_TYPES = ("ULTRASOUND", "PALPATION", "BLOOD_TEST", "OBSERVATION")
RESULTS = ("POSITIVE", "NEGATIVE", "INCONCLUSIVE")
LOSS_OUTCOMES = ("LOSS", "ABORTION")
ASSISTANCE_CODES = ("NONE", "EASY", "ASSISTED", "VETERINARY", "CAESAREAN")
OFFSPRING_OUTCOMES = ("LIVE", "STILLBORN", "DIED_AFTER_BIRTH")
MAX_OFFSPRING = 12
# A served female with no check this long after is "awaiting a pregnancy
# check" on the overview — early enough for an ultrasound in every species
# the farm keeps.
CHECK_DUE_AFTER_DAYS = 30
DUE_SOON_DAYS = 21
# Fallback for a pregnancy window when a species has no gestation length.
_DEFAULT_WINDOW_DAYS = 400
# The farm setting `farms.dry_off_days_before_birth` when a farm has none.
DEFAULT_DRY_OFF_DAYS = 60


# ----------------------------------------------------------------- helpers
def _caps(db: Session, animal: models.Animal):
    return capability_service.resolve_for_animal(db, animal)


def _require(db: Session, animal: models.Animal, cap: str):
    cap_set = _caps(db, animal)
    if not cap_set.has(cap):
        raise LivestockError(capability_service.describe_missing(cap_set, cap, animal.name))
    return cap_set


def _female(animal: models.Animal, what: str) -> None:
    if animal.sex != "F":
        raise LivestockError(f"{animal.name} is not recorded as female; {what} is recorded on the female.")


def _when(at: datetime | None, what: str) -> datetime:
    at = ensure_utc(at) if at else now()
    if at > now() + timedelta(minutes=5):
        raise LivestockError(f"{what} cannot be dated in the future.")
    return at


def _species(db: Session, code: str):
    return capability_service.get_species(db, code)


def _gestation_days(db: Session, animal: models.Animal) -> int | None:
    return _species(db, animal.species).gestation_days


def _due(db: Session, animal: models.Animal, conceived: datetime | None) -> datetime | None:
    days = _gestation_days(db, animal)
    return conceived + timedelta(days=days) if conceived is not None and days else None


def _terminology(db: Session, species_code: str) -> dict:
    return _species(db, species_code).terminology_json or {}


def active_pregnancy(db: Session, animal_id: str) -> rm.PregnancyEpisode | None:
    db.flush()
    return db.scalar(select(rm.PregnancyEpisode).where(rm.PregnancyEpisode.animal_id == animal_id, rm.PregnancyEpisode.status == "active")
                     .order_by(rm.PregnancyEpisode.created_at.desc()))


def active_lactation(db: Session, animal_id: str) -> rm.LactationEpisode | None:
    db.flush()
    return db.scalar(select(rm.LactationEpisode).where(rm.LactationEpisode.animal_id == animal_id, rm.LactationEpisode.status == "active")
                     .order_by(rm.LactationEpisode.started_at.desc()))


def _latest_lactation(db: Session, animal_id: str) -> rm.LactationEpisode | None:
    db.flush()
    return db.scalar(select(rm.LactationEpisode).where(rm.LactationEpisode.animal_id == animal_id).order_by(rm.LactationEpisode.started_at.desc()))


def _same_farm_animal(db: Session, animal_id: str | None, farm_id: str, label: str) -> models.Animal | None:
    if not animal_id:
        return None
    other = db.get(models.Animal, animal_id)
    if other is None or other.farm_id != farm_id:
        raise LivestockError(f"{label} not found", 404)
    return other


def _validate_sire(db: Session, female: models.Animal, sire: models.Animal) -> None:
    if sire.id == female.id:
        raise LivestockError("An animal cannot be its own sire.")
    if sire.species != female.species:
        raise LivestockError(f"{sire.name} is a {sire.species.replace('_', ' ')}, {female.name} a {female.species.replace('_', ' ')}.")
    if sire.sex != "M":
        raise LivestockError(f"{sire.name} is not recorded as male.")
    if not _caps(db, sire).has(Cap.BREEDING):
        raise LivestockError(capability_service.describe_missing(_caps(db, sire), Cap.BREEDING, sire.name))


def days_between(start: datetime, end: datetime) -> int:
    """Calendar days, so \"due in 9 days\" does not read 8 by the afternoon."""
    return (ensure_utc(end).date() - ensure_utc(start).date()).days


def days_pregnant(episode: rm.PregnancyEpisode | None, at: datetime | None = None) -> int | None:
    if episode is None or episode.estimated_conception_at is None:
        return None
    return max(0, days_between(episode.estimated_conception_at, at or now()))


def _hooks(db: Session, animal: models.Animal, changed: set[str], *, trigger: str, user_id: str) -> None:
    from app.services import feed_performance_service, feeding_program_service, group_service

    if changed:
        feeding_program_service.review_animal_if_relevant(db, animal, changed, user_id=user_id)
        # Pregnant / open / in-milk / dry groups follow the records.
        group_service.sync_rule_groups(db, animal, user_id=user_id)
    feed_performance_service.on_context_changed(db, "animal", animal, trigger=trigger, user_id=user_id)


# ----------------------------------------------------------------- dry-off
def dry_off_days(db: Session, farm_id: str) -> int:
    """The farm's setting: how many days before an expected birth a
    lactating animal stops being milked."""
    farm = db.get(models.Farm, farm_id)
    days = getattr(farm, "dry_off_days_before_birth", None) if farm is not None else None
    return DEFAULT_DRY_OFF_DAYS if days is None else int(days)


def dry_off_plan(expected_due_date: datetime | None, lactating: bool, days_before: int, at: datetime | None = None) -> dict:
    """When milking should stop ahead of the expected birth. A plan, never
    a record: the dry-off itself is recorded when it happens."""
    if expected_due_date is None:
        return {"dry_off_from": None, "days_to_dry_off": None, "dry_off_due": False}
    start = ensure_utc(expected_due_date) - timedelta(days=days_before)
    days = days_between(at or now(), start)
    return {"dry_off_from": start, "days_to_dry_off": days, "dry_off_due": bool(lactating) and days <= 0}


# ----------------------------------------------------------------- calendar
# Defaults of the farm's calendar settings (farms.milk_peak_start_days …).
DEFAULT_CALENDAR = {"milk_peak_start_days": 40, "milk_peak_end_days": 70, "breeding_wait_days": 50, "heat_cycle_days": 21}
# A return to heat is watched for this many days either side of one cycle.
HEAT_WATCH_MARGIN_DAYS = 3


def farm_calendar(db: Session, farm_id: str) -> dict:
    farm = db.get(models.Farm, farm_id)
    out = dict(DEFAULT_CALENDAR)
    if farm is not None:
        for k in out:
            v = getattr(farm, k, None)
            if v is not None:
                out[k] = int(v)
    out["dry_off_days_before_birth"] = dry_off_days(db, farm_id)
    return out


def calendar_plan(*, calving_at: datetime | None, lactating: bool, pregnant: bool, can_breed: bool,
                  last_service_at: datetime | None, last_check_at: datetime | None, calendar: dict, at: datetime | None = None) -> dict:
    """The working calendar after a birth (Vision: "when should I watch her
    peak, when should she be inseminated"): days in milk, the milk peak
    window, the end of the voluntary waiting period, and — after a service
    not yet confirmed — the days to watch for a return to heat. A plan from
    the farm's settings and the records; it records nothing."""
    at = at or now()
    out = {"calving_at": None, "days_in_milk": None, "milk_peak_from": None, "milk_peak_to": None, "in_milk_peak": False,
           "breeding_from": None, "ready_for_breeding": False, "heat_watch_from": None, "heat_watch_to": None, "heat_watch_now": False}
    if calving_at is not None:
        calved = ensure_utc(calving_at)
        dim = max(0, days_between(calved, at))
        out.update(calving_at=calved, days_in_milk=dim if lactating else None,
                   milk_peak_from=calved + timedelta(days=calendar["milk_peak_start_days"]),
                   milk_peak_to=calved + timedelta(days=calendar["milk_peak_end_days"]),
                   in_milk_peak=lactating and calendar["milk_peak_start_days"] <= dim <= calendar["milk_peak_end_days"])
        if can_breed and not pregnant:
            breeding_from = calved + timedelta(days=calendar["breeding_wait_days"])
            served_since = last_service_at is not None and ensure_utc(last_service_at) >= calved
            out.update(breeding_from=breeding_from, ready_for_breeding=dim >= calendar["breeding_wait_days"] and not served_since)
    if can_breed and not pregnant and last_service_at is not None:
        served = ensure_utc(last_service_at)
        confirmed_after = last_check_at is not None and ensure_utc(last_check_at) >= served
        if not confirmed_after:
            cycle = calendar["heat_cycle_days"]
            start = served + timedelta(days=cycle - HEAT_WATCH_MARGIN_DAYS)
            end = served + timedelta(days=cycle + HEAT_WATCH_MARGIN_DAYS)
            out.update(heat_watch_from=start, heat_watch_to=end, heat_watch_now=start.date() <= at.date() <= end.date())
    return out


def correct_lactation_start(db: Session, animal: models.Animal, *, started_at: datetime, reason: str | None, user: models.User) -> rm.LactationEpisode:
    """The calving / start-of-milking date of the current lactation, corrected
    (it was entered when milking was recorded, before the date was known).
    A correction with its reason and the old value, never a silent edit; a
    lactation that a recorded birth started is dated by that birth."""
    ensure_on_farm(animal, "a lactation correction")
    row = active_lactation(db, animal.id)
    if row is None:
        raise LivestockError(f"{animal.name} is not in milk.", 404)
    if row.birth_event_id:
        raise LivestockError(f"{animal.name}'s lactation started with a recorded birth; correct that birth's date instead.", 409)
    new_at = _when(started_at, "A calving")
    previous_end = db.scalar(select(func.max(rm.LactationEpisode.ended_at)).where(
        rm.LactationEpisode.animal_id == animal.id, rm.LactationEpisode.id != row.id))
    if previous_end is not None and new_at < ensure_utc(previous_end):
        raise LivestockError(f"{animal.name} was dried off on {ensure_utc(previous_end).date().isoformat()}; this lactation cannot start before that.")
    before = _dt(row.started_at)
    row.started_at = new_at
    refresh_projection(db, animal)
    write_event(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type="lactation_corrected",
                payload={"lactation_id": row.id, "started_at": {"from": before.isoformat() if before else None, "to": new_at.isoformat()},
                         "reason": reason}, created_by=user.id)
    from app.repositories.base import write_audit_log

    write_audit_log(db, farm_id=animal.farm_id, user_id=user.id, action="lactation_corrected", entity_type="animal", entity_id=animal.id,
                    module_code="milk_production", changes={"lactation_started_at": {"from": before.isoformat() if before else None, "to": new_at.isoformat()}},
                    summary=f"{user.name} corrected {animal.name}'s calving / start of milking to {new_at.date().isoformat()}")
    _hooks(db, animal, set(), trigger="lifecycle_changed", user_id=user.id)
    return row


# ----------------------------------------------------------------- projection
def refresh_projection(db: Session, animal: models.Animal) -> set[str]:
    """Re-derives the animal's reproduction and lactation fields from the
    episodes. Returns the names of the fields whose value changed."""
    before = {k: getattr(animal, k) for k in ("pregnant", "lactating", "expected_due_date", "lactation_cycle")}
    pregnancy = active_pregnancy(db, animal.id)
    animal.pregnant = pregnancy is not None
    animal.pregnancy_started_at = pregnancy.estimated_conception_at if pregnancy else None
    animal.expected_due_date = pregnancy.expected_due_date if pregnancy else None
    animal.pregnancy_days = days_pregnant(pregnancy)
    lactation = active_lactation(db, animal.id)
    latest = lactation or _latest_lactation(db, animal.id)
    animal.lactating = lactation is not None
    if latest is not None:
        animal.lactation_started_at = latest.started_at
        if latest.lactation_number is not None:
            animal.lactation_cycle = latest.lactation_number
        if latest.ended_at is not None:
            animal.dried_off_at = latest.ended_at
    return {k for k, v in before.items() if getattr(animal, k) != v}


def open_registration_state(db: Session, animal: models.Animal, *, pregnant: bool, pregnancy_days: int | None, lactating: bool,
                            lactation_cycle: int | None, user_id: str, at: datetime | None = None,
                            breeding: rm.BreedingEvent | None = None, lactation_started_at: datetime | None = None) -> None:
    """An animal registered pregnant or in milk — bought in, or already on
    the farm before the app — arrives with the episode that says so, sourced
    "registration", rather than with a bare flag. With the insemination /
    mating it came from ([breeding], recorded first), the pregnancy is dated
    from that service rather than from an estimate."""
    at = ensure_utc(at) if at else now()
    if lactation_cycle is not None and lactation_cycle < 0:
        raise LivestockError("The lactation number cannot be negative.")
    animal.lactation_cycle = lactation_cycle
    if pregnant:
        gestation = _gestation_days(db, animal)
        if breeding is not None:
            pregnancy_days = days_between(breeding.occurred_at, at)
        if pregnancy_days is not None and (pregnancy_days < 0 or (gestation and pregnancy_days > gestation + 30)):
            raise LivestockError(f"{pregnancy_days} days is not a {animal.species.replace('_', ' ')} pregnancy"
                                 + (f" (about {gestation} days)." if gestation else ".")
                                 + (" Check the insemination date." if breeding is not None else ""))
        conceived = ensure_utc(breeding.occurred_at) if breeding is not None else (at - timedelta(days=pregnancy_days) if pregnancy_days is not None else None)
        episode = rm.PregnancyEpisode(id=new_id(), farm_id=animal.farm_id, animal_id=animal.id, status="active", estimated_conception_at=conceived,
                                      originating_breeding_event_id=breeding.id if breeding is not None else None,
                                      expected_due_date=_due(db, animal, conceived), source="registration", created_by=user_id)
        db.add(episode)
        db.add(rm.PregnancyAssessment(id=new_id(), farm_id=animal.farm_id, pregnancy_episode_id=episode.id, animal_id=animal.id, assessed_at=at,
                                      assessment_type="REGISTRATION", result_code="POSITIVE", estimated_gestation_days=pregnancy_days,
                                      expected_due_date=episode.expected_due_date, recorded_by=user_id, notes="Registered pregnant"))
        write_event(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type="pregnancy_confirmed",
                    payload={"episode_id": episode.id, "source": "registration", "expected_due_date": episode.expected_due_date.isoformat() if episode.expected_due_date else None},
                    created_by=user_id)
    if lactating:
        # The calving that started this lactation, when the farmer knows it —
        # days in milk, the peak and the breeding wait are reckoned from it.
        started = _when(lactation_started_at, "A calving") if lactation_started_at else at
        db.add(rm.LactationEpisode(id=new_id(), farm_id=animal.farm_id, animal_id=animal.id, started_at=started, status="active",
                                   lactation_number=lactation_cycle, source="registration", created_by=user_id))
        write_event(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type="lactation_started",
                    payload={"source": "registration", "lactation_number": lactation_cycle, "started_at": started.isoformat()}, created_by=user_id)
    refresh_projection(db, animal)


# ----------------------------------------------------------------- breeding
def record_breeding(db: Session, female: models.Animal, *, event_type: str, at: datetime | None = None, male_animal_id: str | None = None,
                    sire_reference: str | None = None, semen_batch_reference: str | None = None, technician_user_id: str | None = None,
                    notes: str | None = None, user: models.User) -> rm.BreedingEvent:
    if event_type not in BREEDING_TYPES:
        raise LivestockError(f"event_type must be one of {list(BREEDING_TYPES)}")
    ensure_on_farm(female, "breeding")
    _female(female, "a breeding")
    _require(db, female, Cap.BREEDING)
    at = _when(at, "A breeding")
    male = _same_farm_animal(db, male_animal_id, female.farm_id, "Sire")
    if event_type == "HEAT_OBSERVED" and (male or sire_reference or semen_batch_reference):
        raise LivestockError("A heat is a sign seen on the female; record the mating or insemination that follows it separately.")
    if male is not None:
        ensure_on_farm(male, "a mating")
        _validate_sire(db, female, male)
    pregnancy = active_pregnancy(db, female.id)
    if pregnancy is not None:
        raise LivestockError(
            f"{female.name} is recorded pregnant"
            + (f" (due {ensure_utc(pregnancy.expected_due_date).date().isoformat()})" if pregnancy.expected_due_date else "")
            + ". Record a negative pregnancy check or a pregnancy loss first.",
            409,
        )
    if technician_user_id:
        technician = db.get(models.User, technician_user_id)
        if technician is None or technician.farm_id != female.farm_id:
            raise LivestockError("The technician must be someone on this farm.")
    row = rm.BreedingEvent(
        id=new_id(), farm_id=female.farm_id, female_animal_id=female.id, male_animal_id=male.id if male else None,
        sire_reference=(sire_reference or "").strip() or None, event_type=event_type, occurred_at=at,
        semen_batch_reference=(semen_batch_reference or "").strip() or None, technician_user_id=technician_user_id,
        status="recorded", notes=notes, recorded_at=now(), recorded_by=user.id,
    )
    db.add(row)
    write_event(db, farm_id=female.farm_id, entity_type="animal", entity_id=female.id, event_type="breeding_recorded",
                payload={"breeding_id": row.id, "event_type": event_type, "occurred_at": at.isoformat(), "male_animal_id": row.male_animal_id,
                         "sire_reference": row.sire_reference}, created_by=user.id)
    return row


def void_breeding(db: Session, breeding: rm.BreedingEvent, *, reason: str, user: models.User) -> rm.BreedingEvent:
    """A mistaken entry is voided with its reason, never deleted. A
    breeding a pregnancy already rests on stays."""
    if breeding.status == "voided":
        return breeding
    if not reason or not reason.strip():
        raise LivestockError("Say why the breeding record is being voided.")
    used = db.scalar(select(rm.PregnancyEpisode.id).where(rm.PregnancyEpisode.originating_breeding_event_id == breeding.id))
    if used:
        raise LivestockError("A pregnancy is dated from this breeding; correct the pregnancy check instead.", 409)
    breeding.status = "voided"
    breeding.void_reason = reason.strip()
    write_event(db, farm_id=breeding.farm_id, entity_type="animal", entity_id=breeding.female_animal_id, event_type="breeding_voided",
                payload={"breeding_id": breeding.id, "reason": breeding.void_reason}, created_by=user.id)
    return breeding


def _likely_breeding(db: Session, animal: models.Animal, before: datetime) -> rm.BreedingEvent | None:
    """The service a confirmed pregnancy most plausibly comes from: the
    latest mating / insemination before the check, inside one gestation."""
    window = _gestation_days(db, animal) or _DEFAULT_WINDOW_DAYS
    return db.scalar(select(rm.BreedingEvent).where(
        rm.BreedingEvent.female_animal_id == animal.id, rm.BreedingEvent.status == "recorded",
        rm.BreedingEvent.event_type.in_(SERVICE_TYPES), rm.BreedingEvent.occurred_at <= before,
        rm.BreedingEvent.occurred_at >= before - timedelta(days=window + 30),
    ).order_by(rm.BreedingEvent.occurred_at.desc()))


# ----------------------------------------------------------------- pregnancy
def _end_episode(episode: rm.PregnancyEpisode, at: datetime, outcome: str) -> None:
    episode.status = "ended"
    episode.ended_at = at
    episode.outcome_code = outcome


def record_assessment(db: Session, animal: models.Animal, *, assessment_type: str, result_code: str, at: datetime | None = None,
                      estimated_gestation_days: int | None = None, expected_due_date: datetime | None = None,
                      examiner_user_id: str | None = None, notes: str | None = None, user: models.User) -> tuple[rm.PregnancyAssessment, rm.PregnancyEpisode | None]:
    """A pregnancy check. POSITIVE opens the pregnancy (dated from the
    gestation the examiner gives, else from the likely service) or refines
    the open one; NEGATIVE ends an open one; INCONCLUSIVE changes nothing."""
    if assessment_type not in ASSESSMENT_TYPES:
        raise LivestockError(f"assessment_type must be one of {list(ASSESSMENT_TYPES)}")
    if result_code not in RESULTS:
        raise LivestockError(f"result_code must be one of {list(RESULTS)}")
    ensure_on_farm(animal, "a pregnancy check")
    _female(animal, "a pregnancy check")
    _require(db, animal, Cap.PREGNANCY)
    at = _when(at, "A pregnancy check")
    gestation = _gestation_days(db, animal)
    if estimated_gestation_days is not None and (estimated_gestation_days < 0 or (gestation and estimated_gestation_days > gestation + 30)):
        raise LivestockError(f"{estimated_gestation_days} days is not a {animal.species.replace('_', ' ')} pregnancy"
                             + (f" (about {gestation} days)." if gestation else "."))
    if examiner_user_id:
        examiner = db.get(models.User, examiner_user_id)
        if examiner is None or examiner.farm_id != animal.farm_id:
            raise LivestockError("The examiner must be someone on this farm.")
    episode = active_pregnancy(db, animal.id)
    transition = None
    if result_code == "POSITIVE":
        breeding = _likely_breeding(db, animal, at)
        conceived = at - timedelta(days=estimated_gestation_days) if estimated_gestation_days is not None else (breeding.occurred_at if breeding else None)
        due = ensure_utc(expected_due_date) if expected_due_date else _due(db, animal, conceived)
        if episode is None:
            episode = rm.PregnancyEpisode(
                id=new_id(), farm_id=animal.farm_id, animal_id=animal.id, status="active",
                originating_breeding_event_id=breeding.id if breeding else None, estimated_conception_at=conceived,
                expected_due_date=due, source="assessment", created_by=user.id,
            )
            db.add(episode)
            transition = "pregnancy_confirmed"
        else:
            if estimated_gestation_days is not None or episode.estimated_conception_at is None:
                episode.estimated_conception_at = conceived or episode.estimated_conception_at
            if expected_due_date is not None or episode.expected_due_date is None:
                episode.expected_due_date = due or episode.expected_due_date
            if episode.originating_breeding_event_id is None and breeding is not None:
                episode.originating_breeding_event_id = breeding.id
    elif result_code == "NEGATIVE" and episode is not None:
        _end_episode(episode, at, "NOT_PREGNANT")
        transition = "pregnancy_ended"
    assessment = rm.PregnancyAssessment(
        id=new_id(), farm_id=animal.farm_id, pregnancy_episode_id=episode.id if episode else None, animal_id=animal.id,
        assessed_at=at, assessment_type=assessment_type, result_code=result_code, estimated_gestation_days=estimated_gestation_days,
        expected_due_date=episode.expected_due_date if episode and result_code == "POSITIVE" else (ensure_utc(expected_due_date) if expected_due_date else None),
        examiner_user_id=examiner_user_id, notes=notes, recorded_at=now(), recorded_by=user.id,
    )
    db.add(assessment)
    changed = refresh_projection(db, animal)
    write_event(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type="pregnancy_assessment_recorded",
                payload={"assessment_id": assessment.id, "result": result_code, "type": assessment_type}, created_by=user.id)
    if transition:
        write_event(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type=transition,
                    payload={"episode_id": episode.id, "expected_due_date": episode.expected_due_date.isoformat() if episode.expected_due_date else None,
                             "outcome": episode.outcome_code}, created_by=user.id)
    _hooks(db, animal, changed & {"pregnant"}, trigger="lifecycle_changed", user_id=user.id)
    return assessment, (episode if episode is not None and episode.status == "active" else None)


def end_pregnancy(db: Session, animal: models.Animal, *, outcome_code: str, at: datetime | None = None, notes: str | None = None,
                  user: models.User) -> rm.PregnancyEpisode:
    """A pregnancy lost before term. A birth ends a pregnancy through
    [record_birth]; a mistaken confirmation through a negative check."""
    if outcome_code not in LOSS_OUTCOMES:
        raise LivestockError(f"outcome_code must be one of {list(LOSS_OUTCOMES)}")
    ensure_on_farm(animal, "a pregnancy loss")
    episode = active_pregnancy(db, animal.id)
    if episode is None:
        raise LivestockError(f"{animal.name} has no open pregnancy.", 404)
    at = _when(at, "A pregnancy loss")
    _end_episode(episode, at, outcome_code)
    if notes:
        episode.notes = ((episode.notes + "\n") if episode.notes else "") + notes
    changed = refresh_projection(db, animal)
    write_event(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type="pregnancy_ended",
                payload={"episode_id": episode.id, "outcome": outcome_code, "occurred_at": at.isoformat()}, created_by=user.id)
    _hooks(db, animal, changed & {"pregnant"}, trigger="lifecycle_changed", user_id=user.id)
    return episode


# ----------------------------------------------------------------- birth
def record_birth(db: Session, dam: models.Animal, *, offspring: list[dict], at: datetime | None = None, assistance_code: str = "NONE",
                 sire_animal_id: str | None = None, sire_reference: str | None = None, start_lactation: bool = True,
                 notes: str | None = None, user: models.User) -> tuple[rm.BirthEvent, dict]:
    """A calving / lambing / kidding / foaling. One transaction: the birth,
    each newborn (registered, counted into a flock, or recorded stillborn),
    parentage, the end of the pregnancy and the start of the next lactation.
    Any newborn the registration rules refuse refuses the whole birth, with
    the reason — nothing half-recorded."""
    from app.services import group_service

    ensure_on_farm(dam, "a birth")
    _female(dam, "a birth")
    cap_set = _require(db, dam, Cap.LIVE_BIRTH)
    at = _when(at, "A birth")
    if assistance_code not in ASSISTANCE_CODES:
        raise LivestockError(f"assistance_code must be one of {list(ASSISTANCE_CODES)}")
    if not offspring:
        raise LivestockError("A birth records at least one newborn, live or stillborn.")
    if len(offspring) > MAX_OFFSPRING:
        raise LivestockError(f"At most {MAX_OFFSPRING} newborns in one birth.")
    for i, o in enumerate(offspring, start=1):
        if o.get("outcome_code") not in OFFSPRING_OUTCOMES:
            raise LivestockError(f"Newborn {i}: outcome_code must be one of {list(OFFSPRING_OUTCOMES)}")
        if o.get("register_now") and o["outcome_code"] != "LIVE":
            raise LivestockError(f"Newborn {i} is not recorded live, so it cannot be registered.")
        if o.get("register_now") and o.get("destination_group_id"):
            raise LivestockError(f"Newborn {i}: register it as an animal, or count it into a group — not both.")
        if o.get("birth_weight_kg") is not None and o["birth_weight_kg"] < 0:
            raise LivestockError(f"Newborn {i}: a weight cannot be negative.")

    pregnancy = active_pregnancy(db, dam.id)
    breeding = db.get(rm.BreedingEvent, pregnancy.originating_breeding_event_id) if pregnancy and pregnancy.originating_breeding_event_id else None
    sire = _same_farm_animal(db, sire_animal_id, dam.farm_id, "Sire")
    if sire is not None:
        _validate_sire(db, dam, sire)
    elif breeding is not None and breeding.male_animal_id:
        sire = db.get(models.Animal, breeding.male_animal_id)
    sire_ref = (sire_reference or "").strip() or (breeding.sire_reference if breeding else None)

    live = sum(1 for o in offspring if o["outcome_code"] in ("LIVE", "DIED_AFTER_BIRTH"))
    stillborn = sum(1 for o in offspring if o["outcome_code"] == "STILLBORN")
    birth = rm.BirthEvent(
        id=new_id(), farm_id=dam.farm_id, dam_animal_id=dam.id, pregnancy_episode_id=pregnancy.id if pregnancy else None,
        sire_animal_id=sire.id if sire else None, sire_reference=sire_ref, occurred_at=at, assistance_code=assistance_code,
        offspring_count=len(offspring), live_count=live, stillborn_count=stillborn, status="recorded", notes=notes,
        recorded_at=now(), recorded_by=user.id,
    )
    db.add(birth)
    db.flush()
    if pregnancy is not None:
        _end_episode(pregnancy, at, "BIRTH")

    term = _terminology(db, dam.species)
    registered: list[models.Animal] = []
    counted = 0
    for i, o in enumerate(offspring, start=1):
        child = None
        group = None
        if o["outcome_code"] == "LIVE" and o.get("register_now"):
            child = _register_newborn(db, user, dam, sire, birth, o, sequence_no=i, term=term)
            registered.append(child)
        elif o["outcome_code"] == "LIVE" and o.get("destination_group_id"):
            group = db.get(models.Flock, o["destination_group_id"])
            if group is None or group.farm_id != dam.farm_id:
                raise LivestockError(f"Newborn {i}: group not found", 404)
            if group.species != dam.species:
                raise LivestockError(f"Newborn {i}: {group.name} is not a group of {dam.species.replace('_', ' ')}.")
            group_service.record_quantity(db, group, "BIRTH", 1, at=at, reason=f"Born to {dam.name}", source_type="birth_event",
                                          source_id=birth.id, user_id=user.id, correlation_id=birth.id)
            counted += 1
        db.add(rm.BirthOffspring(
            id=new_id(), birth_event_id=birth.id, offspring_animal_id=child.id if child else None, sequence_no=i,
            sex=animal_service_sex(o.get("sex")), birth_weight_kg=o.get("birth_weight_kg"), outcome_code=o["outcome_code"],
            destination_group_id=group.id if group else None, notes=o.get("notes"),
        ))

    lactation = None
    lactation_note = None
    if start_lactation:
        if cap_set.has(Cap.LACTATION):
            previous = active_lactation(db, dam.id)
            if previous is not None:
                previous.status, previous.ended_at, previous.end_reason_code, previous.ended_by = "ended", max(at, ensure_utc(previous.started_at)), "NEW_LACTATION", user.id
            lactation = _start_lactation_row(db, dam, at=at, number=None, birth_event_id=birth.id, user_id=user.id, source="birth")
        else:
            lactation_note = capability_service.describe_missing(cap_set, Cap.LACTATION, dam.name)

    changed = refresh_projection(db, dam)
    write_event(db, farm_id=dam.farm_id, entity_type="animal", entity_id=dam.id, event_type="birth_recorded",
                payload={"birth_id": birth.id, "occurred_at": at.isoformat(), "offspring": len(offspring), "live": live, "stillborn": stillborn,
                         "registered": [c.id for c in registered], "counted_into_groups": counted, "term": term.get("birth_en")},
                created_by=user.id)
    _hooks(db, dam, changed & {"pregnant", "lactating"}, trigger="lifecycle_changed", user_id=user.id)
    return birth, {"registered_offspring_ids": [c.id for c in registered], "counted_into_groups": counted,
                   "lactation_id": lactation.id if lactation else None, "lactation_not_started": lactation_note}


def animal_service_sex(value: str | None) -> str | None:
    from app.schemas.animals import _normalise_sex

    try:
        return _normalise_sex(value)
    except ValueError as exc:
        raise LivestockError(str(exc)) from None


def _register_newborn(db: Session, user: models.User, dam: models.Animal, sire: models.Animal | None, birth: rm.BirthEvent, o: dict,
                      *, sequence_no: int, term: dict) -> models.Animal:
    from app.services import animal_service

    name = (o.get("name") or "").strip() or f"{term.get('offspring_en', 'Offspring')} of {dam.name}" + (f" #{sequence_no}" if birth.offspring_count > 1 else "")
    data = {
        "name": name, "species": dam.species, "sex": animal_service_sex(o.get("sex")), "breed": dam.breed, "breed_id": dam.breed_id,
        "birth_date": birth.occurred_at, "birth_date_estimated": False, "life_stage": o.get("life_stage") or "newborn",
        "management_profile": o.get("management_profile"), "location_label": dam.location_label, "location_id": dam.location_id,
        "weight_kg": o.get("birth_weight_kg"), "group_name": o.get("group_name"), "status": "healthy", "health_score": 100,
        "acquisition_source": "born on farm", "dam_tag": dam.tag, "sire_tag": sire.tag if sire else (birth.sire_reference or None),
        "notes": o.get("notes"),
    }
    from app.schemas.livestock import IdentifierIn

    identifiers = [i if isinstance(i, IdentifierIn) else IdentifierIn(**i) for i in (o.get("identifiers") or [])]
    try:
        child = animal_service.create_animal(db, user, data, identifiers_in=identifiers, tag=o.get("tag"), registered_at=birth.occurred_at,
                                             source="birth", audit_summary=f"{user.name} registered {name}, born to {dam.name}")
    except LivestockError as exc:
        raise LivestockError(f"Newborn {sequence_no}: {exc.message}", exc.status_code) from None
    except Exception as exc:  # noqa: BLE001 - registration's own HTTP refusal, re-worded for the birth
        detail = getattr(exc, "detail", None)
        if detail is None:
            raise
        raise LivestockError(f"Newborn {sequence_no}: {detail}", getattr(exc, "status_code", 422)) from None
    _link_parent(db, dam, child, "DAM_OF", evidence=("birth_event", birth.id), user_id=user.id)
    if sire is not None:
        _link_parent(db, sire, child, "SIRE_OF", evidence=("birth_event", birth.id), user_id=user.id)
    return child


def register_offspring(db: Session, birth: rm.BirthEvent, sequence_no: int, data: dict, *, user: models.User) -> models.Animal:
    """A newborn recorded live but not registered at the birth (no tag at
    hand) is registered later from its birth row — same parentage, same
    birth date."""
    row = db.scalar(select(rm.BirthOffspring).where(rm.BirthOffspring.birth_event_id == birth.id, rm.BirthOffspring.sequence_no == sequence_no))
    if row is None:
        raise LivestockError("Newborn not found on this birth", 404)
    if row.outcome_code != "LIVE":
        raise LivestockError("Only a newborn recorded live can be registered.")
    if row.offspring_animal_id:
        raise LivestockError("This newborn is already registered.", 409)
    if row.destination_group_id:
        raise LivestockError("This newborn was counted into a group; register it from the group instead.", 409)
    dam = db.get(models.Animal, birth.dam_animal_id)
    sire = db.get(models.Animal, birth.sire_animal_id) if birth.sire_animal_id else None
    term = _terminology(db, dam.species)
    child = _register_newborn(db, user, dam, sire, birth, {**data, "sex": data.get("sex") or row.sex, "birth_weight_kg": row.birth_weight_kg},
                              sequence_no=sequence_no, term=term)
    row.offspring_animal_id = child.id
    if data.get("sex"):
        row.sex = animal_service_sex(data["sex"])
    return child


def _link_parent(db: Session, parent: models.Animal, child: models.Animal, relationship_type: str, *, evidence: tuple[str, str] | None,
                 user_id: str, confidence: str = "recorded") -> lm.AnimalRelationship:
    rel = lm.AnimalRelationship(
        id=new_id(), farm_id=child.farm_id, source_animal_id=parent.id, target_animal_id=child.id, relationship_type=relationship_type,
        confidence_code=confidence, evidence_type=evidence[0] if evidence else None, evidence_id=evidence[1] if evidence else None,
        status="active", created_at=now(), created_by=user_id,
    )
    db.add(rel)
    write_event(db, farm_id=child.farm_id, entity_type="animal", entity_id=child.id, event_type="animal_relationship_recorded",
                payload={"relationship_type": relationship_type, "parent_id": parent.id}, created_by=user_id)
    return rel


def record_parent(db: Session, child: models.Animal, parent: models.Animal, relationship_type: str, *, evidence: str | None, user: models.User) -> lm.AnimalRelationship:
    """Parentage entered by hand — an animal bought in with known parents
    on the farm. A birth recorded here links parentage itself."""
    if relationship_type not in ("DAM_OF", "SIRE_OF"):
        raise LivestockError("relationship_type must be DAM_OF or SIRE_OF")
    if parent.id == child.id:
        raise LivestockError("An animal cannot be its own parent.")
    if parent.farm_id != child.farm_id:
        raise LivestockError("Parent not found", 404)
    if parent.species != child.species:
        raise LivestockError(f"{parent.name} and {child.name} are not the same species.")
    if relationship_type == "DAM_OF" and parent.sex != "F" or relationship_type == "SIRE_OF" and parent.sex != "M":
        raise LivestockError(f"{parent.name}'s sex does not match {relationship_type.replace('_OF', '').lower()}.")
    if parent.birth_date and child.birth_date and ensure_utc(parent.birth_date) >= ensure_utc(child.birth_date):
        raise LivestockError(f"{parent.name} was not born before {child.name}.")
    existing = db.scalar(select(lm.AnimalRelationship).where(
        lm.AnimalRelationship.target_animal_id == child.id, lm.AnimalRelationship.relationship_type == relationship_type,
        lm.AnimalRelationship.status == "active",
    ))
    if existing is not None:
        raise LivestockError(f"{child.name} already has a recorded {'dam' if relationship_type == 'DAM_OF' else 'sire'}.", 409)
    return _link_parent(db, parent, child, relationship_type, evidence=("manual", evidence) if evidence else None, user_id=user.id, confidence="stated")


def relationships(db: Session, animal: models.Animal) -> dict:
    db.flush()
    parents = db.execute(select(lm.AnimalRelationship, models.Animal).join(models.Animal, models.Animal.id == lm.AnimalRelationship.source_animal_id)
                         .where(lm.AnimalRelationship.target_animal_id == animal.id, lm.AnimalRelationship.status == "active")).all()
    children = db.execute(select(lm.AnimalRelationship, models.Animal).join(models.Animal, models.Animal.id == lm.AnimalRelationship.target_animal_id)
                          .where(lm.AnimalRelationship.source_animal_id == animal.id, lm.AnimalRelationship.status == "active")
                          .order_by(models.Animal.birth_date.desc())).all()

    def _a(rel, other):
        return {"relationship_id": rel.id, "relationship_type": rel.relationship_type, "animal_id": other.id, "name": other.name, "tag": other.tag,
                "sex": other.sex, "birth_date": other.birth_date, "active": other.active, "confidence": rel.confidence_code,
                "evidence_type": rel.evidence_type, "evidence_id": rel.evidence_id}

    return {
        "dam": next((_a(r, a) for r, a in parents if r.relationship_type == "DAM_OF"), None),
        "sire": next((_a(r, a) for r, a in parents if r.relationship_type == "SIRE_OF"), None),
        "offspring": [_a(r, a) for r, a in children if r.relationship_type in ("DAM_OF", "SIRE_OF")],
    }


# ----------------------------------------------------------------- lactation
def _start_lactation_row(db: Session, animal: models.Animal, *, at: datetime, number: int | None, birth_event_id: str | None, user_id: str,
                         source: str) -> rm.LactationEpisode:
    if number is None:
        previous_max = db.scalar(select(func.max(rm.LactationEpisode.lactation_number)).where(rm.LactationEpisode.animal_id == animal.id))
        number = (previous_max or animal.lactation_cycle or 0) + 1
    row = rm.LactationEpisode(id=new_id(), farm_id=animal.farm_id, animal_id=animal.id, birth_event_id=birth_event_id, started_at=at,
                              status="active", lactation_number=number, source=source, created_by=user_id)
    db.add(row)
    write_event(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type="lactation_started",
                payload={"lactation_id": row.id, "lactation_number": number, "started_at": at.isoformat(), "birth_event_id": birth_event_id},
                created_by=user_id)
    return row


def start_lactation(db: Session, animal: models.Animal, *, at: datetime | None = None, lactation_number: int | None = None,
                    user: models.User) -> rm.LactationEpisode:
    """A lactation started without a recorded birth (an animal bought in
    fresh, a birth before the app). After a recorded birth it starts by
    itself."""
    ensure_on_farm(animal, "a lactation")
    _female(animal, "a lactation")
    _require(db, animal, Cap.LACTATION)
    at = _when(at, "A lactation")
    if active_lactation(db, animal.id) is not None:
        raise LivestockError(f"{animal.name} is already in milk; record the dry-off first.", 409)
    if lactation_number is not None and lactation_number < 1:
        raise LivestockError("The lactation number starts at 1.")
    row = _start_lactation_row(db, animal, at=at, number=lactation_number, birth_event_id=None, user_id=user.id, source="recorded")
    changed = refresh_projection(db, animal)
    _hooks(db, animal, changed & {"lactating"}, trigger="lifecycle_changed", user_id=user.id)
    return row


def end_lactation(db: Session, animal: models.Animal, *, at: datetime | None = None, reason: str = "DRY_OFF", user: models.User) -> rm.LactationEpisode:
    """Dry-off (PRODUCTION-SCHEMA §8 LactationEnded)."""
    ensure_on_farm(animal, "a dry-off")
    row = active_lactation(db, animal.id)
    if row is None:
        raise LivestockError(f"{animal.name} is not in milk.", 404)
    at = _when(at, "A dry-off")
    if at < ensure_utc(row.started_at):
        raise LivestockError(f"This lactation started on {ensure_utc(row.started_at).date().isoformat()}; a dry-off cannot be dated before it.")
    row.status, row.ended_at, row.end_reason_code, row.ended_by = "ended", at, reason, user.id
    changed = refresh_projection(db, animal)
    write_event(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type="lactation_ended",
                payload={"lactation_id": row.id, "lactation_number": row.lactation_number, "ended_at": at.isoformat(), "reason": reason},
                created_by=user.id)
    _hooks(db, animal, changed & {"lactating"}, trigger="lifecycle_changed", user_id=user.id)
    return row


def on_exit(db: Session, animal: models.Animal, *, at: datetime, user_id: str) -> None:
    pregnancy = active_pregnancy(db, animal.id)
    if pregnancy is not None:
        _end_episode(pregnancy, max(at, ensure_utc(pregnancy.created_at)), "ANIMAL_EXITED")
    lactation = active_lactation(db, animal.id)
    if lactation is not None:
        lactation.status, lactation.ended_at, lactation.end_reason_code, lactation.ended_by = "ended", max(at, ensure_utc(lactation.started_at)), "ANIMAL_EXITED", user_id
    refresh_projection(db, animal)


# ----------------------------------------------------------------- incubation
def _species_supports(db: Session, species_code: str, cap: str) -> bool:
    return db.scalar(select(lm.SpeciesCapabilityRule.id).where(
        lm.SpeciesCapabilityRule.species_code == species_code, lm.SpeciesCapabilityRule.capability_code == cap,
        lm.SpeciesCapabilityRule.enabled.is_(True),
    ).limit(1)) is not None


def start_incubation(db: Session, farm_id: str, *, species_code: str, eggs_set: int, at: datetime | None = None, source_group_id: str | None = None,
                     expected_hatch_date: datetime | None = None, code: str | None = None, notes: str | None = None, user: models.User) -> rm.IncubationBatch:
    species = _species(db, species_code)
    if eggs_set is None or eggs_set <= 0:
        raise LivestockError("Set at least one egg.")
    at = _when(at, "An incubation")
    group = None
    if source_group_id:
        group = db.get(models.Flock, source_group_id)
        if group is None or group.farm_id != farm_id:
            raise LivestockError("Source flock not found", 404)
        if group.species != species_code:
            raise LivestockError(f"{group.name} is a flock of {group.species.replace('_', ' ')}, not {species_code.replace('_', ' ')}.")
        cap_set = capability_service.resolve_for_group(db, group)
        if not cap_set.has(Cap.INCUBATION):
            raise LivestockError(capability_service.describe_missing(cap_set, Cap.INCUBATION, group.name))
    elif not _species_supports(db, species_code, Cap.INCUBATION):
        raise LivestockError(f"{species.name_en} are not configured for incubation.")
    code = (code or "").strip() or _next_incubation_code(db, farm_id, at)
    if db.scalar(select(rm.IncubationBatch.id).where(rm.IncubationBatch.farm_id == farm_id, rm.IncubationBatch.code == code)):
        raise LivestockError(f"An incubation batch {code} already exists.", 409)
    due = ensure_utc(expected_hatch_date) if expected_hatch_date else (at + timedelta(days=species.incubation_days) if species.incubation_days else None)
    batch = rm.IncubationBatch(id=new_id(), farm_id=farm_id, species_code=species_code, source_group_id=group.id if group else None, code=code,
                               eggs_set=eggs_set, set_at=at, expected_hatch_date=due, status="incubating", notes=notes, created_by=user.id)
    db.add(batch)
    write_event(db, farm_id=farm_id, entity_type="incubation_batch", entity_id=batch.id, event_type="incubation_started",
                payload={"code": code, "species": species_code, "eggs_set": eggs_set, "expected_hatch_date": due.isoformat() if due else None},
                created_by=user.id)
    return batch


def _next_incubation_code(db: Session, farm_id: str, at: datetime) -> str:
    base = f"INC-{at:%Y%m%d}"
    n = 1
    while db.scalar(select(rm.IncubationBatch.id).where(rm.IncubationBatch.farm_id == farm_id, rm.IncubationBatch.code == f"{base}-{n}")):
        n += 1
    return f"{base}-{n}"


def record_hatch(db: Session, batch: rm.IncubationBatch, *, hatched_live: int, at: datetime | None = None, unhatched: int | None = None,
                 culled: int | None = None, destination_group_id: str | None = None, notes: str | None = None, user: models.User) -> rm.HatchEvent:
    from app.services import group_service

    if batch.status != "incubating":
        raise LivestockError(f"Batch {batch.code} is {batch.status}.", 409)
    if not _species_supports(db, batch.species_code, Cap.HATCHING):
        raise LivestockError(f"{_species(db, batch.species_code).name_en} are not configured for hatching.")
    at = _when(at, "A hatch")
    if at < ensure_utc(batch.set_at):
        raise LivestockError(f"Batch {batch.code} was set on {ensure_utc(batch.set_at).date().isoformat()}; a hatch cannot be dated before it.")
    counts = [hatched_live, unhatched or 0, culled or 0]
    if any(c < 0 for c in counts):
        raise LivestockError("Counts cannot be negative.")
    if sum(counts) > batch.eggs_set:
        raise LivestockError(f"{sum(counts)} accounted for, but {batch.eggs_set} eggs were set.")
    group = None
    if destination_group_id:
        group = db.get(models.Flock, destination_group_id)
        if group is None or group.farm_id != batch.farm_id:
            raise LivestockError("Destination flock not found", 404)
        if group.species != batch.species_code:
            raise LivestockError(f"{group.name} is not a flock of {batch.species_code.replace('_', ' ')}.")
    hatch = rm.HatchEvent(id=new_id(), incubation_batch_id=batch.id, occurred_at=at, hatched_live=hatched_live, unhatched=unhatched, culled=culled,
                          destination_group_id=group.id if group else None, notes=notes, recorded_at=now(), recorded_by=user.id)
    db.add(hatch)
    batch.status = "hatched"
    if group is not None and hatched_live > 0:
        group_service.record_quantity(db, group, "HATCH", hatched_live, at=at, reason=f"Hatched from {batch.code}", source_type="hatch_event",
                                      source_id=hatch.id, user_id=user.id, correlation_id=batch.id)
    write_event(db, farm_id=batch.farm_id, entity_type="incubation_batch", entity_id=batch.id, event_type="hatch_recorded",
                payload={"hatch_id": hatch.id, "hatched_live": hatched_live, "unhatched": unhatched, "culled": culled,
                         "destination_group_id": hatch.destination_group_id}, created_by=user.id)
    return hatch


def cancel_incubation(db: Session, batch: rm.IncubationBatch, *, reason: str, user: models.User) -> rm.IncubationBatch:
    if batch.status != "incubating":
        raise LivestockError(f"Batch {batch.code} is {batch.status}.", 409)
    if not reason or not reason.strip():
        raise LivestockError("Say why the incubation ended without a hatch.")
    batch.status = "failed"
    batch.notes = ((batch.notes + "\n") if batch.notes else "") + reason.strip()
    write_event(db, farm_id=batch.farm_id, entity_type="incubation_batch", entity_id=batch.id, event_type="incubation_failed",
                payload={"reason": reason.strip()}, created_by=user.id)
    return batch


# ----------------------------------------------------------------- reads
def _dt(value):
    return ensure_utc(value) if value is not None else None


def breeding_dict(db: Session, b: rm.BreedingEvent) -> dict:
    male = db.get(models.Animal, b.male_animal_id) if b.male_animal_id else None
    return {"id": b.id, "event_type": b.event_type, "occurred_at": _dt(b.occurred_at), "male_animal_id": b.male_animal_id,
            "male_name": male.name if male else None, "sire_reference": b.sire_reference, "semen_batch_reference": b.semen_batch_reference,
            "technician_user_id": b.technician_user_id, "status": b.status, "void_reason": b.void_reason, "notes": b.notes,
            "recorded_at": _dt(b.recorded_at), "recorded_by": b.recorded_by}


def assessment_dict(a: rm.PregnancyAssessment) -> dict:
    return {"id": a.id, "pregnancy_episode_id": a.pregnancy_episode_id, "assessed_at": _dt(a.assessed_at), "assessment_type": a.assessment_type,
            "result_code": a.result_code, "estimated_gestation_days": a.estimated_gestation_days, "expected_due_date": _dt(a.expected_due_date),
            "examiner_user_id": a.examiner_user_id, "notes": a.notes, "recorded_by": a.recorded_by}


def pregnancy_dict(p: rm.PregnancyEpisode) -> dict:
    due = _dt(p.expected_due_date)
    return {"id": p.id, "status": p.status, "originating_breeding_event_id": p.originating_breeding_event_id,
            "estimated_conception_at": _dt(p.estimated_conception_at), "expected_due_date": due,
            "days_pregnant": days_pregnant(p) if p.status == "active" else None,
            "days_to_due": days_between(now(), due) if due and p.status == "active" else None,
            "ended_at": _dt(p.ended_at), "outcome_code": p.outcome_code, "source": p.source, "notes": p.notes, "created_at": _dt(p.created_at)}


def birth_dict(db: Session, b: rm.BirthEvent) -> dict:
    db.flush()
    rows = db.scalars(select(rm.BirthOffspring).where(rm.BirthOffspring.birth_event_id == b.id).order_by(rm.BirthOffspring.sequence_no)).all()
    out = []
    for o in rows:
        child = db.get(models.Animal, o.offspring_animal_id) if o.offspring_animal_id else None
        group = db.get(models.Flock, o.destination_group_id) if o.destination_group_id else None
        out.append({"id": o.id, "sequence_no": o.sequence_no, "sex": o.sex, "birth_weight_kg": o.birth_weight_kg, "outcome_code": o.outcome_code,
                    "offspring_animal_id": o.offspring_animal_id, "offspring_name": child.name if child else None, "offspring_tag": child.tag if child else None,
                    "destination_group_id": o.destination_group_id, "destination_group_name": group.name if group else None,
                    "registrable": o.outcome_code == "LIVE" and not o.offspring_animal_id and not o.destination_group_id, "notes": o.notes})
    sire = db.get(models.Animal, b.sire_animal_id) if b.sire_animal_id else None
    return {"id": b.id, "dam_animal_id": b.dam_animal_id, "pregnancy_episode_id": b.pregnancy_episode_id, "occurred_at": _dt(b.occurred_at),
            "assistance_code": b.assistance_code, "offspring_count": b.offspring_count, "live_count": b.live_count,
            "stillborn_count": b.stillborn_count, "sire_animal_id": b.sire_animal_id, "sire_name": sire.name if sire else None,
            "sire_reference": b.sire_reference, "notes": b.notes, "offspring": out, "recorded_by": b.recorded_by}


def lactation_dict(lac: rm.LactationEpisode) -> dict:
    end = _dt(lac.ended_at) or now()
    return {"id": lac.id, "lactation_number": lac.lactation_number, "started_at": _dt(lac.started_at), "ended_at": _dt(lac.ended_at),
            "status": lac.status, "days_in_milk": days_between(lac.started_at, end), "birth_event_id": lac.birth_event_id,
            "end_reason_code": lac.end_reason_code, "source": lac.source}


def incubation_dict(db: Session, batch: rm.IncubationBatch) -> dict:
    db.flush()
    hatch = db.scalar(select(rm.HatchEvent).where(rm.HatchEvent.incubation_batch_id == batch.id))
    group = db.get(models.Flock, batch.source_group_id) if batch.source_group_id else None
    due = _dt(batch.expected_hatch_date)
    return {"id": batch.id, "code": batch.code, "species_code": batch.species_code, "source_group_id": batch.source_group_id,
            "source_group_name": group.name if group else None, "eggs_set": batch.eggs_set, "set_at": _dt(batch.set_at),
            "expected_hatch_date": due, "days_to_hatch": days_between(now(), due) if due and batch.status == "incubating" else None,
            "status": batch.status, "notes": batch.notes,
            "hatch": ({"id": hatch.id, "occurred_at": _dt(hatch.occurred_at), "hatched_live": hatch.hatched_live, "unhatched": hatch.unhatched,
                       "culled": hatch.culled, "destination_group_id": hatch.destination_group_id,
                       "hatch_rate_percent": round(100 * hatch.hatched_live / batch.eggs_set, 1)} if hatch else None)}


def summary(db: Session, animal: models.Animal) -> dict:
    """What the Digital Twin's reproduction card shows, and what the
    tablet needs to decide which actions to offer."""
    cap_set = _caps(db, animal)
    pregnancy = active_pregnancy(db, animal.id)
    lactation = active_lactation(db, animal.id)
    last_breeding = db.scalar(select(rm.BreedingEvent).where(rm.BreedingEvent.female_animal_id == animal.id, rm.BreedingEvent.status == "recorded")
                              .order_by(rm.BreedingEvent.occurred_at.desc()))
    last_check = db.scalar(select(rm.PregnancyAssessment).where(rm.PregnancyAssessment.animal_id == animal.id).order_by(rm.PregnancyAssessment.assessed_at.desc()))
    last_birth = db.scalar(select(rm.BirthEvent).where(rm.BirthEvent.dam_animal_id == animal.id).order_by(rm.BirthEvent.occurred_at.desc()))
    births = db.scalar(select(func.count(rm.BirthEvent.id)).where(rm.BirthEvent.dam_animal_id == animal.id)) or 0
    awaiting = (
        pregnancy is None and last_breeding is not None and last_breeding.event_type in SERVICE_TYPES
        and days_between(last_breeding.occurred_at, now()) >= CHECK_DUE_AFTER_DAYS
        and (last_check is None or ensure_utc(last_check.assessed_at) < ensure_utc(last_breeding.occurred_at))
    )
    days_before = dry_off_days(db, animal.farm_id)
    calendar = farm_calendar(db, animal.farm_id)
    calving_at = lactation.started_at if lactation else (last_birth.occurred_at if last_birth else None)
    plan = calendar_plan(
        calving_at=calving_at, lactating=lactation is not None, pregnant=pregnancy is not None,
        can_breed=cap_set.has(Cap.BREEDING) and animal.sex == "F",
        last_service_at=last_breeding.occurred_at if last_breeding and last_breeding.event_type in SERVICE_TYPES else None,
        last_check_at=last_check.assessed_at if last_check else None, calendar=calendar,
    )
    return {
        "calendar": calendar,
        **plan,
        "applies": {"breeding": cap_set.has(Cap.BREEDING) and animal.sex == "F", "pregnancy": cap_set.has(Cap.PREGNANCY),
                    "live_birth": cap_set.has(Cap.LIVE_BIRTH), "lactation": cap_set.has(Cap.LACTATION)},
        "terminology": _terminology(db, animal.species),
        "pregnant": pregnancy is not None,
        "pregnancy": pregnancy_dict(pregnancy) if pregnancy else None,
        "lactation": lactation_dict(lactation) if lactation else None,
        "last_breeding": breeding_dict(db, last_breeding) if last_breeding else None,
        "last_check": assessment_dict(last_check) if last_check else None,
        "last_birth": {"id": last_birth.id, "occurred_at": _dt(last_birth.occurred_at), "live_count": last_birth.live_count,
                       "offspring_count": last_birth.offspring_count} if last_birth else None,
        "births_count": births,
        "awaiting_pregnancy_check": awaiting,
        "lactation_number": animal.lactation_cycle,
        "dry_off_days_before_birth": days_before,
        **dry_off_plan(pregnancy.expected_due_date if pregnancy else None, lactation is not None, days_before),
    }


def timeline(db: Session, animal: models.Animal) -> dict:
    db.flush()
    return {
        "animal_id": animal.id,
        "summary": summary(db, animal),
        "breedings": [breeding_dict(db, b) for b in db.scalars(select(rm.BreedingEvent).where(rm.BreedingEvent.female_animal_id == animal.id)
                                                                 .order_by(rm.BreedingEvent.occurred_at.desc()))],
        "assessments": [assessment_dict(a) for a in db.scalars(select(rm.PregnancyAssessment).where(rm.PregnancyAssessment.animal_id == animal.id)
                                                                .order_by(rm.PregnancyAssessment.assessed_at.desc()))],
        "pregnancies": [pregnancy_dict(p) for p in db.scalars(select(rm.PregnancyEpisode).where(rm.PregnancyEpisode.animal_id == animal.id)
                                                              .order_by(rm.PregnancyEpisode.created_at.desc()))],
        "births": [birth_dict(db, b) for b in db.scalars(select(rm.BirthEvent).where(rm.BirthEvent.dam_animal_id == animal.id)
                                                         .order_by(rm.BirthEvent.occurred_at.desc()))],
        "lactations": [lactation_dict(lac) for lac in db.scalars(select(rm.LactationEpisode).where(rm.LactationEpisode.animal_id == animal.id)
                                                                 .order_by(rm.LactationEpisode.started_at.desc()))],
        "relationships": relationships(db, animal),
    }


def overview(db: Session, farm_id: str) -> dict:
    """The farm's reproduction day (Vision: "Which cows, goats or sheep
    are ready for breeding?"): who is due, who is waiting for a check, who
    is in milk and at their peak, who is past the waiting period and ready
    to inseminate, who to watch for a return to heat, what is in the
    incubator.

    Read in a handful of farm-wide queries — the episodes, the latest
    service, check and birth per animal — never one summary per animal."""
    db.flush()
    at = now()
    animals = {a.id: a for a in db.scalars(select(models.Animal).where(models.Animal.farm_id == farm_id, models.Animal.active.is_(True)))}

    def _brief(a: models.Animal, **extra) -> dict:
        return {"animal_id": a.id, "name": a.name, "tag": a.tag, "species": a.species, **extra}

    calendar = farm_calendar(db, farm_id)
    days_before = calendar["dry_off_days_before_birth"]
    pregnancies = {p.animal_id: p for p in db.scalars(select(rm.PregnancyEpisode).where(
        rm.PregnancyEpisode.farm_id == farm_id, rm.PregnancyEpisode.status == "active").order_by(rm.PregnancyEpisode.created_at))}
    lactations = {l.animal_id: l for l in db.scalars(select(rm.LactationEpisode).where(
        rm.LactationEpisode.farm_id == farm_id, rm.LactationEpisode.status == "active").order_by(rm.LactationEpisode.started_at))}
    last_breeding: dict[str, rm.BreedingEvent] = {}
    for b in db.scalars(select(rm.BreedingEvent).where(rm.BreedingEvent.farm_id == farm_id, rm.BreedingEvent.status == "recorded")
                        .order_by(rm.BreedingEvent.occurred_at)):
        last_breeding[b.female_animal_id] = b
    last_check: dict[str, rm.PregnancyAssessment] = {}
    for c in db.scalars(select(rm.PregnancyAssessment).where(rm.PregnancyAssessment.farm_id == farm_id).order_by(rm.PregnancyAssessment.assessed_at)):
        last_check[c.animal_id] = c
    last_birth: dict[str, rm.BirthEvent] = {}
    for b in db.scalars(select(rm.BirthEvent).where(rm.BirthEvent.farm_id == farm_id).order_by(rm.BirthEvent.occurred_at)):
        last_birth[b.dam_animal_id] = b

    # Breeding capability per resolver input, not per animal.
    can_breed_cache: dict[tuple, bool] = {}

    def can_breed(a: models.Animal) -> bool:
        key = (a.species, a.sex, a.life_stage, a.management_profile)
        if key not in can_breed_cache:
            can_breed_cache[key] = a.sex == "F" and capability_service.resolve(db, *key).has(Cap.BREEDING)
        return can_breed_cache[key]

    due = []
    for animal_id, p in pregnancies.items():
        a = animals.get(animal_id)
        if a is None:
            continue
        due_date = _dt(p.expected_due_date)
        days = days_between(at, due_date) if due_date else None
        due.append(_brief(a, expected_due_date=due_date, days_to_due=days, days_pregnant=days_pregnant(p),
                          due_soon=days is not None and days <= DUE_SOON_DAYS, overdue=days is not None and days < 0,
                          lactating=bool(a.lactating), **dry_off_plan(due_date, bool(a.lactating), days_before, at)))
    due.sort(key=lambda r: (r["days_to_due"] is None, r["days_to_due"] if r["days_to_due"] is not None else 0))

    awaiting, peak, ready, heat = [], [], [], []
    for a in animals.values():
        if a.sex != "F":
            continue
        b = last_breeding.get(a.id)
        c = last_check.get(a.id)
        lac = lactations.get(a.id)
        pregnant = a.id in pregnancies
        service = b if b is not None and b.event_type in SERVICE_TYPES else None
        if (not pregnant and service is not None and days_between(service.occurred_at, at) >= CHECK_DUE_AFTER_DAYS
                and (c is None or ensure_utc(c.assessed_at) < ensure_utc(service.occurred_at))):
            awaiting.append(_brief(a, last_breeding_at=_dt(service.occurred_at), days_since_breeding=days_between(service.occurred_at, at)))
        birth = last_birth.get(a.id)
        calving = lac.started_at if lac else (birth.occurred_at if birth else None)
        if calving is None and service is None:
            continue
        plan = calendar_plan(calving_at=calving, lactating=lac is not None, pregnant=pregnant, can_breed=can_breed(a),
                             last_service_at=service.occurred_at if service else None, last_check_at=c.assessed_at if c else None,
                             calendar=calendar, at=at)
        if plan["in_milk_peak"]:
            peak.append(_brief(a, days_in_milk=plan["days_in_milk"], milk_peak_to=plan["milk_peak_to"]))
        if plan["ready_for_breeding"]:
            ready.append(_brief(a, days_since_calving=days_between(plan["calving_at"], at), breeding_from=plan["breeding_from"]))
        if plan["heat_watch_now"]:
            heat.append(_brief(a, last_service_at=_dt(service.occurred_at), heat_watch_to=plan["heat_watch_to"]))

    recent = []
    for b in db.scalars(select(rm.BirthEvent).where(rm.BirthEvent.farm_id == farm_id, rm.BirthEvent.occurred_at >= at - timedelta(days=30))
                        .order_by(rm.BirthEvent.occurred_at.desc())):
        dam = animals.get(b.dam_animal_id) or db.get(models.Animal, b.dam_animal_id)
        recent.append({"birth_id": b.id, "dam_animal_id": b.dam_animal_id, "dam_name": dam.name if dam else None, "occurred_at": _dt(b.occurred_at),
                       "live_count": b.live_count, "offspring_count": b.offspring_count})
    in_milk = [a for a in animals.values() if a.lactating]
    incubations = [incubation_dict(db, b) for b in db.scalars(select(rm.IncubationBatch).where(
        rm.IncubationBatch.farm_id == farm_id, rm.IncubationBatch.status == "incubating").order_by(rm.IncubationBatch.expected_hatch_date))]
    return {
        "pregnant": due,
        "due_soon_count": sum(1 for r in due if r["due_soon"]),
        "awaiting_pregnancy_check": awaiting,
        "recent_births": recent,
        "in_milk_count": len(in_milk),
        "incubations": incubations,
        "check_due_after_days": CHECK_DUE_AFTER_DAYS,
        "due_soon_days": DUE_SOON_DAYS,
        "dry_off_days_before_birth": days_before,
        "dry_off_due_count": sum(1 for r in due if r["dry_off_due"]),
        "calendar": calendar,
        "in_milk_peak": sorted(peak, key=lambda r: r["days_in_milk"] or 0),
        "ready_for_breeding": sorted(ready, key=lambda r: -(r["days_since_calving"] or 0)),
        "heat_watch": heat,
    }
