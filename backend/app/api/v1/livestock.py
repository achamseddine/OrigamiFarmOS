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

from app.api.deps import ensure_any_permission, get_current_user, owned_or_404, require_any_permission, require_permission
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import livestock_models as lm
from app.domain import models
from app.repositories.base import new_id, now, write_audit_log, write_event
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
from app.schemas.reproduction import AnimalExitIn, AnimalRestoreIn, MembershipEndIn, MembershipIn, ParentIn, QuantityEventIn
from app.services import capability_service, group_service, identifier_service, livestock_state_service, reproduction_service

router = APIRouter(tags=["livestock"])

# Herd records are read wherever an animal or a group is worked with.
_HERD_VIEW = require_any_permission(perms.ANIMALS, perms.ANIMAL_HEALTH, perms.MILK_PRODUCTION, perms.FEED_NUTRITION, perms.EGG_PRODUCTION)
_HERD_EDIT = require_permission(perms.ANIMALS, perms.EDIT)
# A flock's mortality and additions are recorded by whoever keeps it.
_HEADCOUNT_CREATE = require_any_permission(perms.ANIMALS, perms.EGG_PRODUCTION, action=perms.CREATE)


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
    species = _species_or_422(db, payload.species)
    data = payload.model_dump()
    if data.get("membership_rule"):
        # A rule group (pregnant, open, in milk, dry) overlaps the herd and
        # the pen the animal is in — it is a cohort counting its members.
        if group_service.policy(db, data.get("group_type")).exclusive_membership:
            data["group_type"] = "cohort"
        data["tracking_mode"] = group_service.MEMBERSHIP_DERIVED
        data["count"] = 0
    # LIVESTOCK-SCHEMA §6: a group either counts heads or counts its
    # registered members. Unstated: a head count given means a counted
    # group; otherwise a species kept individually counts members.
    if not data.get("tracking_mode"):
        individual = species.default_management == "individual"
        data["tracking_mode"] = group_service.MEMBERSHIP_DERIVED if individual and not data.get("count") else group_service.QUANTITY_MANAGED
    group = models.Flock(id=new_id(), farm_id=current_user.farm_id, created_at=now(), **data)
    cap_set = capability_service.resolve_for_group(db, group)
    # A counted flock needs the species to be manageable as a group; a herd
    # of registered cows only needs its members to be individuals.
    Cap = capability_service.catalog.Cap
    needed = Cap.INDIVIDUAL_TRACKING if group.tracking_mode == group_service.MEMBERSHIP_DERIVED else Cap.GROUP_TRACKING
    if not cap_set.has(needed):
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"{cap_set.terminology.get('group_en', 'Group')} management is not configured for this species; register the animals individually."
            if needed == Cap.GROUP_TRACKING else f"{species.name_en} are not tracked individually; keep them as a counted group.",
        )
    group_service.open_group(db, group, user_id=current_user.id)
    db.add(group)
    write_event(
        db, farm_id=group.farm_id, entity_type="flock", entity_id=group.id, event_type="group_created",
        payload={"name": group.name, "species": group.species, "count": group.count}, created_by=current_user.id,
    )
    write_audit_log(
        db, farm_id=group.farm_id, user_id=current_user.id, action="group_created", entity_type="flock",
        entity_id=group.id, module_code=perms.ANIMALS, summary=f"{current_user.name} created {group.name}",
    )
    if group.membership_rule:
        db.flush()
        group_service.fill_rule_group(db, group, user_id=current_user.id)
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
    # A head count is never typed over (LIVESTOCK-SCHEMA §9): a new count
    # becomes a COUNT_ADJUSTMENT in the group's ledger, and a group that
    # counts its members takes its count from them.
    if "count" in changes:
        new_count = changes.pop("count")
        if new_count is not None and new_count != group.count:
            if group.tracking_mode == group_service.MEMBERSHIP_DERIVED:
                raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"{group.name} counts its registered members; add or remove animals instead.")
            group_service.set_count(db, group, new_count, user_id=current_user.id)
            changes["count"] = new_count
    for field, value in changes.items():
        if field != "count":
            setattr(group, field, value)
    # A group that grew, changed stage or changed profile may fit a different
    # feeding program — a review, never a silent reassignment (feed §10).
    if {"count", "life_stage", "management_profile", "sex_composition"} & changes.keys():
        from app.services import feed_performance_service, feeding_program_service

        feeding_program_service.review_feeding(db, group.farm_id, "group", group, trigger="group_changed", user_id=current_user.id)
        # FEED-PERFORMANCE-INTELLIGENCE §12: a group change is a confounder.
        feed_performance_service.on_context_changed(db, "group", group, trigger="group_changed", user_id=current_user.id)
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


# ------------------------------------------------------------ group membership (LIVESTOCK-SCHEMA §7–§9)
@router.get("/animal-group-types")
def list_group_types(db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)) -> list[dict]:
    return [
        {"group_type": p.group_type, "label_en": p.label_en, "label_ar": p.label_ar, "exclusive_membership": p.exclusive_membership,
         "allows_individual_members": p.allows_individual_members}
        for p in db.scalars(select(lm.AnimalGroupTypePolicy).where(lm.AnimalGroupTypePolicy.active.is_(True)).order_by(lm.AnimalGroupTypePolicy.group_type))
    ]


@router.get("/animal-groups/{group_id}/members")
def list_members(group_id: str, include_past: bool = False, db: Session = Depends(get_db), user: models.User = Depends(_HERD_VIEW)) -> list[dict]:
    """Who is in the group now — or, with `include_past`, everyone who ever
    was, with the dates (membership is closed, never deleted)."""
    group = _group_or_404(db, group_id, user)
    rows = group_service.member_history(db, group) if include_past else group_service.current_members(db, group)
    return [group_service.membership_dict(db, m, animal=a, group=group) for m, a in rows]


@router.post("/animal-groups/{group_id}/members", status_code=status.HTTP_201_CREATED)
def add_member(group_id: str, payload: MembershipIn, db: Session = Depends(get_db), user: models.User = Depends(_HERD_EDIT)) -> dict:
    """Puts an animal in the group. In an exclusive group (a herd, a pen)
    this is a move: the animal's previous exclusive membership closes."""
    group = _group_or_404(db, group_id, user)
    animal = owned_or_404(db, models.Animal, payload.animal_id, user, "Animal")
    membership = group_service.add_member(db, group, animal, at=payload.valid_from, reason=payload.reason, user_id=user.id)
    group_service.audit(db, group, user, "group_member_added", f"{user.name} added {animal.name} to {group.name}")
    db.commit()
    return group_service.membership_dict(db, membership, animal=animal, group=group)


@router.post("/animal-groups/{group_id}/members/{animal_id}/end")
def end_member(group_id: str, animal_id: str, payload: MembershipEndIn, db: Session = Depends(get_db), user: models.User = Depends(_HERD_EDIT)) -> dict:
    group = _group_or_404(db, group_id, user)
    animal = owned_or_404(db, models.Animal, animal_id, user, "Animal")
    membership = group_service.remove_member(db, group, animal, at=payload.valid_to, reason=payload.reason, user_id=user.id)
    group_service.audit(db, group, user, "group_member_removed", f"{user.name} took {animal.name} out of {group.name}")
    db.commit()
    return group_service.membership_dict(db, membership, animal=animal, group=group)


@router.get("/animal-groups/{group_id}/quantity-events")
def list_quantity_events(group_id: str, db: Session = Depends(get_db), user: models.User = Depends(_HERD_VIEW)) -> list[dict]:
    return [group_service.quantity_dict(e) for e in group_service.quantity_history(db, _group_or_404(db, group_id, user))]


@router.post("/animal-groups/{group_id}/quantity-events", status_code=status.HTTP_201_CREATED)
def record_quantity_event(group_id: str, payload: QuantityEventIn, db: Session = Depends(get_db), user: models.User = Depends(_HEADCOUNT_CREATE)) -> dict:
    """A flock's deaths, sales, purchases, transfers or a recount — one row
    of its head-count ledger; `count` follows."""
    group = _group_or_404(db, group_id, user)
    event = group_service.record_quantity(db, group, payload.event_type, payload.quantity_delta, at=payload.occurred_at, reason=payload.reason,
                                          source_type="manual", user_id=user.id)
    group_service.audit(db, group, user, "group_quantity_changed",
                        f"{user.name} recorded {payload.event_type.lower().replace('_', ' ')} {payload.quantity_delta:+d} on {group.name}",
                        changes={"count": {"to": group.count}})
    db.commit()
    return group_service.quantity_dict(event)


# ------------------------------------------------------------ animal history, exit, parentage (LIVESTOCK-SCHEMA §5, §10, §14)
@router.get("/animals/{animal_id}/history")
def animal_history(animal_id: str, state_type: str | None = None, db: Session = Depends(get_db), user: models.User = Depends(_HERD_VIEW)) -> list[dict]:
    """The animal's effective-dated status, stage, profile and location."""
    animal = owned_or_404(db, models.Animal, animal_id, user, "Animal")
    if state_type and state_type.upper() not in livestock_state_service.STATE_TYPES:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"state_type must be one of {list(livestock_state_service.STATE_TYPES)}")
    return [livestock_state_service.history_dict(h) for h in livestock_state_service.history(db, animal.id, state_type.upper() if state_type else None)]


@router.get("/animals/{animal_id}/groups")
def animal_groups(animal_id: str, db: Session = Depends(get_db), user: models.User = Depends(_HERD_VIEW)) -> list[dict]:
    animal = owned_or_404(db, models.Animal, animal_id, user, "Animal")
    return [group_service.membership_dict(db, m, animal=animal) for m in group_service.memberships_of_animal(db, animal.id)]


@router.post("/animals/{animal_id}/exit")
def exit_animal(animal_id: str, payload: AnimalExitIn, db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> dict:
    """The animal left the farm: sold, dead, culled, slaughtered or
    transferred. Its groups, lactation, pregnancy and feeding close; its
    record stays. A death is recorded by whoever looks after the animal
    (Animals · edit); the others are a manager's call (Animals · approve)."""
    animal = owned_or_404(db, models.Animal, animal_id, user, "Animal")
    action = perms.EDIT if payload.exit_type in livestock_state_service.FACT_EXITS else perms.APPROVE
    ensure_any_permission(db, user, (perms.ANIMALS,), action)
    livestock_state_service.exit_animal(db, animal, payload.exit_type, at=payload.occurred_at, reason=payload.reason, notes=payload.notes, user=user)
    db.commit()
    return {"id": animal.id, "lifecycle_status": animal.lifecycle_status, "exited_at": animal.exited_at, "active": animal.active}


@router.post("/animals/{animal_id}/restore")
def restore_animal(animal_id: str, payload: AnimalRestoreIn, db: Session = Depends(get_db), user: models.User = Depends(require_permission(perms.ANIMALS, perms.DELETE))) -> dict:
    """Brings back an animal archived by mistake. A sale or a death is not
    undone this way."""
    animal = owned_or_404(db, models.Animal, animal_id, user, "Animal")
    livestock_state_service.reactivate(db, animal, reason=payload.reason, user=user)
    db.commit()
    return {"id": animal.id, "lifecycle_status": animal.lifecycle_status, "active": animal.active}


@router.get("/animals/{animal_id}/relationships")
def animal_relationships(animal_id: str, db: Session = Depends(get_db), user: models.User = Depends(_HERD_VIEW)) -> dict:
    return reproduction_service.relationships(db, owned_or_404(db, models.Animal, animal_id, user, "Animal"))


@router.post("/animals/{animal_id}/parents", status_code=status.HTTP_201_CREATED)
def record_parent(animal_id: str, payload: ParentIn, db: Session = Depends(get_db), user: models.User = Depends(_HERD_EDIT)) -> dict:
    """Parentage for an animal that arrived with known parents on this
    farm. A birth recorded here links its own parentage."""
    child = owned_or_404(db, models.Animal, animal_id, user, "Animal")
    parent = owned_or_404(db, models.Animal, payload.parent_animal_id, user, "Parent")
    reproduction_service.record_parent(db, child, parent, payload.relationship_type, evidence=payload.evidence, user=user)
    db.commit()
    return reproduction_service.relationships(db, child)
