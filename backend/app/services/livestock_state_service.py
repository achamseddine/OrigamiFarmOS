"""Effective-dated animal state and the animal's exit from the farm
(database/LIVESTOCK-SCHEMA.md §5, §14; BEHAVIORAL-MODEL §14).

`animals.lifecycle_status`, `life_stage`, `management_profile` and
`location_label` are operational current values. A change to any of them
goes through [record]: validate, close the open history range, open the
new one, update the current field, emit the event — in one transaction,
never the current field alone (§14 "Do not update only the current field").

An exit (sold, dead, culled, slaughtered, transferred) is explicit
(behavioural model §14): it closes the animal's group memberships, its
active lactation and pregnancy and its feeding assignments, blocks future
ordinary production and feeding, and keeps every record made before it.
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import livestock_models as lm
from app.domain import models
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event
from app.services.feed_inventory_service import FeedError

STATUS = "STATUS"
LIFE_STAGE = "LIFE_STAGE"
MANAGEMENT_PROFILE = "MANAGEMENT_PROFILE"
LOCATION = "LOCATION"
STATE_TYPES = (STATUS, LIFE_STAGE, MANAGEMENT_PROFILE, LOCATION)

ACTIVE = "active"
ARCHIVED = "archived"
# exit type -> the quantity event a hybrid or quantity-managed group the
# animal belonged to records for it (LIVESTOCK-SCHEMA §9).
EXIT_TYPES = {
    "dead": "DEATH",
    "sold": "SALE",
    "culled": "CULL",
    "slaughtered": "SLAUGHTER",
    "transferred": "TRANSFER_OUT",
}
# A death is a fact anyone looking after the animal may record; the others
# are management decisions (see api/v1/livestock_history.py).
FACT_EXITS = frozenset({"dead"})


class LivestockError(FeedError):
    """A livestock rule refused the operation. Carries a sentence for the
    farmer; main.py answers it as `detail` with its status code."""


def _apply(animal: models.Animal, state_type: str, value: str | None, reference_id: str | None) -> None:
    if state_type == STATUS:
        animal.lifecycle_status = value or ACTIVE
    elif state_type == LIFE_STAGE:
        animal.life_stage = value
    elif state_type == MANAGEMENT_PROFILE:
        animal.management_profile = value
    elif state_type == LOCATION:
        animal.location_label = value
        animal.location_id = reference_id


def current(db: Session, animal_id: str, state_type: str) -> lm.AnimalStateHistory | None:
    db.flush()  # the session does not autoflush; a range closed in this transaction must read as closed
    return db.scalar(select(lm.AnimalStateHistory).where(
        lm.AnimalStateHistory.animal_id == animal_id, lm.AnimalStateHistory.state_type == state_type,
        lm.AnimalStateHistory.effective_to.is_(None),
    ).order_by(lm.AnimalStateHistory.effective_from.desc()))


def record(db: Session, animal: models.Animal, state_type: str, value: str | None, *, reference_id: str | None = None,
           at: datetime | None = None, reason: str | None = None, source_type: str | None = None, source_id: str | None = None,
           user_id: str | None) -> lm.AnimalStateHistory | None:
    """One state change, written the §14 way. Returns the new history row,
    or None when the value did not change (an edit that re-sends the same
    stage writes nothing)."""
    if state_type not in STATE_TYPES:
        raise ValueError(f"Unknown state type {state_type}")
    at = ensure_utc(at) if at else now()
    if at > now():
        raise LivestockError("A change cannot be dated in the future.")
    open_row = current(db, animal.id, state_type)
    if open_row is not None and open_row.value_code == value and open_row.value_reference_id == reference_id:
        return None
    if open_row is None and value is None and reference_id is None:
        return None
    if open_row is not None:
        since = ensure_utc(open_row.effective_from)
        if at < since:
            raise LivestockError(
                f"{animal.name}'s {_label(state_type)} has been {open_row.value_code or 'unset'} since "
                f"{since.date().isoformat()}; a change cannot be dated before that."
            )
        open_row.effective_to = at
    row = lm.AnimalStateHistory(
        id=new_id(), farm_id=animal.farm_id, animal_id=animal.id, state_type=state_type, value_code=value,
        value_reference_id=reference_id, effective_from=at, reason_code=reason, source_type=source_type, source_id=source_id,
        recorded_at=now(), recorded_by=user_id,
    )
    db.add(row)
    previous = open_row.value_code if open_row is not None else None
    _apply(animal, state_type, value, reference_id)
    write_event(
        db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type=f"animal_{state_type.lower()}_changed",
        payload={"from": previous, "to": value, "effective_from": at.isoformat(), "reason": reason}, created_by=user_id or "system",
    )
    return row


def _label(state_type: str) -> str:
    return {STATUS: "status", LIFE_STAGE: "life stage", MANAGEMENT_PROFILE: "management profile", LOCATION: "location"}[state_type]


def open_initial(db: Session, animal: models.Animal, *, at: datetime | None = None, user_id: str | None) -> None:
    """The opening rows for a newly registered animal: what it was
    registered as, from the moment it was."""
    at = ensure_utc(at) if at else now()
    for state_type, value, ref in (
        (STATUS, animal.lifecycle_status or ACTIVE, None), (LIFE_STAGE, animal.life_stage, None),
        (MANAGEMENT_PROFILE, animal.management_profile, None), (LOCATION, animal.location_label, animal.location_id),
    ):
        if value is None and ref is None:
            continue
        db.add(lm.AnimalStateHistory(
            id=new_id(), farm_id=animal.farm_id, animal_id=animal.id, state_type=state_type, value_code=value, value_reference_id=ref,
            effective_from=at, reason_code="registered", source_type="registration", recorded_at=now(), recorded_by=user_id,
        ))


def history(db: Session, animal_id: str, state_type: str | None = None) -> list[lm.AnimalStateHistory]:
    stmt = select(lm.AnimalStateHistory).where(lm.AnimalStateHistory.animal_id == animal_id)
    if state_type:
        stmt = stmt.where(lm.AnimalStateHistory.state_type == state_type)
    return list(db.scalars(stmt.order_by(lm.AnimalStateHistory.effective_from.desc(), lm.AnimalStateHistory.recorded_at.desc())))


def history_dict(row: lm.AnimalStateHistory) -> dict:
    return {
        "id": row.id, "state_type": row.state_type, "value": row.value_code, "reference_id": row.value_reference_id,
        "effective_from": row.effective_from, "effective_to": row.effective_to, "reason": row.reason_code,
        "source_type": row.source_type, "source_id": row.source_id, "recorded_at": row.recorded_at, "recorded_by": row.recorded_by,
    }


# ------------------------------------------------------------------- exit
def exit_animal(db: Session, animal: models.Animal, exit_type: str, *, at: datetime | None = None, reason: str | None = None,
                notes: str | None = None, user: models.User) -> models.Animal:
    """Records that the animal left the farm. Everything recorded about it
    stays; what can no longer be true afterwards is closed."""
    if exit_type not in EXIT_TYPES and exit_type != ARCHIVED:
        raise LivestockError(f"exit_type must be one of {sorted(EXIT_TYPES)}")
    if not animal.active:
        raise LivestockError(f"{animal.name} already left the farm ({animal.lifecycle_status}).", 409)
    at = ensure_utc(at) if at else now()
    record(db, animal, STATUS, exit_type, at=at, reason=reason, source_type="exit", user_id=user.id)
    animal.active = False
    animal.exited_at = at
    _close_dependents(db, animal, exit_type, at=at, user_id=user.id)
    write_event(
        db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type="animal_exited",
        payload={"exit_type": exit_type, "occurred_at": at.isoformat(), "reason": reason, "notes": notes}, created_by=user.id,
    )
    write_audit_log(
        db, farm_id=animal.farm_id, user_id=user.id, action="animal_exited", entity_type="animal", entity_id=animal.id,
        module_code="animals", summary=f"{user.name} recorded {animal.name} as {exit_type}" + (f": {reason}" if reason else ""),
        changes={"lifecycle_status": {"from": ACTIVE, "to": exit_type}},
    )
    return animal


def _close_dependents(db: Session, animal: models.Animal, exit_type: str, *, at: datetime, user_id: str) -> None:
    from app.domain import feed_models as fm
    from app.services import feeding_program_service as feeding
    from app.services import group_service as groups
    from app.services import reproduction_service as repro

    groups.end_memberships_on_exit(db, animal, at=at, quantity_event=EXIT_TYPES.get(exit_type), reason=f"exit:{exit_type}", user_id=user_id)
    repro.on_exit(db, animal, at=at, user_id=user_id)
    for assignment in db.scalars(select(fm.FeedingAssignment).where(
        fm.FeedingAssignment.subject_type == "animal", fm.FeedingAssignment.subject_id == animal.id, fm.FeedingAssignment.status == "active",
    )).all():
        feeding.end_assignment(db, assignment, user_id=user_id, reason=f"animal {exit_type}")


def reactivate(db: Session, animal: models.Animal, *, at: datetime | None = None, reason: str | None = None, user: models.User) -> models.Animal:
    """Only an archived animal comes back. A sale or a death is a fact; a
    mistaken one is corrected by a manager re-registering, not by flipping
    it back — the exit and everything it closed stay on the record."""
    if animal.active:
        return animal
    if animal.lifecycle_status != ARCHIVED:
        raise LivestockError(
            f"{animal.name} left the farm as {animal.lifecycle_status}; only an archived animal can be restored.", 409,
        )
    record(db, animal, STATUS, ACTIVE, at=at, reason=reason or "restored", source_type="restore", user_id=user.id)
    animal.active = True
    animal.exited_at = None
    return animal


def ensure_on_farm(animal: models.Animal, action: str) -> None:
    """Behavioural model §14: an animal that left blocks ordinary
    production, feeding and reproduction afterwards."""
    if not animal.active:
        raise LivestockError(
            f"{animal.name} is no longer on the farm ({animal.lifecycle_status}"
            + (f" on {ensure_utc(animal.exited_at).date().isoformat()}" if animal.exited_at else "")
            + f"); {action} cannot be recorded.",
            409,
        )
