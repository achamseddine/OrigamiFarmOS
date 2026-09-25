from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_permission, user_can
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.livestock.catalog import Cap
from app.repositories.base import diff_changes, new_id, snapshot, write_audit_log, write_event
from app.schemas.animals import AnimalCreate, AnimalDigitalTwinOut, AnimalMove, AnimalOut, AnimalUpdate
from app.services import capability_service, feeding_program_service, identifier_service
from app.services.capability_service import CapabilitySet

router = APIRouter(prefix="/animals", tags=["animals"])

# Fields the audit trail follows on an animal — everything a manager might
# need to explain later ("who changed this cow's status?").
_AUDITED_ANIMAL_FIELDS = [
    "tag", "name", "species", "breed", "breed_id", "sex", "life_stage", "management_profile",
    "birth_date_estimated", "status", "location_label",
    "health_score", "weight_kg", "group_name", "pregnant", "lactating",
    "purchase_cost", "current_value", "active", "notes",
]

# Money on an animal record is Finance data. Someone who looks after the
# herd does not automatically get to see what it cost.
_FINANCIAL_FIELDS = ("purchase_cost", "current_value")


def _species_or_422(db: Session, code: str) -> None:
    try:
        capability_service.get_species(db, code)
    except capability_service.UnknownSpecies:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"'{code}' is not a species this farm keeps. See GET /species for the list.",
        ) from None


def _check_state_against(cap_set: CapabilitySet, *, name: str, pregnant: bool, lactating: bool) -> None:
    """Generic animal model §12: pregnancy needs PREGNANCY, lactation needs
    LACTATION. A male, a hen, or a meat ewe cannot be recorded as either."""
    if pregnant and not cap_set.has(Cap.PREGNANCY):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, capability_service.describe_missing(cap_set, Cap.PREGNANCY, name))
    if lactating and not cap_set.has(Cap.LACTATION):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, capability_service.describe_missing(cap_set, Cap.LACTATION, name))


def _has_operational_history(db: Session, animal_id: str) -> bool:
    """Anything recorded *about* the animal since it was registered. While
    this is true its species cannot change (§12) — the history would no
    longer mean what it meant."""
    milk = db.scalar(select(models.MilkRecord.id).where(models.MilkRecord.animal_id == animal_id).limit(1))
    if milk:
        return True
    obs = db.scalar(select(models.Observation.id).where(
        models.Observation.entity_type == "animal", models.Observation.entity_id == animal_id).limit(1))
    if obs:
        return True
    treat = db.scalar(select(models.Treatment.id).where(
        models.Treatment.entity_type == "animal", models.Treatment.entity_id == animal_id).limit(1))
    return bool(treat)


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
    """Registers a new animal — the start of its digital twin (tech spec §13).

    Generic animal model §2: species, sex, stage and profile go through
    the capability resolver first; it decides which identifiers this
    animal may and must carry and whether it can be pregnant or lactating.
    """
    _species_or_422(db, payload.species)
    cap_set = capability_service.resolve(db, payload.species, payload.sex, payload.life_stage, payload.management_profile)
    _check_state_against(cap_set, name=payload.name, pregnant=payload.pregnant, lactating=payload.lactating)
    identifiers = identifier_service.collect(payload.identifiers, payload.tag, cap_set)
    identifier_service.ensure_unique(db, current_user.farm_id, identifiers)

    data = payload.model_dump(exclude={"identifiers", "tag"})
    if not user_can(db, current_user, perms.FINANCE, perms.CREATE):
        for field in _FINANCIAL_FIELDS:
            data.pop(field, None)

    animal = models.Animal(id=new_id(), farm_id=current_user.farm_id, **data)
    db.add(animal)
    db.flush()
    identifier_service.attach(db, animal, identifiers)
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

    # Species is the one thing history depends on (§12): once anything has
    # been recorded about the animal, it stays what it was registered as.
    new_species = changes.get("species", animal.species)
    if new_species != animal.species:
        _species_or_422(db, new_species)
        if _has_operational_history(db, animal.id):
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"{animal.name} already has milk, treatment or observation records as a "
                f"{animal.species.replace('_', ' ')}. Its species cannot be changed; register a new animal instead.",
            )

    # Sex, stage or profile changing re-evaluates what the animal can be
    # — a cow that becomes 'meat' cannot stay flagged as lactating.
    resolver_inputs = {"species", "sex", "life_stage", "management_profile"}
    state_inputs = {"pregnant", "lactating"}
    if resolver_inputs & changes.keys() or state_inputs & changes.keys():
        cap_set = capability_service.resolve(
            db, new_species, changes.get("sex", animal.sex),
            changes.get("life_stage", animal.life_stage), changes.get("management_profile", animal.management_profile),
        )
        _check_state_against(
            cap_set, name=animal.name,
            pregnant=changes.get("pregnant", animal.pregnant), lactating=changes.get("lactating", animal.lactating),
        )
    else:
        cap_set = None

    new_tag = changes.pop("tag", None)

    before = snapshot(animal, _AUDITED_ANIMAL_FIELDS)
    for field, value in changes.items():
        setattr(animal, field, value)
    # A change to what the feeding resolver reads (pregnant, lactating,
    # stage, profile, group…) asks for a feeding review (feed architecture
    # §10) — an event and a task, never a silent reassignment.
    feeding_program_service.review_animal_if_relevant(db, animal, set(changes), user_id=current_user.id)
    if new_tag is not None and new_tag.strip() and new_tag.strip() != (animal.tag or ""):
        identifier_service.replace_primary_value(
            db, animal, new_tag.strip(), cap_set or capability_service.resolve_for_animal(db, animal)
        )

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
        capabilities=capability_service.resolve_for_animal(db, animal).to_dict(),
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
