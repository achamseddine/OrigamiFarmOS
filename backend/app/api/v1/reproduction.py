"""Reproduction and lactation endpoints (database/REPRODUCTION-SCHEMA.md,
PRODUCTION-SCHEMA.md §8, generic animal model §5).

Every write is checked against the animal's resolved capabilities by
`services/reproduction_service.py`; the tablet offers the same actions from
the same `summary.applies` flags, but hiding a button is never the guard.
Responses carry the animal's refreshed reproduction summary so a screen
can redraw from one call.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import owned_or_404, require_any_permission, require_permission
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.domain import reproduction_models as rm
from app.schemas.reproduction import (
    BirthIn,
    BreedingIn,
    BreedingVoidIn,
    DryOffIn,
    HatchIn,
    IncubationCancelIn,
    IncubationIn,
    LactationStartIn,
    OffspringRegisterIn,
    PregnancyCheckIn,
    PregnancyLossIn,
)
from app.services import reproduction_service as repro
from app.services.livestock_state_service import LivestockError

router = APIRouter(tags=["reproduction"])

_VIEW = require_any_permission(perms.ANIMALS, perms.ANIMAL_HEALTH, perms.MILK_PRODUCTION, perms.FEED_NUTRITION, perms.EGG_PRODUCTION)
# Breeding, checks and births are recorded by whoever looks after the
# animals; a pregnancy check is often the veterinarian's.
_RECORD = require_any_permission(perms.ANIMALS, perms.ANIMAL_HEALTH, action=perms.CREATE)
_LACTATION = require_any_permission(perms.ANIMALS, perms.MILK_PRODUCTION, action=perms.CREATE)
_CORRECT = require_permission(perms.ANIMALS, perms.EDIT)
_INCUBATION = require_any_permission(perms.ANIMALS, perms.EGG_PRODUCTION, action=perms.CREATE)


def _animal(db: Session, animal_id: str, user: models.User) -> models.Animal:
    return owned_or_404(db, models.Animal, animal_id, user, "Animal")


def _summary(db: Session, animal: models.Animal) -> dict:
    return repro.summary(db, animal)


# ----------------------------------------------------------------- reads
@router.get("/animals/{animal_id}/reproduction")
def reproduction_record(animal_id: str, db: Session = Depends(get_db), user: models.User = Depends(_VIEW)) -> dict:
    """The animal's whole reproductive life: services, checks, pregnancies,
    births with their newborns, lactations and recorded parentage."""
    return repro.timeline(db, _animal(db, animal_id, user))


@router.get("/reproduction/overview")
def reproduction_overview(db: Session = Depends(get_db), user: models.User = Depends(_VIEW)) -> dict:
    """Who is due, who is waiting for a pregnancy check, recent births, how
    many are in milk and what is in the incubator."""
    return repro.overview(db, user.farm_id)


# ----------------------------------------------------------------- breeding
@router.post("/animals/{animal_id}/breedings", status_code=status.HTTP_201_CREATED)
def record_breeding(animal_id: str, payload: BreedingIn, db: Session = Depends(get_db), user: models.User = Depends(_RECORD)) -> dict:
    animal = _animal(db, animal_id, user)
    row = repro.record_breeding(db, animal, event_type=payload.event_type, at=payload.occurred_at, male_animal_id=payload.male_animal_id,
                                sire_reference=payload.sire_reference, semen_batch_reference=payload.semen_batch_reference,
                                technician_user_id=payload.technician_user_id, notes=payload.notes, user=user)
    db.commit()
    return {"breeding": repro.breeding_dict(db, row), "summary": _summary(db, animal)}


@router.post("/animals/{animal_id}/breedings/{breeding_id}/void")
def void_breeding(animal_id: str, breeding_id: str, payload: BreedingVoidIn, db: Session = Depends(get_db), user: models.User = Depends(_CORRECT)) -> dict:
    animal = _animal(db, animal_id, user)
    row = db.get(rm.BreedingEvent, breeding_id)
    if row is None or row.female_animal_id != animal.id:
        raise LivestockError("Breeding record not found", 404)
    repro.void_breeding(db, row, reason=payload.reason, user=user)
    db.commit()
    return {"breeding": repro.breeding_dict(db, row), "summary": _summary(db, animal)}


# ----------------------------------------------------------------- pregnancy
@router.post("/animals/{animal_id}/pregnancy-checks", status_code=status.HTTP_201_CREATED)
def record_pregnancy_check(animal_id: str, payload: PregnancyCheckIn, db: Session = Depends(get_db), user: models.User = Depends(_RECORD)) -> dict:
    animal = _animal(db, animal_id, user)
    assessment, episode = repro.record_assessment(
        db, animal, assessment_type=payload.assessment_type, result_code=payload.result_code, at=payload.assessed_at,
        estimated_gestation_days=payload.estimated_gestation_days, expected_due_date=payload.expected_due_date,
        examiner_user_id=payload.examiner_user_id, notes=payload.notes, user=user,
    )
    db.commit()
    return {"assessment": repro.assessment_dict(assessment), "pregnancy": repro.pregnancy_dict(episode) if episode else None,
            "summary": _summary(db, animal)}


@router.post("/animals/{animal_id}/pregnancy-loss")
def record_pregnancy_loss(animal_id: str, payload: PregnancyLossIn, db: Session = Depends(get_db), user: models.User = Depends(_RECORD)) -> dict:
    animal = _animal(db, animal_id, user)
    episode = repro.end_pregnancy(db, animal, outcome_code=payload.outcome_code, at=payload.occurred_at, notes=payload.notes, user=user)
    db.commit()
    return {"pregnancy": repro.pregnancy_dict(episode), "summary": _summary(db, animal)}


# ----------------------------------------------------------------- birth
@router.post("/animals/{animal_id}/births", status_code=status.HTTP_201_CREATED)
def record_birth(animal_id: str, payload: BirthIn, db: Session = Depends(get_db), user: models.User = Depends(_RECORD)) -> dict:
    """A calving / lambing / kidding / foaling. Newborns marked
    `register_now` become animals in the same transaction — with the
    identifiers their species requires — and any refusal refuses the birth."""
    dam = _animal(db, animal_id, user)
    birth, extra = repro.record_birth(
        db, dam, offspring=[o.model_dump() for o in payload.offspring], at=payload.occurred_at, assistance_code=payload.assistance_code,
        sire_animal_id=payload.sire_animal_id, sire_reference=payload.sire_reference, start_lactation=payload.start_lactation,
        notes=payload.notes, user=user,
    )
    db.commit()
    return {"birth": repro.birth_dict(db, birth), **extra, "summary": _summary(db, dam)}


@router.post("/births/{birth_id}/offspring/{sequence_no}/register", status_code=status.HTTP_201_CREATED)
def register_offspring(birth_id: str, sequence_no: int, payload: OffspringRegisterIn, db: Session = Depends(get_db), user: models.User = Depends(_RECORD)) -> dict:
    birth = db.get(rm.BirthEvent, birth_id)
    if birth is None or birth.farm_id != user.farm_id:
        raise LivestockError("Birth not found", 404)
    child = repro.register_offspring(db, birth, sequence_no, payload.model_dump(), user=user)
    db.commit()
    return {"birth": repro.birth_dict(db, birth), "offspring_animal_id": child.id}


# ----------------------------------------------------------------- lactation
@router.post("/animals/{animal_id}/lactations", status_code=status.HTTP_201_CREATED)
def start_lactation(animal_id: str, payload: LactationStartIn, db: Session = Depends(get_db), user: models.User = Depends(_LACTATION)) -> dict:
    """A lactation that did not start from a recorded birth. After a
    recorded birth the dam's lactation starts by itself."""
    animal = _animal(db, animal_id, user)
    row = repro.start_lactation(db, animal, at=payload.started_at, lactation_number=payload.lactation_number, user=user)
    db.commit()
    return {"lactation": repro.lactation_dict(row), "summary": _summary(db, animal)}


@router.post("/animals/{animal_id}/dry-off")
def dry_off(animal_id: str, payload: DryOffIn, db: Session = Depends(get_db), user: models.User = Depends(_LACTATION)) -> dict:
    animal = _animal(db, animal_id, user)
    row = repro.end_lactation(db, animal, at=payload.ended_at, user=user)
    db.commit()
    return {"lactation": repro.lactation_dict(row), "summary": _summary(db, animal)}


# ----------------------------------------------------------------- incubation
def _batch(db: Session, batch_id: str, user: models.User) -> rm.IncubationBatch:
    batch = db.get(rm.IncubationBatch, batch_id)
    if batch is None or batch.farm_id != user.farm_id:
        raise LivestockError("Incubation batch not found", 404)
    return batch


@router.get("/incubations")
def list_incubations(status_filter: str | None = None, db: Session = Depends(get_db), user: models.User = Depends(_VIEW)) -> list[dict]:
    stmt = select(rm.IncubationBatch).where(rm.IncubationBatch.farm_id == user.farm_id)
    if status_filter:
        stmt = stmt.where(rm.IncubationBatch.status == status_filter)
    return [repro.incubation_dict(db, b) for b in db.scalars(stmt.order_by(rm.IncubationBatch.set_at.desc()))]


@router.post("/incubations", status_code=status.HTTP_201_CREATED)
def start_incubation(payload: IncubationIn, db: Session = Depends(get_db), user: models.User = Depends(_INCUBATION)) -> dict:
    batch = repro.start_incubation(db, user.farm_id, species_code=payload.species_code, eggs_set=payload.eggs_set, at=payload.set_at,
                                   source_group_id=payload.source_group_id, expected_hatch_date=payload.expected_hatch_date,
                                   code=payload.code, notes=payload.notes, user=user)
    db.commit()
    return repro.incubation_dict(db, batch)


@router.post("/incubations/{batch_id}/hatch")
def record_hatch(batch_id: str, payload: HatchIn, db: Session = Depends(get_db), user: models.User = Depends(_INCUBATION)) -> dict:
    """The hatch: live chicks counted into the destination flock's ledger."""
    batch = _batch(db, batch_id, user)
    repro.record_hatch(db, batch, hatched_live=payload.hatched_live, at=payload.occurred_at, unhatched=payload.unhatched, culled=payload.culled,
                       destination_group_id=payload.destination_group_id, notes=payload.notes, user=user)
    db.commit()
    return repro.incubation_dict(db, batch)


@router.post("/incubations/{batch_id}/cancel")
def cancel_incubation(batch_id: str, payload: IncubationCancelIn, db: Session = Depends(get_db), user: models.User = Depends(_INCUBATION)) -> dict:
    batch = _batch(db, batch_id, user)
    repro.cancel_incubation(db, batch, reason=payload.reason, user=user)
    db.commit()
    return repro.incubation_dict(db, batch)
