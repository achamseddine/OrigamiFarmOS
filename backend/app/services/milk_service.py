"""Milk records: the checks a milking must pass, and corrections.

The same rules hold for milk recorded today, milk entered later from a
paper sheet, milk replayed by an offline tablet and a correction — a
record must be milk the animal could give at its own milking time: within a
lactation that covered that time, withheld if a recorded withdrawal
covered it, held for review if her records cannot vouch for it, and not in
the future — so all of them go through [check_milk] (v0.8.5, ADR-005,
milk_safety_service).

A correction changes the record in place and keeps the full before/after
in the audit log and the event stream (handbook: "Preserve history"):
every total, chart and analysis reads milk_records, so the corrected
value is what they count, and who changed what, from what, why and with
whose approval stays on file.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core import duplicates
from app.core import permissions as perms
from app.core.record_time import not_in_future
from app.domain import models
from app.domain import reproduction_models as rm
from app.livestock.catalog import Cap
from app.repositories.base import ensure_utc, now, write_audit_log, write_event
from app.schemas.production import ALLOWED_MILK_DESTINATIONS, MAX_LITERS_PER_MILKING, MILK_SESSIONS
from app.services import capability_service, livestock_state_service
from app.services import milk_safety_service as safety
from app.services.feed_inventory_service import FeedError

CORRECTABLE = ("animal_id", "session", "liters", "destination", "recorded_at")


class MilkError(FeedError):
    pass


@dataclass
class MilkCheck:
    """What the server found for one milking: the withdrawal status at its
    own timestamp, the lactation it belongs to, and whether it may be sold."""

    assessment: safety.Assessment
    lactation: rm.LactationEpisode | None
    release_status: str

    @property
    def under_withdrawal(self) -> bool:
        return self.assessment.status != safety.CLEAR


def check_milk(db: Session, animal: models.Animal, recorded_at: datetime | None, destination: str) -> MilkCheck:
    """Refuses milk the animal cannot have given, judged at the milking's
    own time (v0.8.5, milk_safety_service): she is on the farm, able to
    give milk, within a lactation that covers that time — active or since
    ended — and, if a recorded withdrawal covers it, the milk is withheld.
    Milk an uncertain withdrawal covers is kept but held for review."""
    livestock_state_service.ensure_on_farm(animal, "milk")
    # Milk is a capability (generic animal model §12): a bull, a hen, a
    # meat ewe or a mare cannot have a milk record, however the form was
    # filled in.
    cap_set = capability_service.resolve_for_animal(db, animal)
    if not cap_set.has(Cap.MILK_PRODUCTION):
        raise MilkError(capability_service.describe_missing(cap_set, Cap.MILK_PRODUCTION, animal.name), 422)
    at = ensure_utc(recorded_at) if recorded_at is not None else now()

    # Milk belongs to a lactation (PRODUCTION-SCHEMA §8, ADR-005): the one
    # that covers the milking time — the current one or one since ended, so
    # milk noted on paper before yesterday's dry-off can still be entered.
    lactation = safety.lactation_at(db, animal, at)
    if lactation.problem:
        raise MilkError(lactation.problem, lactation.status_code)

    # Withdrawal at the milking time, from the dated veterinary history —
    # not the animal's record today. Server-side, so a stale offline tablet
    # and a late entry are judged like a live one.
    assessment = safety.assess(db, animal, at)
    if assessment.status == safety.WITHDRAWAL and destination != "withheld":
        raise MilkError(
            f"{assessment.note(animal.name)} Record this milk as withheld; it must not enter stored, sold, processed or consumed stock.",
            422,
        )
    return MilkCheck(assessment, lactation.episode, safety.release_status_for(assessment.status, destination))


def ensure_milk_allowed(db: Session, animal: models.Animal, recorded_at: datetime | None, destination: str) -> bool:
    """[check_milk], answering only whether a withdrawal (recorded or
    uncertain) covers the milking."""
    return check_milk(db, animal, recorded_at, destination).under_withdrawal


def apply_check(record: models.MilkRecord, check: MilkCheck, animal: models.Animal) -> None:
    """Writes what the server found onto the record (never the client)."""
    record.withdrawal_check = check.assessment.status
    record.release_status = check.release_status
    note = check.assessment.note(animal.name)
    record.safety_note = note[:1000] if note else None
    record.checked_at = now()
    record.lactation_episode_id = check.lactation.id if check.lactation is not None else None


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
    check_milk(db, animal, at, new["destination"])
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
    # A corrected milking is judged again at its (possibly new) time: a
    # release a reviewer gave stands only while the animal and the time
    # stay the same; otherwise the server's new answer applies.
    before_status = record.release_status
    keep_release = before_status == safety.RELEASED and "animal_id" not in changed and "recorded_at" not in changed
    check = check_milk(db, animal, ensure_utc(record.recorded_at), record.destination)
    apply_check(record, check, animal)
    if keep_release and record.release_status == safety.HELD:
        record.release_status = safety.RELEASED
    elif record.release_status != safety.RELEASED:
        record.reviewed_by = record.reviewed_at = record.review_note = None
    if record.release_status != before_status:
        changed["release_status"] = {"from": before_status, "to": record.release_status}
    db.flush()
    write_audit_log(db, farm_id=animal.farm_id, user_id=user.id, action="milk_record_corrected", entity_type="milk_record", entity_id=record.id,
                    module_code=perms.MILK_PRODUCTION, summary=f"Milk record of {animal.name} corrected: {reason.strip()}"[:500], changes=changed,
                    metadata={"reason": reason.strip(), "requested_by": requested_by, "approved_by": user.id if requested_by else None,
                              "approval_request_id": approval_request_id})
    write_event(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type="milk_record_corrected",
                payload={"milk_record_id": record.id, "changes": changed, "reason": reason.strip(), "requested_by": requested_by,
                         "approval_request_id": approval_request_id}, created_by=user.id)
    return record


# ------------------------------------------------------- held for review
def held_records(db: Session, farm_id: str) -> list[tuple[models.MilkRecord, models.Animal]]:
    """Milk kept but not saleable until reviewed (v0.8.5), oldest first."""
    return list(db.execute(
        select(models.MilkRecord, models.Animal).join(models.Animal, models.Animal.id == models.MilkRecord.animal_id)
        .where(models.Animal.farm_id == farm_id, models.MilkRecord.release_status == safety.HELD)
        .order_by(models.MilkRecord.recorded_at)
    ).all())


def review(db: Session, record: models.MilkRecord, *, decision: str, note: str | None, user: models.User) -> models.MilkRecord:
    """A veterinarian or the farm manager decides held milk:

    release   it may be sold — refused while a recorded withdrawal covers
              the milking (that window is the prescription's; a wrong one is
              corrected on the treatment or dose, never cleared here)
    withhold  it is withheld (a correction of its destination, on file)

    The reason is required and kept with the record, the audit log and the
    event stream. The server never releases milk by itself."""
    if decision not in ("release", "withhold"):
        raise MilkError("decision must be release or withhold")
    note = (note or "").strip()
    if not note:
        raise MilkError("Say why — it stays on the record with the milk.")
    if user.role not in safety.REVIEW_ROLES:
        raise MilkError("Held milk is released or withheld by a veterinarian or the farm manager.", 403)
    if record.release_status != safety.HELD:
        raise MilkError(f"This milk is not held for review (it is {record.release_status}).", 409)
    animal = db.get(models.Animal, record.animal_id)
    if decision == "withhold":
        apply_correction(db, record, {"destination": "withheld"}, reason=f"Held milk withheld after review: {note}", user=user)
        record.reviewed_by, record.reviewed_at, record.review_note = user.id, now(), note
        return record
    assessment = safety.assess(db, animal, record.recorded_at)
    if assessment.status == safety.WITHDRAWAL:
        raise MilkError(f"{assessment.note(animal.name)} Milk a recorded withdrawal covers cannot be released; if the dose or treatment was "
                        "recorded wrongly, the veterinarian corrects that record first.", 409)
    record.release_status = safety.RELEASED
    record.withdrawal_check = assessment.status
    record.reviewed_by, record.reviewed_at, record.review_note = user.id, now(), note
    write_audit_log(db, farm_id=animal.farm_id, user_id=user.id, action="milk_released", entity_type="milk_record", entity_id=record.id,
                    module_code=perms.MILK_PRODUCTION, summary=f"{record.liters:g} L of {animal.name}'s milk released after review: {note}"[:500],
                    changes={"release_status": {"from": safety.HELD, "to": safety.RELEASED}},
                    metadata={"withdrawal_check": assessment.status, "note": note})
    write_event(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type="milk_released",
                payload={"milk_record_id": record.id, "liters": record.liters, "note": note, "withdrawal_check": assessment.status},
                created_by=user.id)
    return record


def legacy_review(db: Session, farm_id: str, *, days: int = 365) -> dict:
    """Milk recorded before v0.8.5 (`unchecked`) that the dated veterinary
    history now says was under withdrawal, or cannot confirm. Read only: it
    changes no record, no tank figure and no sale — each line is for the
    manager and the veterinarian to decide (docs/runbooks/MILK-SAFETY-REVIEW.md)."""
    since = now() - timedelta(days=days)
    rows = db.execute(
        select(models.MilkRecord, models.Animal).join(models.Animal, models.Animal.id == models.MilkRecord.animal_id)
        .where(models.Animal.farm_id == farm_id, models.MilkRecord.withdrawal_check == safety.UNCHECKED,
               models.MilkRecord.destination != "withheld", models.MilkRecord.recorded_at >= since)
        .order_by(models.MilkRecord.recorded_at)
    ).all()
    findings = []
    for rec, animal in rows:
        a = safety.assess(db, animal, rec.recorded_at)
        if a.status == safety.CLEAR:
            continue
        findings.append({"milk_record_id": rec.id, "animal_id": animal.id, "animal_name": animal.name, "recorded_at": rec.recorded_at,
                         "session": rec.session, "liters": rec.liters, "destination": rec.destination, **a.to_dict(animal.name)})
    return {"since": since, "checked": len(rows), "findings": findings,
            "withdrawal_l": round(sum(f["liters"] for f in findings if f["withdrawal_check"] == safety.WITHDRAWAL), 1),
            "uncertain_l": round(sum(f["liters"] for f in findings if f["withdrawal_check"] == safety.UNCERTAIN), 1)}
