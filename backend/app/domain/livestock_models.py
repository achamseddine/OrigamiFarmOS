"""Tables for the generic animal model (docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md).

`animals` and `flocks` stay where they are in models.py — this module adds
the configuration that describes them: what species exist, what each can
be identified by and participate in, and the identifiers an individual
animal actually carries.

Natural keys on purpose. `species.code` is the string every existing row,
endpoint and tablet screen already uses (`cow`, `layer_hen`); making it
the primary key gives referential integrity without renaming a column the
whole product depends on. The spec allows exactly this: "Referential
integrity is more important than forcing a specific ORM pattern."
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, Boolean, DateTime, ForeignKey, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


class Species(Base):
    """A kind of animal the farm may keep. Adding one is a row, not a
    module (tech spec §14)."""

    __tablename__ = "species"

    code: Mapped[str] = mapped_column(String(30), primary_key=True)
    name_en: Mapped[str] = mapped_column(String(80))
    name_ar: Mapped[str] = mapped_column(String(80))
    # viviparous | oviparous | unspecified — drives the resolver's
    # biological invariants, which configuration cannot override.
    reproduction_mode: Mapped[str] = mapped_column(String(20), default="unspecified")
    # A hint for the tablet's icon map (cow, goat, sheep, horse, poultry,
    # duck, barn). Presentation, not behaviour.
    icon: Mapped[str] = mapped_column(String(30), default="barn")
    # individual | group | either — what the Add Animal flow offers first.
    default_management: Mapped[str] = mapped_column(String(20), default="either")
    # {"birth_en": "Calving", "offspring_en": "Calf", "group_en": "Herd", …}
    terminology_json: Mapped[dict] = mapped_column(JSON, default=dict)
    # Management profile codes the Add Animal flow offers for this species;
    # empty means all. A horse is never offered "broiler".
    profiles_json: Mapped[list] = mapped_column(JSON, default=list)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    sort_order: Mapped[int] = mapped_column(Integer, default=100)


class Breed(Base):
    __tablename__ = "breeds"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    species_code: Mapped[str] = mapped_column(String(30), ForeignKey("species.code"))
    name: Mapped[str] = mapped_column(String(100))
    name_ar: Mapped[str | None] = mapped_column(String(100), nullable=True)
    active: Mapped[bool] = mapped_column(Boolean, default=True)


class LifeStage(Base):
    """Generic stages (newborn/young/adult/senior). A species may add its
    own, scoped by `species_code`; the resolver treats both alike."""

    __tablename__ = "life_stages"

    code: Mapped[str] = mapped_column(String(30), primary_key=True)
    species_code: Mapped[str | None] = mapped_column(String(30), ForeignKey("species.code"), nullable=True)
    label_en: Mapped[str] = mapped_column(String(80))
    label_ar: Mapped[str] = mapped_column(String(80))
    sort_order: Mapped[int] = mapped_column(Integer, default=100)


class ManagementProfile(Base):
    """Why the farm keeps the animal — dairy, meat, layer, breeding… It is
    the fourth input to the resolver alongside species, sex and stage."""

    __tablename__ = "management_profiles"

    code: Mapped[str] = mapped_column(String(30), primary_key=True)
    species_code: Mapped[str | None] = mapped_column(String(30), ForeignKey("species.code"), nullable=True)
    label_en: Mapped[str] = mapped_column(String(80))
    label_ar: Mapped[str] = mapped_column(String(80))


class Capability(Base):
    __tablename__ = "capabilities"

    code: Mapped[str] = mapped_column(String(40), primary_key=True)
    # identification | reproduction | production | health | management
    category: Mapped[str] = mapped_column(String(30))
    label_en: Mapped[str] = mapped_column(String(80))
    label_ar: Mapped[str] = mapped_column(String(80))
    active: Mapped[bool] = mapped_column(Boolean, default=True)


class SpeciesCapabilityRule(Base):
    """One line of configuration: for this species (and optionally this
    sex / stage / profile), this capability is on or off, and required or
    not. Among matching rules that grant it, the most specific wins and
    `priority` breaks ties; a matching rule that disables it is a veto."""

    __tablename__ = "species_capability_rules"
    __table_args__ = (Index("ix_species_capability_rules_species", "species_code"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    species_code: Mapped[str] = mapped_column(String(30), ForeignKey("species.code"))
    capability_code: Mapped[str] = mapped_column(String(40), ForeignKey("capabilities.code"))
    sex: Mapped[str | None] = mapped_column(String(5), nullable=True)
    life_stage: Mapped[str | None] = mapped_column(String(30), ForeignKey("life_stages.code"), nullable=True)
    management_profile: Mapped[str | None] = mapped_column(
        String(30), ForeignKey("management_profiles.code"), nullable=True
    )
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    required: Mapped[bool] = mapped_column(Boolean, default=False)
    configuration_json: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    priority: Mapped[int] = mapped_column(Integer, default=0)


class AnimalIdentifier(Base):
    """An identifier an individual animal carries (tech spec §4). A cow
    may have a farm number, an ear tag and an RFID; a mare a name, a
    microchip and a passport. All are rows here, none a column on
    `animals`. Uniqueness is enforced in code per farm, type and issuing
    authority — a farm number is unique on one farm, an RFID everywhere."""

    __tablename__ = "animal_identifiers"
    __table_args__ = (
        Index("ix_animal_identifiers_animal", "animal_id"),
        Index("ix_animal_identifiers_lookup", "identifier_type", "identifier_value"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    animal_id: Mapped[str] = mapped_column(String(36), ForeignKey("animals.id"))
    identifier_type: Mapped[str] = mapped_column(String(30))
    identifier_value: Mapped[str] = mapped_column(String(120))
    issuing_authority: Mapped[str | None] = mapped_column(String(120), nullable=True)
    valid_from: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    valid_to: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    is_primary: Mapped[bool] = mapped_column(Boolean, default=False)
    # active | retired — a replaced ear tag is retired, never deleted, so
    # a record that names the old tag still resolves.
    status: Mapped[str] = mapped_column(String(20), default="active")
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
