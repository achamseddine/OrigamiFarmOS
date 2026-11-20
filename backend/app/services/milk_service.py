"""Milk records: the checks a milking must pass, and corrections.

The same rules hold for milk recorded today and for a correction made
later — a corrected record must still be milk an animal in milk could
give, outside withdrawal unless withheld, dated within her lactation and
not in the future — so both go through [ensure_milk_allowed].

A correction changes the record in place and keeps the full before/after
in the audit log and the event stream (handbook: "Preserve history"):
every total, chart and analysis reads milk_records, so the corrected
value is what they count, and who changed what, from what, why and with
whose approval stays on file.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core import duplicates
from app.core import permissions as perms
from app.core.record_time import not_in_future
from app.domain import models
from app.livestock.catalog import Cap
from app.repositories.base import ensure_utc, write_audit_log, write_event
from app.schemas.production import ALLOWED_MILK_DESTINATIONS, MAX_LITERS_PER_MILKING, MILK_SESSIONS
from app.services import capability_service, livestock_state_service, reproduction_service
from app.services.feed_inventory_service import FeedError

CORRECTABLE = ("animal_id", "session", "liters", "destination", "recorded_at")


class MilkError(FeedError):
    pass


def ensure_milk_allowed(db: Session, animal: models.Animal, recorded_at: datetime | None, destination: str) -> bool:
    """Refuses milk the animal cannot have given; returns whether she is
    under withdrawal (the milk is then only accepted as withheld)."""
    livestock_state_service.ensure_on_farm(animal, "milk")
    # Milk is a capability (generic animal model §12): a bull, a hen, a
    # meat ewe or a mare cannot have a milk record, however the form was
    # filled in.
    cap_set = capability_service.resolve_for_animal(db, animal)
    if not cap_set.has(Cap.MILK_PRODUCTION):
        raise MilkError(capability_service.describe_missing(cap_set, Cap.MILK_PRODUCTION, animal.name), 422)

    # Milk belongs to a lactation (PRODUCTION-SCHEMA §8): the round, the
    # days in milk and the dry-off plan all read "in milk" from the record,
    # so milk from an animal that is not being milked is refused with what
    # to do instead — never a second, silent idea of who is in milk.
    lactation = reproduction_service.active_lactation(db, animal.id)
    if lactation is None and not animal.lactating:
        raise MilkError(
            f"{animal.name} is not recorded as being milked. Start her milking first (her profile → Is she being milked? → "
            "Producing milk), then record the milk.",
            409,
        )
    if lactation is not None and recorded_at is not None and recorded_at < ensure_utc(lactation.started_at) - timedelta(days=1):
        raise MilkError(
            f"{animal.name} started this lactation on {ensure_utc(lactation.started_at).date().isoformat()}; milk cannot be dated before it. "
            "If she calved earlier, correct the calving date on her profile.",
            422,
        )

    under_withdrawal = animal.withdrawal_until is not None and ensure_utc(animal.withdrawal_until) > datetime.now(timezone.utc)
    # Server-side safety gate, including when an offline tablet is stale.
    if under_withdrawal and destination != "withheld":
        raise MilkError(
            f"{animal.name} is under withdrawal until {animal.withdrawal_until.isoformat()}. "
            "Record this milk as withheld; it must not enter stored, sold, processed or consumed stock.",
            422,
        )
    return under_withdrawal


def get_record(db: Session, record_id: str, farm_id: str) -> tuple[models.MilkRecord, models.Animal]:
    record = db.get(models.MilkRecord, record_id)
    animal = db.get(models.Animal, record.animal_id) if record is not None else None
    if record is None or animal is None or animal.farm_id != farm_id:
        raise MilkError("Milk record not found", 404)
    return record, animal


def proposed_values(record: models.MilkRecord, changes: dict) -> dict:
    """The record as it would read after [changes] (only the fields a
    correction may change; unset ones keep their value)."""
    out = {k: getattr(record, k) for k in CORRECTABLE}
    for k in CORRECTABLE:
        if changes.get(k) is not None:
            out[k] = changes[k]
    return out


def validate_correction(db: Session, record: models.MilkRecord, changes: dict, farm_id: str) -> tuple[dict, models.Animal]:
    """Checks a correction before it is applied or sent for approval."""
    new = proposed_values(record, changes)
    if all(new[k] == getattr(record, k) or (k == "recorded_at" and ensure_utc(new[k]) == ensure_utc(getattr(record, k))) for k in CORRECTABLE):
        raise MilkError("The correction changes nothing: give the right amount, session, destination, day or animal.")
    if new["session"] not in MILK_SESSIONS:
        raise MilkError(f"session must be one of {sorted(MILK_SESSIONS)}")
    if new["destination"] not in ALLOWED_MILK_DESTINATIONS:
        raise MilkError(f"destination must be one of {sorted(ALLOWED_MILK_DESTINATIONS)}")
    liters = float(new["liters"])
    if liters < 0:
        raise MilkError("liters cannot be negative")
    if liters > MAX_LITERS_PER_MILKING:
        raise MilkError(f"{liters:g} L is more than one animal gives in one milking — check the amount")
    animal = db.get(models.Animal, new["animal_id"])
    if animal is None or animal.farm_id != farm_id:
        raise MilkError("Animal not found", 404)
    at = not_in_future(ensure_utc(new["recorded_at"]), "Milk")
    ensure_milk_allowed(db, animal, at, new["destination"])
    return new, animal


def apply_correction(db: Session, record: models.MilkRecord, changes: dict, *, reason: str, user: models.User,
                     requested_by: str | None = None, approval_request_id: str | None = None) -> models.MilkRecord:
    """Corrects [record] in place; the before/after goes to the audit log
    and the event stream. [requested_by] is the employee whose request the
    manager [user] approved, when there was one."""
    if not reason or not reason.strip():
        raise MilkError("Say why the milk record is corrected.")
    new, animal = validate_correction(db, record, changes, user.farm_id)
    # Moving it onto another session or day must not create a second record
    # of a milking already on file.
    if (new["session"], ensure_utc(new["recorded_at"]).date(), new["animal_id"]) != (record.session, ensure_utc(record.recorded_at).date(), record.animal_id):
        day_start, day_end = duplicates.farm_day(db, animal.farm_id, ensure_utc(new["recorded_at"]))
        clash = db.scalar(select(models.MilkRecord).where(
            models.MilkRecord.animal_id == new["animal_id"], models.MilkRecord.session == new["session"], models.MilkRecord.id != record.id,
            models.MilkRecord.recorded_at >= day_start, models.MilkRecord.recorded_at < day_end))
        if clash is not None:
            raise MilkError(f"{animal.name}'s {new['session']} milk is already recorded for that day ({clash.liters:g} L); correct that record instead.", 409)
    changed = {}
    for k in CORRECTABLE:
        before, after = getattr(record, k), new[k]
        if k == "recorded_at":
            before, after = ensure_utc(before), ensure_utc(after)
            if before == after:
                continue
            changed[k] = {"from": before.isoformat(), "to": after.isoformat()}
            record.recorded_at = after
            continue
        if before != after:
            changed[k] = {"from": before, "to": after}
            setattr(record, k, float(after) if k == "liters" else after)
    db.flush()
    write_audit_log(db, farm_id=animal.farm_id, user_id=user.id, action="milk_record_corrected", entity_type="milk_record", entity_id=record.id,
                    module_code=perms.MILK_PRODUCTION, summary=f"Milk record of {animal.name} corrected: {reason.strip()}"[:500], changes=changed,
                    metadata={"reason": reason.strip(), "requested_by": requested_by, "approved_by": user.id if requested_by else None,
                              "approval_request_id": approval_request_id})
    write_event(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type="milk_record_corrected",
                payload={"milk_record_id": record.id, "changes": changed, "reason": reason.strip(), "requested_by": requested_by,
                         "approval_request_id": approval_request_id}, created_by=user.id)
    return record
