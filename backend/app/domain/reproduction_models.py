"""Reproduction and lactation (database/REPRODUCTION-SCHEMA.md,
PRODUCTION-SCHEMA.md §8).

Reproduction owns breeding, pregnancy, birth and incubation/hatch facts.
It stores no animal identity (that is `animals`), no production output
(milk is `milk_records`) and no diagnosis (that is health). The animal's
`pregnant` / `lactating` / due-date fields are a projection of the rows
here, refreshed by `services/reproduction_service.py` and never edited.

`lactation_episodes` is a production state (PRODUCTION-SCHEMA §8). It lives
in this module because the birth that usually starts it is here, and the
two are written in one transaction; it is still read by production and
feed as their own context, never as a reproduction record.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import CheckConstraint, DateTime, Float, ForeignKey, Index, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


class BreedingEvent(Base):
    """A heat seen, a mating, an insemination or an embryo transfer.
    Pregnancy is never inferred from it (REPRODUCTION-SCHEMA core
    invariant): only a pregnancy check opens a pregnancy."""

    __tablename__ = "breeding_events"
    __table_args__ = (Index("ix_breeding_events_female", "female_animal_id", "occurred_at"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    female_animal_id: Mapped[str] = mapped_column(String(36), ForeignKey("animals.id"))
    male_animal_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("animals.id"), nullable=True)
    # A sire that is not on this farm: a hired ram, an AI bull's name.
    sire_reference: Mapped[str | None] = mapped_column(String(120), nullable=True)
    # HEAT_OBSERVED | NATURAL_MATING | ARTIFICIAL_INSEMINATION | EMBRYO_TRANSFER
    event_type: Mapped[str] = mapped_column(String(40))
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    semen_batch_reference: Mapped[str | None] = mapped_column(String(120), nullable=True)
    technician_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    # recorded | voided — a mistaken entry is voided with a reason, never deleted.
    status: Mapped[str] = mapped_column(String(20), default="recorded")
    void_reason: Mapped[str | None] = mapped_column(String(200), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    recorded_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    correlation_id: Mapped[str | None] = mapped_column(String(36), nullable=True)


class PregnancyEpisode(Base):
    """One pregnancy, from the check that confirmed it to its outcome. At
    most one active episode per animal, enforced by the service."""

    __tablename__ = "pregnancy_episodes"
    __table_args__ = (Index("ix_pregnancy_episodes_animal", "animal_id", "status"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    animal_id: Mapped[str] = mapped_column(String(36), ForeignKey("animals.id"))
    originating_breeding_event_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("breeding_events.id"), nullable=True)
    # active | ended
    status: Mapped[str] = mapped_column(String(20), default="active")
    estimated_conception_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    expected_due_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # BIRTH | LOSS | ABORTION | NOT_PREGNANT | ANIMAL_EXITED
    outcome_code: Mapped[str | None] = mapped_column(String(30), nullable=True)
    # assessment | registration | backfill — how the episode came to exist.
    source: Mapped[str] = mapped_column(String(20), default="assessment")
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)


class PregnancyAssessment(Base):
    """A pregnancy check. A NEGATIVE result may exist with no episode;
    POSITIVE opens one (or refines the active one); NEGATIVE on an active
    episode ends it."""

    __tablename__ = "pregnancy_assessments"
    __table_args__ = (Index("ix_pregnancy_assessments_animal", "animal_id", "assessed_at"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    pregnancy_episode_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("pregnancy_episodes.id"), nullable=True)
    animal_id: Mapped[str] = mapped_column(String(36), ForeignKey("animals.id"))
    assessed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    # ULTRASOUND | PALPATION | BLOOD_TEST | OBSERVATION | REGISTRATION
    assessment_type: Mapped[str] = mapped_column(String(30))
    # POSITIVE | NEGATIVE | INCONCLUSIVE
    result_code: Mapped[str] = mapped_column(String(20))
    estimated_gestation_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    expected_due_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    examiner_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    recorded_by: Mapped[str | None] = mapped_column(String(36), nullable=True)


class BirthEvent(Base):
    """A calving, lambing, kidding or foaling — one generic record, the
    species' own word on screen (terminology on `species`)."""

    __tablename__ = "birth_events"
    __table_args__ = (
        Index("ix_birth_events_dam", "dam_animal_id", "occurred_at"),
        CheckConstraint("offspring_count >= 0 AND live_count >= 0 AND stillborn_count >= 0", name="ck_birth_counts_non_negative"),
        CheckConstraint("live_count + stillborn_count <= offspring_count", name="ck_birth_counts_add_up"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    dam_animal_id: Mapped[str] = mapped_column(String(36), ForeignKey("animals.id"))
    pregnancy_episode_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("pregnancy_episodes.id"), nullable=True)
    sire_animal_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("animals.id"), nullable=True)
    sire_reference: Mapped[str | None] = mapped_column(String(120), nullable=True)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    # NONE | EASY | ASSISTED | VETERINARY | CAESAREAN
    assistance_code: Mapped[str] = mapped_column(String(20), default="NONE")
    offspring_count: Mapped[int] = mapped_column(Integer)
    live_count: Mapped[int] = mapped_column(Integer)
    stillborn_count: Mapped[int] = mapped_column(Integer, default=0)
    status: Mapped[str] = mapped_column(String(20), default="recorded")
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    recorded_by: Mapped[str | None] = mapped_column(String(36), nullable=True)


class BirthOffspring(Base):
    """One newborn of a birth. A live, individually tracked newborn links
    to the `animals` row registered with it (now, or later from this
    row); a stillborn one, or one counted into a flock, has none."""

    __tablename__ = "birth_offspring"
    __table_args__ = (UniqueConstraint("birth_event_id", "sequence_no", name="uq_birth_offspring_sequence"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    birth_event_id: Mapped[str] = mapped_column(String(36), ForeignKey("birth_events.id"))
    offspring_animal_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("animals.id"), nullable=True)
    sequence_no: Mapped[int] = mapped_column(Integer)
    sex: Mapped[str | None] = mapped_column(String(5), nullable=True)
    birth_weight_kg: Mapped[float | None] = mapped_column(Float, nullable=True)
    # LIVE | STILLBORN | DIED_AFTER_BIRTH
    outcome_code: Mapped[str] = mapped_column(String(20))
    destination_group_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("flocks.id"), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)


class LactationEpisode(Base):
    """A lactation (PRODUCTION-SCHEMA §8), from its start — usually a
    birth — to dry-off. `lactation_number` is the parity the feed
    baselines read."""

    __tablename__ = "lactation_episodes"
    __table_args__ = (
        Index("ix_lactation_episodes_animal", "animal_id", "status"),
        CheckConstraint("ended_at IS NULL OR ended_at >= started_at", name="ck_lactation_range"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    animal_id: Mapped[str] = mapped_column(String(36), ForeignKey("animals.id"))
    birth_event_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("birth_events.id"), nullable=True)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # active | ended
    status: Mapped[str] = mapped_column(String(20), default="active")
    lactation_number: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # DRY_OFF | ANIMAL_EXITED | PROFILE_CHANGED
    end_reason_code: Mapped[str | None] = mapped_column(String(30), nullable=True)
    source: Mapped[str] = mapped_column(String(20), default="recorded")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    ended_by: Mapped[str | None] = mapped_column(String(36), nullable=True)


class IncubationBatch(Base):
    """Eggs set to hatch (REPRODUCTION-SCHEMA incubation_batch). Poultry
    reproduction runs through here — never through pregnancy."""

    __tablename__ = "incubation_batches"
    __table_args__ = (
        UniqueConstraint("farm_id", "code", name="uq_incubation_batch_code"),
        CheckConstraint("eggs_set > 0", name="ck_incubation_eggs_set_positive"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    # The species decides INCUBATION / HATCHING and the expected hatch
    # date; the source flock, when there is one, is where the eggs came from.
    species_code: Mapped[str] = mapped_column(String(30), ForeignKey("species.code"))
    source_group_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("flocks.id"), nullable=True)
    code: Mapped[str] = mapped_column(String(60))
    eggs_set: Mapped[int] = mapped_column(Integer)
    set_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expected_hatch_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # incubating | hatched | failed | cancelled
    status: Mapped[str] = mapped_column(String(20), default="incubating")
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)


class HatchEvent(Base):
    __tablename__ = "hatch_events"
    __table_args__ = (CheckConstraint("hatched_live >= 0", name="ck_hatch_live_non_negative"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    incubation_batch_id: Mapped[str] = mapped_column(String(36), ForeignKey("incubation_batches.id"))
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    hatched_live: Mapped[int] = mapped_column(Integer)
    unhatched: Mapped[int | None] = mapped_column(Integer, nullable=True)
    culled: Mapped[int | None] = mapped_column(Integer, nullable=True)
    destination_group_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("flocks.id"), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    recorded_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
