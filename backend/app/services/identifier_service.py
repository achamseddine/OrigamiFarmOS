"""Identifiers an animal carries — attaching, replacing, and keeping them
unique (generic animal model §4, §12).

The rules the resolver hands over (`allowed_identifier_types`,
`required_identifier_types`) are enforced here; the router only asks.
"""
from __future__ import annotations

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import livestock_models as lm
from app.domain import models
from app.repositories.base import new_id
from app.schemas.livestock import IdentifierIn
from app.services.capability_service import CapabilitySet


def legacy_tag_type(cap_set: CapabilitySet) -> str:
    """What an older client's bare `tag` means for this animal: an ear tag
    where the species wears one, a leg band where it wears that, and a
    farm number otherwise. Deterministic, so the same tablet always maps
    the same way."""
    allowed = cap_set.allowed_identifier_types()
    for candidate in ("EAR_TAG", "LEG_BAND"):
        if candidate in allowed:
            return candidate
    return "FARM_NUMBER"


def collect(
    payload_identifiers: list[IdentifierIn],
    legacy_tag: str | None,
    cap_set: CapabilitySet,
    *,
    check_required: bool = True,
) -> list[IdentifierIn]:
    """Merges the identifier list with a legacy `tag`, checks every type is
    permitted for this animal and — at registration — that every required
    type is present, and settles which one is primary. Adding one more
    identifier to an animal that already has its ear tag passes
    `check_required=False`; the retire endpoint guards the other direction."""
    identifiers = list(payload_identifiers)
    if legacy_tag:
        identifiers.append(IdentifierIn(identifier_type=legacy_tag_type(cap_set), identifier_value=legacy_tag))

    allowed = cap_set.allowed_identifier_types()
    for ident in identifiers:
        if ident.identifier_type not in allowed:
            label = ident.identifier_type.replace("_", " ").lower()
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                f"A {label} is not used for this kind of animal. Allowed: {', '.join(sorted(allowed)).lower()}.",
            )

    present = {i.identifier_type for i in identifiers}
    missing = cap_set.required_identifier_types() - present if check_required else set()
    if missing:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"This animal must have a {', '.join(m.replace('_', ' ').lower() for m in sorted(missing))} to be registered.",
        )

    # Exactly one primary: the one marked, else the first.
    if identifiers and not any(i.is_primary for i in identifiers):
        identifiers[0] = identifiers[0].model_copy(update={"is_primary": True})
    primaries = [i for i in identifiers if i.is_primary]
    if len(primaries) > 1:
        keep = primaries[0]
        identifiers = [i if i is keep else i.model_copy(update={"is_primary": False}) for i in identifiers]
    return identifiers


def find_clash(
    db: Session,
    farm_id: str,
    identifier_type: str,
    value: str,
    issuing_authority: str | None,
    exclude_animal_id: str | None = None,
) -> models.Animal | None:
    """Another active animal on this farm carrying the same identifier.
    Scope is (farm, type, issuing authority): farm number 744 may exist on
    two farms; RFID 982000123456789 issued by one authority may not."""
    stmt = (
        select(models.Animal)
        .join(lm.AnimalIdentifier, lm.AnimalIdentifier.animal_id == models.Animal.id)
        .where(
            models.Animal.farm_id == farm_id,
            models.Animal.active.is_(True),
            lm.AnimalIdentifier.status == "active",
            lm.AnimalIdentifier.identifier_type == identifier_type,
            lm.AnimalIdentifier.identifier_value == value,
        )
    )
    if issuing_authority is None:
        stmt = stmt.where(lm.AnimalIdentifier.issuing_authority.is_(None))
    else:
        stmt = stmt.where(lm.AnimalIdentifier.issuing_authority == issuing_authority)
    if exclude_animal_id:
        stmt = stmt.where(models.Animal.id != exclude_animal_id)
    return db.scalars(stmt).first()


def ensure_unique(db: Session, farm_id: str, identifiers: list[IdentifierIn], exclude_animal_id: str | None = None) -> None:
    for ident in identifiers:
        clash = find_clash(db, farm_id, ident.identifier_type, ident.identifier_value, ident.issuing_authority, exclude_animal_id)
        if clash is not None:
            label = ident.identifier_type.replace("_", " ").lower()
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"{label.capitalize()} '{ident.identifier_value}' is already used by {clash.name}.",
            )


def attach(db: Session, animal: models.Animal, identifiers: list[IdentifierIn]) -> None:
    for ident in identifiers:
        db.add(
            lm.AnimalIdentifier(
                id=new_id(),
                animal_id=animal.id,
                identifier_type=ident.identifier_type,
                identifier_value=ident.identifier_value,
                issuing_authority=ident.issuing_authority,
                valid_from=ident.valid_from,
                valid_to=ident.valid_to,
                is_primary=ident.is_primary,
                notes=ident.notes,
            )
        )
    db.flush()
    sync_tag(db, animal)


def active_identifiers(db: Session, animal_id: str) -> list[lm.AnimalIdentifier]:
    return list(
        db.scalars(
            select(lm.AnimalIdentifier)
            .where(lm.AnimalIdentifier.animal_id == animal_id, lm.AnimalIdentifier.status == "active")
            .order_by(lm.AnimalIdentifier.is_primary.desc(), lm.AnimalIdentifier.created_at)
        )
    )


def sync_tag(db: Session, animal: models.Animal) -> None:
    """`animals.tag` mirrors the primary identifier's value so lists and
    search keep working unchanged. If nothing is primary, the first
    active identifier is promoted."""
    active = active_identifiers(db, animal.id)
    if not active:
        animal.tag = None
        return
    primary = next((i for i in active if i.is_primary), None)
    if primary is None:
        primary = active[0]
        primary.is_primary = True
    for other in active:
        if other is not primary and other.is_primary:
            other.is_primary = False
    animal.tag = primary.identifier_value


def replace_primary_value(db: Session, animal: models.Animal, new_value: str, cap_set: CapabilitySet) -> None:
    """An older client editing `tag`: the old primary is retired, not
    erased — a treatment record that names the old tag still resolves —
    and a new primary of the same type takes its place."""
    active = active_identifiers(db, animal.id)
    primary = next((i for i in active if i.is_primary), None)
    identifier_type = primary.identifier_type if primary else legacy_tag_type(cap_set)
    replacement = IdentifierIn(identifier_type=identifier_type, identifier_value=new_value, is_primary=True)
    ensure_unique(db, animal.farm_id, [replacement], exclude_animal_id=animal.id)
    if primary is not None:
        if primary.identifier_value == new_value:
            return
        primary.status = "retired"
        primary.is_primary = False
    attach(db, animal, [replacement])
