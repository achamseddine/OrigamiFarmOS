from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.base import get_db
from app.domain import models
from app.repositories.base import write_event
from app.schemas.animals import AnimalDigitalTwinOut, AnimalMove, AnimalOut

router = APIRouter(prefix="/animals", tags=["animals"])


@router.get("", response_model=list[AnimalOut])
def list_animals(
    farm_id: str,
    species: str | None = None,
    status_filter: str | None = Query(None, alias="status"),
    search: str | None = None,
    db: Session = Depends(get_db),
    _user: models.User = Depends(get_current_user),
) -> list[models.Animal]:
    stmt = select(models.Animal).where(models.Animal.farm_id == farm_id, models.Animal.active.is_(True))
    if species:
        stmt = stmt.where(models.Animal.species == species)
    if status_filter:
        stmt = stmt.where(models.Animal.status == status_filter)
    if search:
        like = f"%{search.lower()}%"
        stmt = stmt.where((models.Animal.name.ilike(like)) | (models.Animal.tag.ilike(like)))
    return list(db.scalars(stmt.order_by(models.Animal.name)))


@router.patch("/{animal_id}", response_model=AnimalOut)
def move_animal(animal_id: str, payload: AnimalMove, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> models.Animal:
    animal = db.get(models.Animal, animal_id)
    if animal is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Animal not found")
    animal.location_label = payload.location_label
    write_event(
        db,
        farm_id=animal.farm_id,
        entity_type="animal",
        entity_id=animal.id,
        event_type="animal_moved",
        payload={"location_label": payload.location_label},
        created_by=current_user.id,
    )
    db.commit()
    db.refresh(animal)
    return animal


@router.get("/{animal_id}", response_model=AnimalDigitalTwinOut)
def get_animal(animal_id: str, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)):
    animal = db.get(models.Animal, animal_id)
    if animal is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Animal not found")

    observations = db.scalars(
        select(models.Observation)
        .where(models.Observation.entity_type == "animal", models.Observation.entity_id == animal_id)
        .order_by(models.Observation.observed_at.desc())
        .limit(20)
    ).all()
    events = db.scalars(
        select(models.Event)
        .where(models.Event.entity_type == "animal", models.Event.entity_id == animal_id)
        .order_by(models.Event.created_at.desc())
        .limit(20)
    ).all()
    recs = db.scalars(
        select(models.Recommendation)
        .where(
            models.Recommendation.entity_type == "animal",
            models.Recommendation.entity_id == animal_id,
            models.Recommendation.status == "generated",
        )
        .order_by(models.Recommendation.generated_at.desc())
    ).all()

    return AnimalDigitalTwinOut(
        **AnimalOut.model_validate(animal).model_dump(),
        recent_observations=[
            {
                "id": o.id,
                "observation_type": o.observation_type,
                "value_numeric": o.value_numeric,
                "value_text": o.value_text,
                "severity": o.severity,
                "observed_at": o.observed_at.isoformat(),
            }
            for o in observations
        ],
        recent_events=[
            {"id": e.id, "event_type": e.event_type, "created_at": e.created_at.isoformat(), "payload": e.payload_json}
            for e in events
        ],
        open_recommendations=[{"id": r.id, "title": r.title, "priority": r.priority, "confidence": r.confidence} for r in recs],
    )
