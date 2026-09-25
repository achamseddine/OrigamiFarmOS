from __future__ import annotations

from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.base import get_db
from app.domain import models
from app.repositories.base import new_id, now, write_event
from app.schemas.observations import ObservationCreate, ObservationOut

router = APIRouter(prefix="/observations", tags=["observations"])


@router.post("", response_model=ObservationOut, status_code=status.HTTP_201_CREATED)
def create_observation(
    payload: ObservationCreate, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)
) -> models.Observation:
    """Constitution: "Workers record observations. Workers do not
    diagnose." [ObservationCreate] structurally has no diagnosis field, so
    this endpoint cannot be used to smuggle one in regardless of caller
    role.
    """
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
    db.add(observation)
    write_event(
        db,
        farm_id=payload.farm_id,
        entity_type=payload.entity_type,
        entity_id=payload.entity_id,
        event_type="observation_recorded",
        payload={"observation_type": payload.observation_type, "severity": payload.severity},
        created_by=current_user.id,
    )
    db.commit()
    db.refresh(observation)
    return observation
