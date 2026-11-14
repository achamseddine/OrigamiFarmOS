from __future__ import annotations

from fastapi import APIRouter, Depends, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import ensure_any_permission, ensure_farm_user, ensure_own_farm, get_current_user, owned_or_404, require_farm_access
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.repositories.base import new_id, now, write_event
from app.schemas.observations import ObservationCreate, ObservationOut
from app.services import emergency_service
from app.services import health_case_service as cases

router = APIRouter(prefix="/observations", tags=["observations"])

# What an observation is about decides who may record it: the record
# sheet offers "observe" to Animals and Animal Health; a field belongs to
# Agriculture.
_SUBJECTS = {
    "animal": (models.Animal, "Animal", (perms.ANIMALS, perms.ANIMAL_HEALTH)),
    "flock": (models.Flock, "Flock", (perms.ANIMALS, perms.ANIMAL_HEALTH)),
    "field": (models.Field, "Field", (perms.AGRICULTURE, perms.PRODUCE_HARVEST)),
}
_OBSERVATIONS_VIEW = require_farm_access(perms.ANIMALS, perms.ANIMAL_HEALTH, perms.AGRICULTURE)


@router.get("", response_model=list[ObservationOut])
def list_observations(
    entity_type: str | None = None, entity_id: str | None = None, db: Session = Depends(get_db), user: models.User = Depends(_OBSERVATIONS_VIEW)
) -> list[models.Observation]:
    stmt = select(models.Observation).where(models.Observation.farm_id == user.farm_id)
    if entity_type:
        stmt = stmt.where(models.Observation.entity_type == entity_type)
    if entity_id:
        stmt = stmt.where(models.Observation.entity_id == entity_id)
    return list(db.scalars(stmt.order_by(models.Observation.observed_at.desc())))


@router.post("", response_model=ObservationOut, status_code=status.HTTP_201_CREATED)
def create_observation(
    payload: ObservationCreate, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)
) -> models.Observation:
    """Constitution: "Workers record observations. Workers do not
    diagnose." [ObservationCreate] structurally has no diagnosis field, so
    this endpoint cannot be used to smuggle one in regardless of caller
    role.

    The farm, the subject and the observer must all be the caller's own:
    an observation is evidence the emergency engine and the health case
    act on, so it cannot be planted on another farm's animal or in
    another farm's staff member's name.
    """
    ensure_own_farm(current_user, payload.farm_id)
    model, label, modules = _SUBJECTS[payload.entity_type]
    ensure_any_permission(db, current_user, modules, perms.CREATE)
    owned_or_404(db, model, payload.entity_id, current_user, label)
    ensure_farm_user(db, current_user, payload.observer_id, "observer")
    from app.core import duplicates

    lo, hi = duplicates.near(payload.observed_at)
    earlier = db.scalar(select(models.Observation).where(
        models.Observation.entity_type == payload.entity_type, models.Observation.entity_id == payload.entity_id,
        models.Observation.observation_type == payload.observation_type, models.Observation.observed_at >= lo, models.Observation.observed_at <= hi,
        models.Observation.value_numeric.is_(None) if payload.value_numeric is None else models.Observation.value_numeric == payload.value_numeric,
        models.Observation.value_text.is_(None) if payload.value_text is None else models.Observation.value_text == payload.value_text,
    ))
    match = duplicates.guard(earlier, f"The same {payload.observation_type.replace('_', ' ')} observation was already recorded within half an hour.",
                             confirm=payload.confirm_duplicate)
    observation = models.Observation(
        id=new_id(),
        farm_id=payload.farm_id,
        entity_type=payload.entity_type,
        entity_id=payload.entity_id,
        observation_type=payload.observation_type,
        quality=payload.quality,
        value_numeric=payload.value_numeric,
        value_text=payload.value_text,
        unit=payload.unit,
        severity=payload.severity,
        observed_at=payload.observed_at or now(),
        observer_id=payload.observer_id,
        notes=payload.notes,
    )
    # An observation on a subject with an open health case belongs to it
    # (HEALTH-VETERINARY-SCHEMA health_observation.health_case_id) — still
    # an observation, never a diagnosis.
    subject_type = "animal" if payload.entity_type == "animal" else ("group" if payload.entity_type in ("flock", "group") else None)
    if subject_type is not None:
        case = cases.current_case(db, subject_type, payload.entity_id)
        if case is not None:
            observation.health_case_id = case.id
    db.add(observation)
    duplicates.log_confirmed(db, farm_id=payload.farm_id, entity_type=payload.entity_type, entity_id=payload.entity_id,
                             match_id=match.id if match else None, what=f"observation:{observation.id}", user_id=current_user.id)
    write_event(
        db,
        farm_id=payload.farm_id,
        entity_type=payload.entity_type,
        entity_id=payload.entity_id,
        event_type="observation_recorded",
        payload={"observation_type": payload.observation_type, "severity": payload.severity},
        created_by=current_user.id,
    )
    db.flush()
    # A severe observation starts emergency triage by itself (clinical
    # decision support §12): pattern recognition, never a diagnosis.
    emergency_service.on_observation(db, observation, user_id=current_user.id)
    db.commit()
    db.refresh(observation)
    return observation
