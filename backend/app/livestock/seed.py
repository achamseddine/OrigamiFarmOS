"""The demo farm's livestock records (LIVESTOCK-SCHEMA, REPRODUCTION-SCHEMA).

The animals in `app/seed.py` arrive with the state a farm states on day
one — Bella pregnant 120 days, five animals in milk, herd names. This turns
that state into the records it stands for, the way the migration does for
a live database, and adds the history a working farm would have behind it:

- every animal's opening state history;
- the herds as first-class groups with memberships (the Dairy Herd the feed
  seed created, Goat Group B, Sheep Group A), and the flocks' head-count
  ledgers (Layer and Duck flocks hybrid, the Turkey flock counted);
- Bella's insemination, positive scan and open pregnancy; Luna's calving 90
  days ago with a heifer calf still to be registered, and the lactation it
  started; the other lactations; Daisy served a month ago and awaiting a
  pregnancy check; a hatching batch in the incubator.

Rows are written directly, not through the services: the services raise
feeding reviews and feed-performance re-reads, which belong to live
changes, not to the history of a demo farm.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import livestock_models as lm
from app.domain import models
from app.domain import reproduction_models as rm
from app.services import livestock_state_service, reproduction_service

SEEDER = "user-rami"


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _ago(days: int, hour: int = 8) -> datetime:
    return (_now() - timedelta(days=days)).replace(hour=hour, minute=0, second=0, microsecond=0)


def seed_livestock_demo_data(db: Session, farm_id: str) -> None:
    animals = {a.id: a for a in db.scalars(select(models.Animal).where(models.Animal.farm_id == farm_id))}

    # ---------------------------------------------------------------- history
    for a in animals.values():
        registered = a.birth_date if a.birth_date is not None else _ago(400)
        livestock_state_service.open_initial(db, a, at=registered, user_id=SEEDER)

    # ---------------------------------------------------------------- groups
    herds = {
        "Dairy Herd": db.get(models.Flock, "grp-dairy-herd"),
        "Goat Group B": models.Flock(id="grp-goat-b", farm_id=farm_id, name="Goat Group B", species="goat", group_type="herd",
                                     sex_composition="female", life_stage="adult", status="healthy", location_label="Hillside Paddock"),
        "Sheep Group A": models.Flock(id="grp-sheep-a", farm_id=farm_id, name="Sheep Group A", species="sheep", group_type="flock",
                                      sex_composition="female", life_stage="adult", status="healthy", location_label="Meadow Field"),
    }
    for name, herd in herds.items():
        if herd is None:
            continue
        herd.tracking_mode = "MEMBERSHIP_DERIVED"
        herd.created_at = _ago(365)
        db.add(herd)
    db.flush()
    flocks = {f.name: f for f in db.scalars(select(models.Flock).where(models.Flock.farm_id == farm_id))}
    for a in animals.values():
        group = flocks.get(a.group_name or "")
        if group is None or group.species != a.species:
            continue
        db.add(lm.AnimalGroupMembership(farm_id=farm_id, animal_group_id=group.id, animal_id=a.id, valid_from=_ago(300),
                                        reason_code="opening_state", created_by=SEEDER))
    db.flush()
    for herd in herds.values():
        if herd is not None:
            herd.count = len([a for a in animals.values() if a.group_name == herd.name and a.species == herd.species])

    # The flocks' head-count ledgers: an opening count and the losses since,
    # ending at today's count.
    ledgers = {
        "flock-layer": [("INITIAL_COUNT", 2470, 60, "Placed from the rearing house"), ("DEATH", -14, 30, "Heat stress"), ("DEATH", -6, 9, "Found dead in house 2")],
        "flock-duck": [("INITIAL_COUNT", 690, 60, "Opening count"), ("SALE", -10, 20, "Sold live at the Saturday market")],
        "flock-turkey": [("INITIAL_COUNT", 120, 45, "Opening count")],
    }
    for flock_id, rows in ledgers.items():
        flock = db.get(models.Flock, flock_id)
        if flock is None:
            continue
        has_individuals = any(a.group_name == flock.name and a.species == flock.species for a in animals.values())
        flock.tracking_mode = "HYBRID" if has_individuals else "QUANTITY_MANAGED"
        flock.created_at = _ago(60)
        running = 0
        for event_type, delta, days, reason in rows:
            running += delta
            db.add(lm.AnimalGroupQuantityEvent(farm_id=farm_id, animal_group_id=flock.id, event_type=event_type, quantity_delta=delta,
                                               resulting_quantity=running, occurred_at=_ago(days), reason=reason, source_type="manual",
                                               recorded_at=_ago(days, hour=17), recorded_by="user-worker-1"))
        flock.count = running

    # ---------------------------------------------------------------- reproduction
    bella, luna = animals.get("cow-744"), animals.get("cow-214")
    if bella is not None:
        ai = rm.BreedingEvent(farm_id=farm_id, female_animal_id=bella.id, sire_reference="Holstein AI sire HOL-4471", event_type="ARTIFICIAL_INSEMINATION",
                              occurred_at=_ago(120), semen_batch_reference="LOT 4471-22", technician_user_id="user-vet-1", status="recorded",
                              recorded_at=_ago(120, hour=10), recorded_by="user-vet-1")
        db.add(ai)
        db.flush()
        pregnancy = rm.PregnancyEpisode(farm_id=farm_id, animal_id=bella.id, originating_breeding_event_id=ai.id, status="active",
                                        estimated_conception_at=_ago(120), expected_due_date=_ago(120) + timedelta(days=283), source="assessment",
                                        created_at=_ago(85), created_by="user-vet-1")
        db.add(pregnancy)
        db.flush()
        db.add(rm.PregnancyAssessment(farm_id=farm_id, pregnancy_episode_id=pregnancy.id, animal_id=bella.id, assessed_at=_ago(85),
                                      assessment_type="ULTRASOUND", result_code="POSITIVE", estimated_gestation_days=35,
                                      expected_due_date=pregnancy.expected_due_date, examiner_user_id="user-vet-1",
                                      notes="Single foetus, normal heartbeat.", recorded_at=_ago(85, hour=11), recorded_by="user-vet-1"))
        db.add(rm.LactationEpisode(farm_id=farm_id, animal_id=bella.id, started_at=_ago(200), status="active", lactation_number=2,
                                   source="registration", created_by=SEEDER))
    if luna is not None:
        previous = rm.PregnancyEpisode(farm_id=farm_id, animal_id=luna.id, status="ended", estimated_conception_at=_ago(373),
                                       expected_due_date=_ago(90), ended_at=_ago(90, hour=5), outcome_code="BIRTH", source="assessment",
                                       created_at=_ago(330), created_by="user-vet-1")
        db.add(previous)
        db.flush()
        calving = rm.BirthEvent(farm_id=farm_id, dam_animal_id=luna.id, pregnancy_episode_id=previous.id, sire_reference="Holstein AI sire HOL-3920",
                                occurred_at=_ago(90, hour=5), assistance_code="EASY", offspring_count=1, live_count=1, stillborn_count=0,
                                status="recorded", notes="Heifer calf, up and suckling within the hour.", recorded_at=_ago(90, hour=9),
                                recorded_by="user-worker-1")
        db.add(calving)
        db.flush()
        db.add(rm.BirthOffspring(birth_event_id=calving.id, sequence_no=1, sex="F", birth_weight_kg=38, outcome_code="LIVE",
                                 notes="Awaiting her ear tag."))
        db.add(rm.LactationEpisode(farm_id=farm_id, animal_id=luna.id, birth_event_id=calving.id, started_at=_ago(90, hour=5), status="active",
                                   lactation_number=3, source="birth", created_by="user-worker-1"))
    for animal_id, days, number in (("cow-clover", 150, 1), ("goat-willow", 60, 2), ("goat-gigi", 45, 1)):
        if animal_id in animals:
            db.add(rm.LactationEpisode(farm_id=farm_id, animal_id=animal_id, started_at=_ago(days), status="active", lactation_number=number,
                                       source="registration", created_by=SEEDER))
    daisy = animals.get("sheep-s045")
    if daisy is not None:
        db.add(rm.BreedingEvent(farm_id=farm_id, female_animal_id=daisy.id, sire_reference="Awassi ram (neighbour's)", event_type="NATURAL_MATING",
                                occurred_at=_ago(35), status="recorded", recorded_at=_ago(35, hour=18), recorded_by="user-worker-1"))

    db.add(rm.IncubationBatch(farm_id=farm_id, species_code="layer_hen", code="INC-DEMO-01", eggs_set=150, set_at=_ago(12),
                              expected_hatch_date=_ago(12) + timedelta(days=21), status="incubating",
                              notes="Fertile eggs bought in from the Zahle hatchery.", created_by="user-worker-1"))
    db.flush()
    for a in animals.values():
        reproduction_service.refresh_projection(db, a)
