from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_permission, user_can
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.repositories.base import diff_changes, new_id, snapshot, write_audit_log, write_event
from app.schemas.animals import AnimalCreate, AnimalDigitalTwinOut, AnimalMove, AnimalOut, AnimalUpdate

router = APIRouter(prefix="/animals", tags=["animals"])

# Fields the audit trail follows on an animal — everything a manager might
# need to explain later ("who changed this cow's status?").
_AUDITED_ANIMAL_FIELDS = [
    "tag", "name", "species", "breed", "sex", "status", "location_label",
    "health_score", "weight_kg", "group_name", "pregnant", "lactating",
    "purchase_cost", "current_value", "active", "notes",
]

# Money on an animal record is Finance data. Someone who looks after the
# herd does not automatically get to see what it cost.
_FINANCIAL_FIELDS = ("purchase_cost", "current_value")


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


@router.post("", response_model=AnimalOut, status_code=status.HTTP_201_CREATED)
def create_animal(
    payload: AnimalCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.ANIMALS, perms.CREATE)),
) -> models.Animal:
    """Registers a new animal — the start of its digital twin (tech spec §13)."""
    clash = db.scalars(
        select(models.Animal).where(
            models.Animal.farm_id == current_user.farm_id,
            models.Animal.tag == payload.tag,
            models.Animal.active.is_(True),
        )
    ).one_or_none()
    if clash is not None:
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"Ear tag '{payload.tag}' is already used by {clash.name}."
        )

    data = payload.model_dump()
    if not user_can(db, current_user, perms.FINANCE, perms.CREATE):
        for field in _FINANCIAL_FIELDS:
            data.pop(field, None)

    animal = models.Animal(id=new_id(), farm_id=current_user.farm_id, **data)
    db.add(animal)
    write_event(
        db, farm_id=current_user.farm_id, entity_type="animal", entity_id=animal.id,
        event_type="animal_created",
        payload={"tag": animal.tag, "name": animal.name, "species": animal.species},
        created_by=current_user.id,
    )
    write_audit_log(
        db, farm_id=current_user.farm_id, user_id=current_user.id, action="animal_created",
        entity_type="animal", entity_id=animal.id, module_code=perms.ANIMALS,
        summary=f"{current_user.name} created {animal.name} #{animal.tag}",
    )
    db.commit()
    db.refresh(animal)
    return animal


@router.put("/{animal_id}", response_model=AnimalOut)
def update_animal(
    animal_id: str,
    payload: AnimalUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.ANIMALS, perms.EDIT)),
) -> models.Animal:
    """Full edit of an animal record (tech spec §12)."""
    animal = db.get(models.Animal, animal_id)
    if animal is None or animal.farm_id != current_user.farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Animal not found")

    changes = payload.model_dump(exclude_unset=True)
    if not user_can(db, current_user, perms.FINANCE, perms.EDIT):
        for field in _FINANCIAL_FIELDS:
            changes.pop(field, None)
    if changes.get("active") is False and not user_can(db, current_user, perms.ANIMALS, perms.DELETE):
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, "You do not have permission to archive an animal in Animals."
        )
    if "tag" in changes and changes["tag"] != animal.tag:
        clash = db.scalars(
            select(models.Animal).where(
                models.Animal.farm_id == current_user.farm_id,
                models.Animal.tag == changes["tag"],
                models.Animal.id != animal.id,
                models.Animal.active.is_(True),
            )
        ).one_or_none()
        if clash is not None:
            raise HTTPException(
                status.HTTP_409_CONFLICT, f"Ear tag '{changes['tag']}' is already used by {clash.name}."
            )

    before = snapshot(animal, _AUDITED_ANIMAL_FIELDS)
    for field, value in changes.items():
        setattr(animal, field, value)

    write_event(
        db, farm_id=current_user.farm_id, entity_type="animal", entity_id=animal.id,
        event_type="animal_updated", payload={"fields": sorted(changes)}, created_by=current_user.id,
    )
    write_audit_log(
        db, farm_id=current_user.farm_id, user_id=current_user.id, action="animal_updated",
        entity_type="animal", entity_id=animal.id, module_code=perms.ANIMALS,
        summary=f"{current_user.name} updated {animal.name} #{animal.tag}",
        changes=diff_changes(before, animal, _AUDITED_ANIMAL_FIELDS),
    )
    db.commit()
    db.refresh(animal)
    return animal


@router.patch("/{animal_id}", response_model=AnimalOut)
def move_animal(
    animal_id: str,
    payload: AnimalMove,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.ANIMALS, perms.EDIT)),
) -> models.Animal:
    animal = db.get(models.Animal, animal_id)
    if animal is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Animal not found")
    previous = animal.location_label
    animal.location_label = payload.location_label
    write_audit_log(
        db, farm_id=animal.farm_id, user_id=current_user.id, action="animal_moved",
        entity_type="animal", entity_id=animal.id, module_code=perms.ANIMALS,
        summary=f"{current_user.name} moved {animal.name} to {payload.location_label}",
        changes={"location_label": {"from": previous, "to": payload.location_label}},
    )
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
