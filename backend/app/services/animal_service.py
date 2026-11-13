"""Registering an animal — the start of its digital twin (tech spec §13,
generic animal model §2, LIVESTOCK-SCHEMA §2/§14).

One path for every way an animal arrives: the Add Animal form, a calf
registered at its birth, a chick picked out of a hatch. Species, sex,
stage and profile go through the capability resolver first; it decides
which identifiers the animal may and must carry, and whether it can be
registered pregnant or in milk. Registration then writes the opening
state history, turns an opening pregnancy or lactation into the episode it
stands for, and places the animal in its herd.
"""
from __future__ import annotations

from datetime import datetime

from fastapi import HTTPException, status
from sqlalchemy.orm import Session

from app.api.deps import user_can
from app.core import permissions as perms
from app.domain import models
from app.livestock.catalog import Cap
from app.repositories.base import ensure_utc, new_id, write_audit_log, write_event
from app.services import capability_service, health_case_service, identifier_service
from app.services.capability_service import CapabilitySet

# Money on an animal record is Finance data. Someone who looks after the
# herd does not automatically get to see what it cost.
FINANCIAL_FIELDS = ("purchase_cost", "current_value")
# Reproduction and lactation are not columns a registration sets: they
# become episodes (reproduction_service.open_registration_state).
_OPENING_STATE_FIELDS = ("pregnant", "pregnancy_days", "lactating", "lactation_cycle", "service_date", "service_type")


def species_or_422(db: Session, code: str) -> None:
    try:
        capability_service.get_species(db, code)
    except capability_service.UnknownSpecies:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"'{code}' is not a species this farm keeps. See GET /species for the list.",
        ) from None


def check_state_against(cap_set: CapabilitySet, *, name: str, pregnant: bool, lactating: bool) -> None:
    """Generic animal model §12: pregnancy needs PREGNANCY, lactation needs
    LACTATION. A male, a hen, or a meat ewe cannot be recorded as either."""
    if pregnant and not cap_set.has(Cap.PREGNANCY):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, capability_service.describe_missing(cap_set, Cap.PREGNANCY, name))
    if lactating and not cap_set.has(Cap.LACTATION):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, capability_service.describe_missing(cap_set, Cap.LACTATION, name))


def create_animal(db: Session, user: models.User, data: dict, *, identifiers_in: list | None = None, tag: str | None = None,
                  registered_at: datetime | None = None, source: str = "registration", audit_summary: str | None = None) -> models.Animal:
    """Registers one animal from an AnimalCreate-shaped dict. Does not
    commit: a birth registers its offspring in the birth's own transaction."""
    from app.services import group_service, livestock_state_service, reproduction_service

    data = dict(data)
    species_or_422(db, data["species"])
    cap_set = capability_service.resolve(db, data["species"], data.get("sex"), data.get("life_stage"), data.get("management_profile"))
    pregnant = bool(data.get("pregnant"))
    lactating = bool(data.get("lactating"))
    check_state_against(cap_set, name=data["name"], pregnant=pregnant, lactating=lactating)
    identifiers = identifier_service.collect(identifiers_in or [], tag, cap_set)
    # Every animal gets the farm's next number — the human-readable ID on
    # its QR label — whatever else it carries; no tag has to be scanned or
    # typed to register it.
    identifiers = identifier_service.with_farm_number(db, user.farm_id, identifiers)
    identifier_service.ensure_unique(db, user.farm_id, identifiers)

    opening = {k: data.pop(k, None) for k in _OPENING_STATE_FIELDS}
    group_name = data.pop("group_name", None)
    if not user_can(db, user, perms.FINANCE, perms.CREATE):
        for field in FINANCIAL_FIELDS:
            data.pop(field, None)

    animal = models.Animal(id=new_id(), farm_id=user.farm_id, lifecycle_status="active", **data)
    db.add(animal)
    db.flush()
    at = ensure_utc(registered_at) if registered_at else None
    livestock_state_service.open_initial(db, animal, at=at, user_id=user.id)
    identifier_service.attach(db, animal, identifiers)
    if animal.weight_kg:
        health_case_service.record_weight(db, animal.farm_id, animal, weight_kg=animal.weight_kg, method="scale", source_type="animal_update", user_id=user.id)
    breeding = None
    if opening["service_date"] is not None:
        breeding = reproduction_service.record_breeding(
            db, animal, event_type=opening["service_type"] or "ARTIFICIAL_INSEMINATION", at=opening["service_date"], user=user,
        )
    reproduction_service.open_registration_state(
        db, animal, pregnant=pregnant, pregnancy_days=opening["pregnancy_days"], lactating=lactating,
        lactation_cycle=opening["lactation_cycle"], user_id=user.id, breeding=breeding if pregnant else None,
    )
    if group_name and group_name.strip():
        group_service.move_by_name(db, animal, group_name, user_id=user.id, review=False)
    write_event(
        db, farm_id=user.farm_id, entity_type="animal", entity_id=animal.id, event_type="animal_created",
        payload={"tag": animal.tag, "name": animal.name, "species": animal.species, "source": source}, created_by=user.id,
    )
    write_audit_log(
        db, farm_id=user.farm_id, user_id=user.id, action="animal_created", entity_type="animal", entity_id=animal.id,
        module_code=perms.ANIMALS, summary=audit_summary or f"{user.name} created {animal.name} #{animal.tag}",
    )
    return animal
