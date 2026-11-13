"""Animal groups as first-class subjects (database/LIVESTOCK-SCHEMA.md
§6–§9).

Membership is effective-dated and closed, never deleted. A group's type
policy decides whether membership is exclusive (a herd, a pen: joining
another closes the first) or overlapping (a cohort). A group's tracking
mode decides what its head count is:

- MEMBERSHIP_DERIVED — the number of current members;
- QUANTITY_MANAGED / HYBRID — the running total of its quantity ledger
  (`animal_group_quantity_events`); registered individuals in a hybrid
  flock never redefine its total.

Two projections are kept here and nowhere else: `flocks.count`, and
`animals.group_name` — the name of the animal's current exclusive group,
which the feeding resolver and the tablet read.
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.domain import livestock_models as lm
from app.domain import models
from app.livestock import catalog
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event
from app.services.livestock_state_service import LivestockError, ensure_on_farm

MEMBERSHIP_DERIVED = "MEMBERSHIP_DERIVED"
QUANTITY_MANAGED = "QUANTITY_MANAGED"
HYBRID = "HYBRID"

QUANTITY_EVENT_TYPES = {
    "INITIAL_COUNT": 0, "COUNT_ADJUSTMENT": 0,  # either sign
    "ADDITION": 1, "PURCHASE": 1, "BIRTH": 1, "HATCH": 1, "TRANSFER_IN": 1,
    "REMOVAL": -1, "DEATH": -1, "SALE": -1, "CULL": -1, "SLAUGHTER": -1, "TRANSFER_OUT": -1,
}


# Groups whose members follow the herd records (flocks.membership_rule):
# the pregnant cows, the open (not pregnant) cows, those in milk, those dry.
# Membership is still effective-dated rows opened and closed here — a cow
# confirmed pregnant leaves "Open cows" and joins "Pregnant cows" the day
# the check is recorded, and the history says so.
MEMBERSHIP_RULES = ("PREGNANT", "NOT_PREGNANT", "IN_MILK", "DRY")
_BREEDING_STAGES = ("adult", "senior")


def rule_matches(rule: str, animal: models.Animal) -> bool:
    """Whether an animal on the farm belongs in a group of this rule. "Not
    pregnant" and "dry" mean breeding-age females — a calf is neither."""
    if not animal.active:
        return False
    female = (animal.sex or "").upper() == "F"
    breeding_age = (animal.life_stage or catalog.DEFAULT_LIFE_STAGE) in _BREEDING_STAGES
    if rule == "PREGNANT":
        return bool(animal.pregnant)
    if rule == "NOT_PREGNANT":
        return female and breeding_age and not animal.pregnant
    if rule == "IN_MILK":
        return bool(animal.lactating)
    if rule == "DRY":
        return female and breeding_age and not animal.lactating
    return False


def sync_rule_groups(db: Session, animal: models.Animal, *, user_id: str, groups: list[models.Flock] | None = None) -> None:
    """Moves the animal into, or out of, every rule group of its species on
    its farm, so the groups always say what the records say."""
    if groups is None:
        groups = list(db.scalars(select(models.Flock).where(
            models.Flock.farm_id == animal.farm_id, models.Flock.species == animal.species, models.Flock.membership_rule.is_not(None),
        )))
    if not groups:
        return
    current = {m.animal_group_id for m in memberships_of_animal(db, animal.id, current_only=True)}
    for group in groups:
        if group.status in ("closed", "archived") or group.membership_rule not in MEMBERSHIP_RULES:
            continue
        should = rule_matches(group.membership_rule, animal)
        if should and group.id not in current:
            add_member(db, group, animal, reason=f"rule:{group.membership_rule}", user_id=user_id, review=False)
        elif not should and group.id in current:
            remove_member(db, group, animal, reason=f"rule:{group.membership_rule}", user_id=user_id)


def fill_rule_group(db: Session, group: models.Flock, *, user_id: str) -> int:
    """A new rule group starts with every animal that already matches."""
    added = 0
    for animal in db.scalars(select(models.Animal).where(
        models.Animal.farm_id == group.farm_id, models.Animal.species == group.species, models.Animal.active.is_(True),
    )):
        if rule_matches(group.membership_rule or "", animal):
            add_member(db, group, animal, reason=f"rule:{group.membership_rule}", user_id=user_id, review=False)
            added += 1
    return added


def policy(db: Session, group_type: str | None) -> lm.AnimalGroupTypePolicy:
    """The type's policy; an unknown type is a physical, exclusive group —
    the safe reading, since it never lets an animal be in two pens."""
    row = db.get(lm.AnimalGroupTypePolicy, group_type or "")
    if row is not None:
        return row
    return lm.AnimalGroupTypePolicy(group_type=group_type or "herd", label_en=group_type or "Group", label_ar=group_type or "مجموعة",
                                    exclusive_membership=True, allows_individual_members=True, active=True)


def _active(at: datetime | None = None):
    at = at or now()
    return (lm.AnimalGroupMembership.valid_from <= at) & (
        lm.AnimalGroupMembership.valid_to.is_(None) | (lm.AnimalGroupMembership.valid_to > at)
    )


def memberships_of_animal(db: Session, animal_id: str, *, current_only: bool = False) -> list[lm.AnimalGroupMembership]:
    db.flush()  # sessions do not autoflush; a membership closed in this transaction must read as closed
    stmt = select(lm.AnimalGroupMembership).where(lm.AnimalGroupMembership.animal_id == animal_id)
    if current_only:
        stmt = stmt.where(lm.AnimalGroupMembership.valid_to.is_(None))
    return list(db.scalars(stmt.order_by(lm.AnimalGroupMembership.valid_from.desc())))


def current_members(db: Session, group: models.Flock, at: datetime | None = None) -> list[tuple[lm.AnimalGroupMembership, models.Animal]]:
    db.flush()
    rows = db.execute(
        select(lm.AnimalGroupMembership, models.Animal)
        .join(models.Animal, models.Animal.id == lm.AnimalGroupMembership.animal_id)
        .where(lm.AnimalGroupMembership.animal_group_id == group.id, _active(ensure_utc(at) if at else None))
        .order_by(models.Animal.name)
    ).all()
    return [(m, a) for m, a in rows]


def member_history(db: Session, group: models.Flock) -> list[tuple[lm.AnimalGroupMembership, models.Animal]]:
    rows = db.execute(
        select(lm.AnimalGroupMembership, models.Animal)
        .join(models.Animal, models.Animal.id == lm.AnimalGroupMembership.animal_id)
        .where(lm.AnimalGroupMembership.animal_group_id == group.id)
        .order_by(lm.AnimalGroupMembership.valid_from.desc())
    ).all()
    return [(m, a) for m, a in rows]


def exclusive_group_of(db: Session, animal: models.Animal) -> models.Flock | None:
    """The animal's current herd / flock / pen — the group it inherits a
    feeding program from (feed architecture §9)."""
    for membership in memberships_of_animal(db, animal.id, current_only=True):
        group = db.get(models.Flock, membership.animal_group_id)
        if group is not None and policy(db, group.group_type).exclusive_membership:
            return group
    return None


def _refresh_animal_group_name(db: Session, animal: models.Animal) -> bool:
    group = exclusive_group_of(db, animal)
    name = group.name if group is not None else None
    if animal.group_name != name:
        animal.group_name = name
        return True
    return False


def refresh_count(db: Session, group: models.Flock) -> None:
    if group.tracking_mode == MEMBERSHIP_DERIVED:
        db.flush()
        group.count = db.scalar(select(func.count(lm.AnimalGroupMembership.id)).where(
            lm.AnimalGroupMembership.animal_group_id == group.id, lm.AnimalGroupMembership.valid_to.is_(None),
        )) or 0


def _on_animal_regrouped(db: Session, animal: models.Animal, *, user_id: str) -> None:
    """A group change is a feeding-review trigger and a feed-performance
    confounder (feed §10, FEED-PERFORMANCE-INTELLIGENCE §12) — a review,
    never a silent reassignment."""
    from app.services import feed_performance_service, feeding_program_service

    feeding_program_service.review_animal_if_relevant(db, animal, {"group_name"}, user_id=user_id)
    feed_performance_service.on_context_changed(db, "animal", animal, trigger="group_moved", user_id=user_id)


def _on_group_changed(db: Session, group: models.Flock, *, user_id: str) -> None:
    from app.services import feed_performance_service, feeding_program_service

    feeding_program_service.review_feeding(db, group.farm_id, "group", group, trigger="group_changed", user_id=user_id)
    feed_performance_service.on_context_changed(db, "group", group, trigger="group_changed", user_id=user_id)


# -------------------------------------------------------------- membership
def add_member(db: Session, group: models.Flock, animal: models.Animal, *, at: datetime | None = None, reason: str | None = None,
               user_id: str, review: bool = True) -> lm.AnimalGroupMembership:
    """`review=False` for an animal joining its herd as it is registered:
    it inherits the herd's program, which is no move to review."""
    at = ensure_utc(at) if at else now()
    if at > now():
        raise LivestockError("A membership cannot start in the future.")
    if animal.farm_id != group.farm_id:
        raise LivestockError("Animal not found", 404)
    ensure_on_farm(animal, "a group move")
    if animal.species != group.species:
        raise LivestockError(
            f"{animal.name} is a {animal.species.replace('_', ' ')}; {group.name} is a group of {group.species.replace('_', ' ')}. "
            "A group holds one species."
        )
    if group.status in ("closed", "archived"):
        raise LivestockError(f"{group.name} is {group.status}.", 409)
    group_policy = policy(db, group.group_type)
    if not group_policy.allows_individual_members:
        raise LivestockError(f"A {group_policy.label_en.lower()} is counted, not made of registered animals.")
    for m in memberships_of_animal(db, animal.id, current_only=True):
        if m.animal_group_id == group.id:
            raise LivestockError(f"{animal.name} is already in {group.name}.", 409)
    moved_from: list[models.Flock] = []
    if group_policy.exclusive_membership:
        # A physical group: joining it is a move out of the previous one.
        for m in memberships_of_animal(db, animal.id, current_only=True):
            other = db.get(models.Flock, m.animal_group_id)
            if other is not None and policy(db, other.group_type).exclusive_membership:
                if at < ensure_utc(m.valid_from):
                    raise LivestockError(f"{animal.name} joined {other.name} on {ensure_utc(m.valid_from).date().isoformat()}; a move cannot be dated before that.")
                m.valid_to = at
                m.end_reason_code = f"moved_to:{group.id}"
                m.ended_by = user_id
                moved_from.append(other)
    membership = lm.AnimalGroupMembership(
        id=new_id(), farm_id=group.farm_id, animal_group_id=group.id, animal_id=animal.id, valid_from=at,
        reason_code=reason, created_at=now(), created_by=user_id,
    )
    db.add(membership)
    if group.tracking_mode == QUANTITY_MANAGED:
        # Registering an individual in a counted flock makes it hybrid: the
        # count stays the flock's own (LIVESTOCK-SCHEMA §6).
        group.tracking_mode = HYBRID
    db.flush()
    for g in (*moved_from, group):
        refresh_count(db, g)
    changed = _refresh_animal_group_name(db, animal)
    write_event(
        db, farm_id=group.farm_id, entity_type="animal", entity_id=animal.id, event_type="animal_added_to_group",
        payload={"group_id": group.id, "group_name": group.name, "valid_from": at.isoformat(), "moved_from": [g.id for g in moved_from], "reason": reason},
        created_by=user_id,
    )
    if review and changed:
        _on_animal_regrouped(db, animal, user_id=user_id)
    if review and (group.tracking_mode == MEMBERSHIP_DERIVED or moved_from):
        _on_group_changed(db, group, user_id=user_id)
    return membership


def remove_member(db: Session, group: models.Flock, animal: models.Animal, *, at: datetime | None = None, reason: str | None = None,
                  user_id: str, quantity_event: str | None = None) -> lm.AnimalGroupMembership:
    at = ensure_utc(at) if at else now()
    membership = next((m for m in memberships_of_animal(db, animal.id, current_only=True) if m.animal_group_id == group.id), None)
    if membership is None:
        raise LivestockError(f"{animal.name} is not in {group.name}.", 404)
    if at < ensure_utc(membership.valid_from):
        raise LivestockError(f"{animal.name} joined {group.name} on {ensure_utc(membership.valid_from).date().isoformat()}; leaving cannot be dated before that.")
    membership.valid_to = at
    membership.end_reason_code = reason or "removed"
    membership.ended_by = user_id
    if quantity_event and group.tracking_mode in (HYBRID, QUANTITY_MANAGED) and (group.count or 0) > 0:
        record_quantity(db, group, quantity_event, -1, at=at, reason=f"{animal.name}: {reason or quantity_event.lower()}",
                        source_type="animal", source_id=animal.id, user_id=user_id)
    refresh_count(db, group)
    changed = _refresh_animal_group_name(db, animal)
    write_event(
        db, farm_id=group.farm_id, entity_type="animal", entity_id=animal.id, event_type="animal_removed_from_group",
        payload={"group_id": group.id, "group_name": group.name, "valid_to": at.isoformat(), "reason": reason}, created_by=user_id,
    )
    if changed and animal.active:
        _on_animal_regrouped(db, animal, user_id=user_id)
    if group.tracking_mode == MEMBERSHIP_DERIVED:
        _on_group_changed(db, group, user_id=user_id)
    return membership


def end_memberships_on_exit(db: Session, animal: models.Animal, *, at: datetime, quantity_event: str | None, reason: str, user_id: str) -> None:
    """An animal that died or was sold leaves every group it was in; a
    counted flock it belonged to records the loss in its own ledger."""
    for membership in memberships_of_animal(db, animal.id, current_only=True):
        group = db.get(models.Flock, membership.animal_group_id)
        if group is not None:
            remove_member(db, group, animal, at=max(at, ensure_utc(membership.valid_from)), reason=reason, user_id=user_id, quantity_event=quantity_event)


def move_by_name(db: Session, animal: models.Animal, name: str | None, *, user_id: str, review: bool = True) -> None:
    """The edit form's herd / group field (and older clients' free-text
    `group_name`): an existing group of the animal's species, by name, or
    blank to leave its current herd. A name that matches no group is
    refused with the names that would — a typo must not create a herd."""
    target_name = (name or "").strip()
    current_group = exclusive_group_of(db, animal)
    if not target_name:
        if current_group is not None:
            remove_member(db, current_group, animal, reason="left_group", user_id=user_id)
        return
    if current_group is not None and current_group.name.strip().lower() == target_name.lower():
        return
    group = db.scalar(select(models.Flock).where(
        models.Flock.farm_id == animal.farm_id, models.Flock.species == animal.species, func.lower(models.Flock.name) == target_name.lower(),
    ))
    if group is None:
        names = sorted(g.name for g in db.scalars(select(models.Flock).where(models.Flock.farm_id == animal.farm_id, models.Flock.species == animal.species)))
        raise LivestockError(
            f"There is no group called '{target_name}' for {animal.species.replace('_', ' ')}. "
            + (f"Choose one of: {', '.join(names)} — or create the group first." if names else "Create the group first.")
        )
    add_member(db, group, animal, reason="edit" if review else "registered", user_id=user_id, review=review)


# -------------------------------------------------------------- quantity
def record_quantity(db: Session, group: models.Flock, event_type: str, quantity_delta: int, *, at: datetime | None = None,
                    reason: str | None = None, source_type: str | None = None, source_id: str | None = None,
                    user_id: str, correlation_id: str | None = None) -> lm.AnimalGroupQuantityEvent:
    """One head-count movement. The total is the running sum in the order
    the movements are recorded; a backdated entry keeps its occurred-at but
    never rewrites totals already reported."""
    if event_type not in QUANTITY_EVENT_TYPES:
        raise LivestockError(f"event_type must be one of {sorted(QUANTITY_EVENT_TYPES)}")
    if group.tracking_mode == MEMBERSHIP_DERIVED:
        raise LivestockError(f"{group.name} counts its registered members; add or remove animals instead of changing its count.")
    sign = QUANTITY_EVENT_TYPES[event_type]
    if quantity_delta == 0 and event_type != "INITIAL_COUNT":
        raise LivestockError("A head-count change must move the count.")
    if sign > 0 and quantity_delta < 0 or sign < 0 and quantity_delta > 0:
        raise LivestockError(f"A {event_type.lower().replace('_', ' ')} {'adds' if sign > 0 else 'removes'} animals; send the quantity with that sign.")
    at = ensure_utc(at) if at else now()
    if at > now():
        raise LivestockError("A head-count change cannot be dated in the future.")
    resulting = (group.count or 0) + quantity_delta
    if resulting < 0:
        raise LivestockError(f"{group.name} has {group.count or 0}; removing {-quantity_delta} would leave a negative count.")
    row = lm.AnimalGroupQuantityEvent(
        id=new_id(), farm_id=group.farm_id, animal_group_id=group.id, event_type=event_type, quantity_delta=quantity_delta,
        resulting_quantity=resulting, occurred_at=at, reason=reason, source_type=source_type, source_id=source_id,
        recorded_at=now(), recorded_by=user_id, correlation_id=correlation_id,
    )
    db.add(row)
    group.count = resulting
    write_event(
        db, farm_id=group.farm_id, entity_type="flock", entity_id=group.id, event_type="animal_group_quantity_changed",
        payload={"event_type": event_type, "delta": quantity_delta, "resulting": resulting, "occurred_at": at.isoformat(), "reason": reason},
        created_by=user_id,
    )
    _on_group_changed(db, group, user_id=user_id)
    return row


def set_count(db: Session, group: models.Flock, new_count: int, *, user_id: str, reason: str | None = None) -> lm.AnimalGroupQuantityEvent | None:
    """An older client's "count = N" edit, written as the adjustment it is."""
    if new_count == (group.count or 0):
        return None
    return record_quantity(db, group, "COUNT_ADJUSTMENT", new_count - (group.count or 0), reason=reason or "count corrected", user_id=user_id)


def open_group(db: Session, group: models.Flock, *, user_id: str) -> None:
    """A new group's opening count, as the first row of its ledger."""
    if group.tracking_mode not in catalog.TRACKING_MODES:
        raise LivestockError(f"tracking_mode must be one of {list(catalog.TRACKING_MODES)}")
    if group.tracking_mode == MEMBERSHIP_DERIVED:
        group.count = 0
        return
    if (group.count or 0) > 0:
        db.add(lm.AnimalGroupQuantityEvent(
            id=new_id(), farm_id=group.farm_id, animal_group_id=group.id, event_type="INITIAL_COUNT", quantity_delta=group.count,
            resulting_quantity=group.count, occurred_at=now(), reason="Opening count", recorded_at=now(), recorded_by=user_id,
        ))


def quantity_history(db: Session, group: models.Flock) -> list[lm.AnimalGroupQuantityEvent]:
    return list(db.scalars(select(lm.AnimalGroupQuantityEvent).where(lm.AnimalGroupQuantityEvent.animal_group_id == group.id)
                           .order_by(lm.AnimalGroupQuantityEvent.recorded_at.desc())))


# -------------------------------------------------------------- dicts
def membership_dict(db: Session, m: lm.AnimalGroupMembership, animal: models.Animal | None = None, group: models.Flock | None = None) -> dict:
    group = group or db.get(models.Flock, m.animal_group_id)
    animal = animal or db.get(models.Animal, m.animal_id)
    return {
        "id": m.id, "group_id": m.animal_group_id, "group_name": group.name if group else None,
        "group_type": group.group_type if group else None, "animal_id": m.animal_id,
        "animal_name": animal.name if animal else None, "animal_tag": animal.tag if animal else None,
        "valid_from": m.valid_from, "valid_to": m.valid_to, "current": m.valid_to is None,
        "reason": m.reason_code, "end_reason": m.end_reason_code,
    }


def quantity_dict(e: lm.AnimalGroupQuantityEvent) -> dict:
    return {
        "id": e.id, "group_id": e.animal_group_id, "event_type": e.event_type, "quantity_delta": e.quantity_delta,
        "resulting_quantity": e.resulting_quantity, "occurred_at": e.occurred_at, "reason": e.reason,
        "source_type": e.source_type, "source_id": e.source_id, "recorded_at": e.recorded_at, "recorded_by": e.recorded_by,
    }


def audit(db: Session, group: models.Flock, user: models.User, action: str, summary: str, changes: dict | None = None) -> None:
    write_audit_log(db, farm_id=group.farm_id, user_id=user.id, action=action, entity_type="flock", entity_id=group.id,
                    module_code="animals", summary=summary, changes=changes)
