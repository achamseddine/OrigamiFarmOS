"""Is this milk safe, judged at the moment it was milked? (v0.8.5, ADR-005;
audit 2026-11-25 I-3 and I-15.)

A milking is judged from the animal's dated history, not from what her
record says today, so the same milking gets the same answer whether it is
entered at the parlour, a day later from a paper sheet, or replayed by a
tablet that was offline:

Withdrawal — the windows a veterinary fact put on her milk:

    a medicine administration (to her, or to a group she was in when the
    dose was given)   administered_at → withdrawal_milk_until   recorded
    a treatment with a withdrawal (to her, or her group)
                      start_at → withdrawal_until               recorded
    an administration recorded and then reversed
                      administered_at → withdrawal_milk_until   uncertain
                      (a reversal does not prove she was not dosed)
    her withdrawal_until when no dated milk window explains it (none, or
    a longer meat withdrawal on it)
                      ? → withdrawal_until                       recorded from
                      withdrawal_known_since, uncertain before it

    clear       no window covers the milking
    withdrawal  a recorded window covers it: the milk is withheld — any other
                destination is refused (422)
    uncertain   only an uncertain window covers it: the milk is kept but held
                for review; it is not saleable until a veterinarian or the farm
                manager releases it, saying why — the system never clears it

Overlapping medicines are each a window; the milk is clear only outside all
of them. The windows come from the authorised withdrawal rules the doses
and prescriptions carry; nothing here computes, shortens or invents one.

Lactation — milk belongs to a lactation episode that covers the milking
(from a day before it started to its dry-off), active or ended. Milk after
a dry-off, between two lactations or before the first is refused; an animal
milked before lactations were recorded (no episode, marked in milk) keeps
being accepted, as before.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.domain import livestock_models as lm
from app.domain import models
from app.domain import pharmacy_models as pm
from app.domain import reproduction_models as rm
from app.repositories.base import ensure_utc, now

CLEAR, WITHDRAWAL, UNCERTAIN, UNCHECKED = "clear", "withdrawal", "uncertain", "unchecked"
SALEABLE, HELD, RELEASED, NOT_FOR_SALE = "saleable", "held", "released", "not_for_sale"
# Stored milk that counts in the saleable tank.
TANK_STATUSES = (SALEABLE, RELEASED)
# A stored withdrawal_until within this of a fact's end is that fact's.
_EXPLAINED_SLACK = timedelta(minutes=1)
# Milk may be dated up to a day before the lactation's recorded start (the
# farm's time zone, a calving entered by its date).
_LACTATION_GRACE = timedelta(days=1)


@dataclass
class Window:
    """One withdrawal on the animal's milk."""

    source: str           # administration | treatment | animal_record
    source_id: str | None
    label: str
    starts_at: datetime | None
    until: datetime
    certainty: str        # recorded | uncertain

    def covers(self, at: datetime) -> bool:
        return (self.starts_at is None or self.starts_at <= at) and at < self.until

    def to_dict(self) -> dict:
        return {"source": self.source, "source_id": self.source_id, "label": self.label,
                "starts_at": self.starts_at, "until": self.until, "certainty": self.certainty}


@dataclass
class Assessment:
    status: str                                   # clear | withdrawal | uncertain
    at: datetime
    windows: list[Window] = field(default_factory=list)

    @property
    def until(self) -> datetime | None:
        return max((w.until for w in self.windows), default=None)

    def note(self, name: str) -> str | None:
        if self.status == CLEAR:
            return None
        parts = []
        for w in sorted(self.windows, key=lambda w: w.until):
            since = f"from {w.starts_at.date().isoformat()} " if w.starts_at else ""
            parts.append(f"{w.label} {since}until {w.until.date().isoformat()}")
        head = (f"{name} was under withdrawal when milked ({self.at.date().isoformat()})"
                if self.status == WITHDRAWAL else
                f"{name}'s withdrawal at this milking ({self.at.date().isoformat()}) cannot be confirmed from her records")
        return f"{head}: {'; '.join(parts)}."

    def to_dict(self, name: str = "") -> dict:
        return {"withdrawal_check": self.status, "at": self.at, "until": self.until, "note": self.note(name),
                "windows": [w.to_dict() for w in self.windows]}


# ------------------------------------------------------------- the facts
def _groups_at(db: Session, animal: models.Animal, at: datetime) -> set[str]:
    """The groups the animal was in at [at]: her membership history, or —
    for an animal registered before memberships were kept — the group her
    record names (the dose was applied to her as a member then too)."""
    rows = list(db.scalars(select(lm.AnimalGroupMembership).where(lm.AnimalGroupMembership.animal_id == animal.id)))
    if rows:
        return {m.animal_group_id for m in rows
                if ensure_utc(m.valid_from) <= at and (m.valid_to is None or at < ensure_utc(m.valid_to))}
    if not animal.group_name:
        return set()
    return set(db.scalars(select(models.Flock.id).where(
        models.Flock.farm_id == animal.farm_id, models.Flock.species == animal.species,
        models.Flock.name.ilike(animal.group_name.strip()),
    )))


def windows(db: Session, animal: models.Animal) -> list[Window]:
    """Every withdrawal window on the animal's milk, from the dated facts,
    plus her stored withdrawal when no fact explains it."""
    out: list[Window] = []
    explained: list[datetime] = []

    # Medicine administrations — to her, or to a group she was in then.
    group_ids = set(db.scalars(select(models.Flock.id).where(models.Flock.farm_id == animal.farm_id)))
    adms = list(db.scalars(select(pm.MedicationAdministration).where(
        pm.MedicationAdministration.farm_id == animal.farm_id,
        or_((pm.MedicationAdministration.subject_type == "animal") & (pm.MedicationAdministration.subject_id == animal.id),
            (pm.MedicationAdministration.subject_type == "group") & (pm.MedicationAdministration.subject_id.in_(group_ids) if group_ids else False)),
    )))
    for a in adms:
        at = ensure_utc(a.administered_at)
        if a.subject_type == "group" and a.subject_id not in _groups_at(db, animal, at):
            continue
        if a.withdrawal_milk_until is None:
            continue
        # Only a milk window explains the withdrawal on her record for milk:
        # a longer meat withdrawal stays on her milk, as it always has, until
        # her record says otherwise (never weaker than before v0.8.5).
        explained.append(ensure_utc(a.withdrawal_milk_until))
        product = db.get(pm.MedicineProduct, a.inventory_item_id)
        item = db.get(models.InventoryItem, a.inventory_item_id)
        name = (getattr(item, "name", None) or getattr(product, "name", None) or "Medicine")
        reversed_ = a.status == "reversed"
        out.append(Window(
            source="administration", source_id=a.id, starts_at=at, until=ensure_utc(a.withdrawal_milk_until),
            label=f"{name} given {at.date().isoformat()}" + (" (dose reversed — a veterinarian decides)" if reversed_ else ""),
            certainty="uncertain" if reversed_ else "recorded",
        ))

    # Treatments with a withdrawal — to her, or to a group she was in then.
    treatments = list(db.scalars(select(models.Treatment).where(
        models.Treatment.withdrawal_until.is_not(None),
        or_((models.Treatment.entity_type == "animal") & (models.Treatment.entity_id == animal.id),
            (models.Treatment.entity_type.in_(("group", "flock"))) & (models.Treatment.entity_id.in_(group_ids) if group_ids else False)),
    )))
    for t in treatments:
        start = ensure_utc(t.start_at)
        if t.entity_type != "animal" and t.entity_id not in _groups_at(db, animal, start):
            continue
        until = ensure_utc(t.withdrawal_until)
        explained.append(until)
        out.append(Window(source="treatment", source_id=t.id, starts_at=start, until=until,
                          label=f"{t.medication} (treatment from {start.date().isoformat()})", certainty="recorded"))

    # Her stored withdrawal, when no dated fact explains it: recorded from
    # the moment the server held it, unknown before.
    if animal.withdrawal_until is not None:
        stored = ensure_utc(animal.withdrawal_until)
        if not any(stored <= e + _EXPLAINED_SLACK for e in explained):
            since = ensure_utc(animal.withdrawal_known_since) if animal.withdrawal_known_since else None
            reason = animal.withdrawal_reason or "Withdrawal"
            if since is not None and since < stored:
                out.append(Window(source="animal_record", source_id=animal.id, starts_at=since, until=stored, certainty="recorded",
                                  label=f"{reason} on her record (known since {since.date().isoformat()})"))
            out.append(Window(source="animal_record", source_id=animal.id, starts_at=None, until=min(stored, since) if since else stored,
                              certainty="uncertain", label=f"{reason} on her record, with no dated treatment to say when it began"))
    return out


def assess(db: Session, animal: models.Animal, at: datetime | None) -> Assessment:
    """The withdrawal status of a milking at [at] (now when not given)."""
    at = ensure_utc(at) if at is not None else now()
    covering = [w for w in windows(db, animal) if w.covers(at)]
    recorded = [w for w in covering if w.certainty == "recorded"]
    if recorded:
        return Assessment(WITHDRAWAL, at, recorded)
    if covering:
        return Assessment(UNCERTAIN, at, covering)
    return Assessment(CLEAR, at, [])


def release_status_for(check: str, destination: str) -> str:
    """Whether milk of [check] sent to [destination] may be sold."""
    if destination == "withheld":
        return NOT_FOR_SALE
    if check == UNCERTAIN:
        return HELD
    if check == WITHDRAWAL:
        return NOT_FOR_SALE  # refused before it is stored; listed for completeness
    return SALEABLE


# -------------------------------------------------------------- lactation
@dataclass
class LactationAnswer:
    episode: rm.LactationEpisode | None
    problem: str | None = None
    status_code: int = 422


def lactation_at(db: Session, animal: models.Animal, at: datetime) -> LactationAnswer:
    """The lactation a milking at [at] belongs to, or why there is none."""
    db.flush()
    episodes = list(db.scalars(select(rm.LactationEpisode).where(rm.LactationEpisode.animal_id == animal.id)
                               .order_by(rm.LactationEpisode.started_at)))
    if not episodes:
        if animal.lactating:
            return LactationAnswer(None)  # milked before lactations were recorded
        return LactationAnswer(None, f"{animal.name} is not recorded as being milked. Start her milking first (her profile → Is she being "
                                     "milked? → Producing milk), then record the milk.", 409)
    for e in reversed(episodes):
        start = ensure_utc(e.started_at) - _LACTATION_GRACE
        end = ensure_utc(e.ended_at) if e.ended_at else None
        if start <= at and (end is None or at <= end):
            return LactationAnswer(e)
    first = episodes[0]
    if at < ensure_utc(first.started_at) - _LACTATION_GRACE:
        return LactationAnswer(None, f"{animal.name} started this lactation on {ensure_utc(first.started_at).date().isoformat()}; milk cannot be "
                                     "dated before it. If she calved earlier, correct the calving date on her profile.")
    before = [e for e in episodes if e.ended_at is not None and ensure_utc(e.ended_at) < at]
    last_dry = before[-1] if before else None
    later = [e for e in episodes if ensure_utc(e.started_at) - _LACTATION_GRACE > at]
    dried = ensure_utc(last_dry.ended_at).date().isoformat() if last_dry else "?"
    if later:
        return LactationAnswer(None, f"{animal.name} was dry on {at.date().isoformat()}: dried off on {dried}, the next lactation started "
                                     f"{ensure_utc(later[0].started_at).date().isoformat()}. Milk cannot be dated between two lactations.")
    active = next((e for e in episodes if e.status == "active"), None)
    if active is None:
        return LactationAnswer(None, f"{animal.name} was dried off on {dried}; milk after the dry-off is refused. If she is being milked again, "
                                     "start her milking first (her profile → Is she being milked? → Producing milk).", 409)
    return LactationAnswer(None, f"{animal.name} was dried off on {dried}; milk after the dry-off is refused.")


# ------------------------------------------------- facts recorded later
def hold_after_new_withdrawal(db: Session, animal: models.Animal, *, starts_at: datetime, until: datetime | None, source: str,
                              user_id: str) -> list[models.MilkRecord]:
    """A withdrawal recorded with a start in the past (a dose entered late, a
    treatment backdated) reaches milk already recorded as saleable: each such
    milking is held — not counted in the tank, not sold again — and the
    manager and veterinarian are told. Nothing already sold is changed."""
    if until is None:
        return []
    starts_at, until = ensure_utc(starts_at), ensure_utc(until)
    if starts_at >= now():
        return []
    db.flush()
    rows = list(db.scalars(select(models.MilkRecord).where(
        models.MilkRecord.animal_id == animal.id, models.MilkRecord.recorded_at >= starts_at, models.MilkRecord.recorded_at < until,
        models.MilkRecord.destination != "withheld", models.MilkRecord.release_status.in_(TANK_STATUSES),
    )))
    held = []
    for rec in rows:
        a = assess(db, animal, rec.recorded_at)
        if a.status == CLEAR:
            continue
        rec.withdrawal_check, rec.release_status = a.status, HELD
        rec.safety_note = (a.note(animal.name) or "")[:1000] + f" Held when {source} was recorded."
        rec.checked_at = now()
        held.append(rec)
    if held:
        from app.repositories.base import write_audit_log, write_event

        liters = round(sum(r.liters for r in held), 1)
        write_event(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type="milk_held_for_review",
                    payload={"milk_record_ids": [r.id for r in held], "liters": liters, "source": source}, created_by=user_id)
        write_audit_log(db, farm_id=animal.farm_id, user_id=user_id, action="milk_held_for_review", entity_type="animal", entity_id=animal.id,
                        module_code="milk_production", summary=f"{liters:g} L of {animal.name}'s milk held: {source} covers it"[:500],
                        metadata={"milk_record_ids": [r.id for r in held]})
        _notify_reviewers(db, animal, f"{liters:g} L of {animal.name}'s milk held for review",
                          f"{source} covers {len(held)} milking(s) already recorded as saleable. They no longer count in the tank; "
                          "check whether any of it was sold.", key=f"held:{animal.id}:{held[0].id}")
    return held


def _notify_reviewers(db: Session, animal: models.Animal, title: str, description: str, *, key: str) -> None:
    from app.repositories.base import new_id

    reviewers = db.scalars(select(models.User).where(models.User.farm_id == animal.farm_id, models.User.active.is_(True),
                                                     models.User.role.in_(REVIEW_ROLES)))
    for u in reviewers:
        if db.scalar(select(models.Notification.id).where(models.Notification.source_id == f"{key}|{u.id}")):
            continue
        db.add(models.Notification(
            id=new_id(), farm_id=animal.farm_id, user_id=u.id, module_code="milk_production", notification_type="milk_safety",
            title=title[:300], description=description, priority="high", entity_type="animal", entity_id=animal.id,
            source_type="milk_safety", source_id=f"{key}|{u.id}", created_at=now(),
        ))


# Who may release held milk: the roles that diagnose and decide on
# treatment (health_case_service.DIAGNOSTIC_ROLES) — never a worker.
REVIEW_ROLES = ("owner", "manager", "veterinarian")
