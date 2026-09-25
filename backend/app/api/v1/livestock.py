"""Species configuration, the capability resolver, identifiers, and
animal groups (docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md §11).

These are the endpoints that make "adding a species is configuration"
true for the tablet: it asks `/species` what exists, `/species/{code}/
configuration` what each needs, and `/animal-capabilities/resolve` what a
particular animal can do — then draws exactly that.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_permission
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import livestock_models as lm
from app.domain import models
from app.repositories.base import new_id, write_audit_log, write_event
from app.schemas.livestock import (
    AnimalGroupCreate,
    AnimalGroupOut,
    AnimalGroupUpdate,
    BreedOut,
    CapabilityOut,
    CapabilitySetOut,
    IdentifierIn,
    IdentifierOut,
    LifeStageOut,
    ManagementProfileOut,
    ResolveRequest,
    RuleOut,
    SpeciesConfigurationOut,
    SpeciesOut,
)
from app.services import capability_service, identifier_service

router = APIRouter(tags=["livestock"])


def _species_or_422(db: Session, code: str) -> lm.Species:
    try:
        return capability_service.get_species(db, code)
    except capability_service.UnknownSpecies:
        known = [s.code for s in db.scalars(select(lm.Species).where(lm.Species.active.is_(True)))]
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"'{code}' is not a species this farm keeps. Known species: {', '.join(known)}.",
        ) from None


# ------------------------------------------------------------------ species
@router.get("/species", response_model=list[SpeciesOut])
def list_species(db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)):
    return list(db.scalars(select(lm.Species).where(lm.Species.active.is_(True)).order_by(lm.Species.sort_order)))


@router.get("/species/{code}/configuration", response_model=SpeciesConfigurationOut)
def species_configuration(code: str, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)):
    species = _species_or_422(db, code)
    generic_or_own = lambda col: (col.is_(None)) | (col == code)  # noqa: E731
    return SpeciesConfigurationOut(
        species=SpeciesOut.model_validate(species),
        breeds=[BreedOut.model_validate(b) for b in db.scalars(
            select(lm.Breed).where(lm.Breed.species_code == code, lm.Breed.active.is_(True)).order_by(lm.Breed.name))],
        life_stages=[LifeStageOut.model_validate(s) for s in db.scalars(
            select(lm.LifeStage).where(generic_or_own(lm.LifeStage.species_code)).order_by(lm.LifeStage.sort_order))],
        management_profiles=[
            ManagementProfileOut.model_validate(p) for p in db.scalars(
                select(lm.ManagementProfile).where(generic_or_own(lm.ManagementProfile.species_code)).order_by(lm.ManagementProfile.code))
            # Only the profiles that make sense for this species (empty = all).
            if not species.profiles_json or p.code in species.profiles_json
        ],
        rules=[RuleOut.model_validate(r) for r in db.scalars(
            select(lm.SpeciesCapabilityRule).where(lm.SpeciesCapabilityRule.species_code == code))],
    )


@router.get("/capabilities", response_model=list[CapabilityOut])
def list_capabilities(db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)):
    return list(db.scalars(select(lm.Capability).where(lm.Capability.active.is_(True))))


# ----------------------------------------------------------------- resolver
@router.post("/animal-capabilities/resolve", response_model=CapabilitySetOut)
def resolve_capabilities(payload: ResolveRequest, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)):
    """What an animal of this species / sex / stage / profile can do — the
    same answer the write endpoints enforce, so a form built from it never
    offers something the server will refuse."""
    _species_or_422(db, payload.species)
    return capability_service.resolve(db, payload.species, payload.sex, payload.life_stage, payload.management_profile).to_dict()


@router.get("/animals/{animal_id}/capabilities", response_model=CapabilitySetOut)
def animal_capabilities(animal_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    animal = _animal_or_404(db, animal_id, current_user)
    return capability_service.resolve_for_animal(db, animal).to_dict()


# -------------------------------------------------------------- identifiers
def _animal_or_404(db: Session, animal_id: str, user: models.User) -> models.Animal:
    animal = db.get(models.Animal, animal_id)
    if animal is None or animal.farm_id != user.farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Animal not found")
    return animal


@router.get("/animals/{animal_id}/identifiers", response_model=list[IdentifierOut])
def list_identifiers(animal_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    _animal_or_404(db, animal_id, current_user)
    return list(
        db.scalars(
            select(lm.AnimalIdentifier)
            .where(lm.AnimalIdentifier.animal_id == animal_id)
            .order_by(lm.AnimalIdentifier.status, lm.AnimalIdentifier.is_primary.desc(), lm.AnimalIdentifier.created_at)
        )
    )


@router.post("/animals/{animal_id}/identifiers", response_model=IdentifierOut, status_code=status.HTTP_201_CREATED)
def add_identifier(
    animal_id: str,
    payload: IdentifierIn,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.ANIMALS, perms.EDIT)),
):
    animal = _animal_or_404(db, animal_id, current_user)
    cap_set = capability_service.resolve_for_animal(db, animal)
    identifiers = identifier_service.collect([payload], None, cap_set, check_required=False)
    # `collect` would make a lone identifier primary; adding a second RFID
    # to a cow with an ear tag must not steal the primary unless asked.
    identifiers = [identifiers[0].model_copy(update={"is_primary": payload.is_primary})]
    identifier_service.ensure_unique(db, animal.farm_id, identifiers, exclude_animal_id=animal.id)
    if payload.is_primary:
        for existing in identifier_service.active_identifiers(db, animal.id):
            existing.is_primary = False
    identifier_service.attach(db, animal, identifiers)
    row = identifier_service.active_identifiers(db, animal.id)
    created = next(i for i in row if i.identifier_type == payload.identifier_type and i.identifier_value == payload.identifier_value)
    write_audit_log(
        db, farm_id=animal.farm_id, user_id=current_user.id, action="animal_identifier_added",
        entity_type="animal", entity_id=animal.id, module_code=perms.ANIMALS,
        summary=f"{current_user.name} added {payload.identifier_type.replace('_', ' ').lower()} {payload.identifier_value} to {animal.name}",
    )
    db.commit()
    db.refresh(created)
    return created


@router.delete("/animals/{animal_id}/identifiers/{identifier_id}", status_code=status.HTTP_204_NO_CONTENT)
def retire_identifier(
    animal_id: str,
    identifier_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.ANIMALS, perms.EDIT)),
):
    """Retires, never deletes: a record that names the old tag still
    resolves. If it was the primary, the next active identifier takes over
    — an animal is not left with no way to be called."""
    animal = _animal_or_404(db, animal_id, current_user)
    ident = db.get(lm.AnimalIdentifier, identifier_id)
    if ident is None or ident.animal_id != animal.id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Identifier not found")
    remaining = [i for i in identifier_service.active_identifiers(db, animal.id) if i.id != ident.id]
    cap_set = capability_service.resolve_for_animal(db, animal)
    still_present = {i.identifier_type for i in remaining}
    missing = cap_set.required_identifier_types() - still_present
    if missing:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"{animal.name} must keep a {', '.join(m.replace('_', ' ').lower() for m in sorted(missing))}. Add a replacement first.",
        )
    ident.status = "retired"
    ident.is_primary = False
    identifier_service.sync_tag(db, animal)
    write_audit_log(
        db, farm_id=animal.farm_id, user_id=current_user.id, action="animal_identifier_retired",
        entity_type="animal", entity_id=animal.id, module_code=perms.ANIMALS,
        summary=f"{current_user.name} retired {ident.identifier_type.replace('_', ' ').lower()} {ident.identifier_value} on {animal.name}",
    )
    db.commit()


# ------------------------------------------------------------ animal groups
@router.get("/animal-groups", response_model=list[AnimalGroupOut])
def list_groups(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    return list(db.scalars(select(models.Flock).where(models.Flock.farm_id == current_user.farm_id).order_by(models.Flock.name)))


@router.post("/animal-groups", response_model=AnimalGroupOut, status_code=status.HTTP_201_CREATED)
def create_group(
    payload: AnimalGroupCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.ANIMALS, perms.CREATE)),
):
    _species_or_422(db, payload.species)
    group = models.Flock(id=new_id(), farm_id=current_user.farm_id, **payload.model_dump())
    cap_set = capability_service.resolve_for_group(db, group)
    if not cap_set.has(capability_service.catalog.Cap.GROUP_TRACKING):
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"{cap_set.terminology.get('group_en', 'Group')} management is not configured for this species; register the animals individually.",
        )
    db.add(group)
    write_event(
        db, farm_id=group.farm_id, entity_type="flock", entity_id=group.id, event_type="group_created",
        payload={"name": group.name, "species": group.species, "count": group.count}, created_by=current_user.id,
    )
    write_audit_log(
        db, farm_id=group.farm_id, user_id=current_user.id, action="group_created", entity_type="flock",
        entity_id=group.id, module_code=perms.ANIMALS, summary=f"{current_user.name} created {group.name}",
    )
    db.commit()
    db.refresh(group)
    return group


def _group_or_404(db: Session, group_id: str, user: models.User) -> models.Flock:
    group = db.get(models.Flock, group_id)
    if group is None or group.farm_id != user.farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Animal group not found")
    return group


@router.get("/animal-groups/{group_id}", response_model=AnimalGroupOut)
def get_group(group_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    return _group_or_404(db, group_id, current_user)


@router.patch("/animal-groups/{group_id}", response_model=AnimalGroupOut)
def update_group(
    group_id: str,
    payload: AnimalGroupUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.ANIMALS, perms.EDIT)),
):
    group = _group_or_404(db, group_id, current_user)
    changes = payload.model_dump(exclude_unset=True)
    for field, value in changes.items():
        setattr(group, field, value)
    # A group that grew, changed stage or changed profile may fit a different
    # feeding program — a review, never a silent reassignment (feed §10).
    if {"count", "life_stage", "management_profile", "sex_composition"} & changes.keys():
        from app.services import feeding_program_service

        feeding_program_service.review_feeding(db, group.farm_id, "group", group, trigger="group_changed", user_id=current_user.id)
    write_audit_log(
        db, farm_id=group.farm_id, user_id=current_user.id, action="group_updated", entity_type="flock",
        entity_id=group.id, module_code=perms.ANIMALS, summary=f"{current_user.name} updated {group.name}",
        changes={k: {"to": v} for k, v in changes.items()},
    )
    db.commit()
    db.refresh(group)
    return group


@router.get("/animal-groups/{group_id}/capabilities", response_model=CapabilitySetOut)
def group_capabilities(group_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    return capability_service.resolve_for_group(db, _group_or_404(db, group_id, current_user)).to_dict()
