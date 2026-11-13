"""Work responsibilities: what an employee looks after and which duties that
means (Settings > Employees > Responsibilities).

A responsibility is a scope — one animal, a group, every animal of a
species, or a field — and its duties: milking (and the milk record),
feeding (and the feeding record), observations, health care, egg
collection, crop care, harvest. It does two things:

- routes the work: the employee's day lists their animals and what is still
  to record today (`for_user`);
- grants the module access the duties need, as an ordinary
  `user_module_permissions` row (view + create + edit) when the employee
  does not hold that module yet — never a hidden second permission system,
  and never removed silently when the responsibility ends (the manager
  revokes access on the same screen).

Ended, never deleted, so "who looked after the dairy herd in March" stays
answerable.
"""
from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core import permissions as perms
from app.domain import models
from app.livestock import catalog as livestock_catalog
from app.repositories.base import new_id, now, write_audit_log, write_event
from app.services import group_service
from app.services.feed_inventory_service import FeedError

# duty -> the module whose access it needs
DUTIES: dict[str, str] = {
    "milking": perms.MILK_PRODUCTION,
    "feeding": perms.FEED_NUTRITION,
    "observation": perms.ANIMALS,
    "health_care": perms.ANIMAL_HEALTH,
    "egg_collection": perms.EGG_PRODUCTION,
    "crop_care": perms.AGRICULTURE,
    "harvest": perms.PRODUCE_HARVEST,
}
ANIMAL_DUTIES = ("milking", "feeding", "observation", "health_care", "egg_collection")
FIELD_DUTIES = ("crop_care", "harvest", "observation")
SCOPE_TYPES = ("animal", "group", "species", "field")


class ResponsibilityError(FeedError):
    """A refusal said as a sentence (→ 422 / 404 like the feed errors)."""


def _scope(db: Session, farm_id: str, scope_type: str, scope_id: str):
    if scope_type not in SCOPE_TYPES:
        raise ResponsibilityError(f"scope_type must be one of {list(SCOPE_TYPES)}")
    if scope_type == "animal":
        row = db.get(models.Animal, scope_id)
        if row is None or row.farm_id != farm_id:
            raise ResponsibilityError("Animal not found", 404)
        return row
    if scope_type == "group":
        row = db.get(models.Flock, scope_id)
        if row is None or row.farm_id != farm_id:
            raise ResponsibilityError("Group not found", 404)
        return row
    if scope_type == "field":
        row = db.get(models.Field, scope_id)
        if row is None or row.farm_id != farm_id:
            raise ResponsibilityError("Field not found", 404)
        return row
    codes = {row["code"] for row in livestock_catalog.SPECIES}
    if scope_id not in codes:
        raise ResponsibilityError(f"'{scope_id}' is not a species this farm keeps.")
    return scope_id


def scope_name(db: Session, r: models.WorkResponsibility) -> str:
    try:
        target = _scope(db, r.farm_id, r.scope_type, r.scope_id)
    except ResponsibilityError:
        return r.scope_id
    if r.scope_type == "species":
        return next((s["name_en"] for s in livestock_catalog.SPECIES if s["code"] == target), target)
    return getattr(target, "name", r.scope_id)


def animals_in_scope(db: Session, r: models.WorkResponsibility) -> list[models.Animal]:
    """The animals a responsibility covers today — the group's current
    members, every animal of the species, the one animal — on the farm."""
    if r.scope_type == "animal":
        a = db.get(models.Animal, r.scope_id)
        return [a] if a is not None and a.active else []
    if r.scope_type == "group":
        group = db.get(models.Flock, r.scope_id)
        return [a for _m, a in group_service.current_members(db, group)] if group is not None else []
    if r.scope_type == "species":
        return list(db.scalars(select(models.Animal).where(
            models.Animal.farm_id == r.farm_id, models.Animal.species == r.scope_id, models.Animal.active.is_(True)).order_by(models.Animal.name)))
    return []


def _ensure_module_access(db: Session, user: models.User, duties: list[str], scope_type: str, *, granted_by: models.User) -> list[str]:
    """The access the duties need, added where the employee lacks it."""
    if perms.is_full_access(user.role):
        return []
    needed = {DUTIES[d] for d in duties}
    if scope_type in ("animal", "group", "species"):
        needed.add(perms.ANIMALS)
    held = {p.module_code for p in db.scalars(select(models.UserModulePermission).where(models.UserModulePermission.user_id == user.id))}
    added = []
    for code in sorted(needed - held):
        db.add(models.UserModulePermission(
            id=new_id(), farm_id=user.farm_id, user_id=user.id, module_code=code,
            **{f"can_{action}": value for action, value in perms.DEFAULT_RESPONSIBILITY_GRANT.items()},
        ))
        added.append(code)
    if added:
        write_audit_log(db, farm_id=user.farm_id, user_id=granted_by.id, action="permissions_granted_by_responsibility", entity_type="user",
                        entity_id=user.id, module_code=perms.EMPLOYEES,
                        summary=f"{granted_by.name} gave {user.name} access to {', '.join(added)} for their new duties")
    return added


def assign(db: Session, *, employee: models.User, scope_type: str, scope_id: str, duties: list[str], notes: str | None,
           by: models.User) -> tuple[models.WorkResponsibility, list[str]]:
    if not employee.active:
        raise ResponsibilityError(f"{employee.name} is not active.")
    duties = sorted({d.strip().lower() for d in duties if d and d.strip()})
    if not duties:
        raise ResponsibilityError("Choose at least one duty (milking, feeding, observations…).")
    unknown = [d for d in duties if d not in DUTIES]
    if unknown:
        raise ResponsibilityError(f"Unknown duty: {', '.join(unknown)}. Duties are {', '.join(DUTIES)}.")
    allowed = FIELD_DUTIES if scope_type == "field" else ANIMAL_DUTIES
    wrong = [d for d in duties if d not in allowed]
    if wrong:
        raise ResponsibilityError(f"{', '.join(w.replace('_', ' ') for w in wrong)}: not a duty for {'a field' if scope_type == 'field' else 'animals'}.")
    _scope(db, employee.farm_id, scope_type, scope_id)
    existing = db.scalar(select(models.WorkResponsibility).where(
        models.WorkResponsibility.user_id == employee.id, models.WorkResponsibility.scope_type == scope_type,
        models.WorkResponsibility.scope_id == scope_id, models.WorkResponsibility.status == "active"))
    if existing is not None:
        raise ResponsibilityError(f"{employee.name} already looks after this; end that responsibility to change its duties.", 409)
    row = models.WorkResponsibility(id=new_id(), farm_id=employee.farm_id, user_id=employee.id, scope_type=scope_type, scope_id=scope_id,
                                    duties=duties, status="active", valid_from=now(), notes=(notes or "").strip() or None,
                                    created_by=by.id, created_at=now())
    db.add(row)
    db.flush()
    added = _ensure_module_access(db, employee, duties, scope_type, granted_by=by)
    name = scope_name(db, row)
    write_event(db, farm_id=employee.farm_id, entity_type="user", entity_id=employee.id, event_type="responsibility_assigned",
                payload={"responsibility_id": row.id, "scope_type": scope_type, "scope_id": scope_id, "duties": duties, "modules_granted": added},
                created_by=by.id)
    write_audit_log(db, farm_id=employee.farm_id, user_id=by.id, action="responsibility_assigned", entity_type="user", entity_id=employee.id,
                    module_code=perms.EMPLOYEES, summary=f"{by.name} made {employee.name} responsible for {name}: {', '.join(duties)}")
    return row, added


def end(db: Session, row: models.WorkResponsibility, *, by: models.User, reason: str | None = None) -> models.WorkResponsibility:
    if row.status != "active":
        return row
    row.status = "ended"
    row.valid_to = now()
    write_event(db, farm_id=row.farm_id, entity_type="user", entity_id=row.user_id, event_type="responsibility_ended",
                payload={"responsibility_id": row.id, "reason": reason}, created_by=by.id)
    write_audit_log(db, farm_id=row.farm_id, user_id=by.id, action="responsibility_ended", entity_type="user", entity_id=row.user_id,
                    module_code=perms.EMPLOYEES, summary=f"{by.name} ended a responsibility for {scope_name(db, row)}")
    return row


def to_dict(db: Session, r: models.WorkResponsibility, *, with_animals: bool = False) -> dict:
    out = {
        "id": r.id, "user_id": r.user_id, "scope_type": r.scope_type, "scope_id": r.scope_id, "scope_name": scope_name(db, r),
        "duties": list(r.duties or []), "status": r.status, "valid_from": r.valid_from, "valid_to": r.valid_to, "notes": r.notes,
    }
    if with_animals:
        out["animals"] = [{"id": a.id, "name": a.name, "tag": a.tag, "species": a.species, "lactating": bool(a.lactating)} for a in animals_in_scope(db, r)]
    return out


def of_user(db: Session, user_id: str, *, active_only: bool = True) -> list[models.WorkResponsibility]:
    stmt = select(models.WorkResponsibility).where(models.WorkResponsibility.user_id == user_id)
    if active_only:
        stmt = stmt.where(models.WorkResponsibility.status == "active")
    return list(db.scalars(stmt.order_by(models.WorkResponsibility.created_at)))
