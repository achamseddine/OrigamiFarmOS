"""Who a farm wants told (MEDICINE-NOTIFICATION-RULES.md §Notification
behavior, CLINICAL-DECISION-SUPPORT §12 "notify manager/vet according to
policy").

A domain alert is authoritative; routing only decides its recipients. A
farm configures `notification_routes` per route code — a role, a person,
or both — and the built-in default applies where it has not: managers
and owners for logistics and escalations, veterinarians for the clinical
routes, plus whoever holds the inventory module's configure right for the
pharmacy (the "designated pharmacy / stock responsible user").
"""
from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core import permissions as perms
from app.domain import models
from app.domain import platform_models as plm
from app.repositories.base import new_id, now, write_event
from app.services.feed_inventory_service import FeedError


class RoutingError(FeedError):
    pass


DEFAULT_ROLES: dict[str, tuple[str, ...]] = {
    "pharmacy_stock": ("manager", "owner"),
    "pharmacy_critical": ("manager", "owner"),
    "pharmacy_expiry": ("manager", "owner"),
    "emergency_escalation": ("manager", "owner", "veterinarian"),
    "emergency_manager": ("manager", "owner"),
    "emergency_veterinarian": ("veterinarian",),
    "emergency_reassessment": ("manager", "owner"),
    "feed_performance": ("manager", "owner"),
    "procurement_requisition": ("manager", "owner"),
}
# Routes that also reach the designated stock-responsible person by default.
_STOCK_ROUTES = ("pharmacy_stock", "pharmacy_critical", "pharmacy_expiry", "procurement_requisition")


def configured_routes(db: Session, farm_id: str, route_code: str) -> list[plm.NotificationRoute]:
    return list(db.scalars(select(plm.NotificationRoute).where(
        plm.NotificationRoute.farm_id == farm_id, plm.NotificationRoute.route_code == route_code, plm.NotificationRoute.active.is_(True))))


def recipients(db: Session, farm_id: str, route_code: str) -> list[models.User]:
    """Active users the route reaches, explicit people first, no twins."""
    if route_code not in plm.ROUTE_CODES:
        raise RoutingError(f"route_code must be one of {list(plm.ROUTE_CODES)}")
    rows = configured_routes(db, farm_id, route_code)
    users: list[models.User] = []
    seen: set[str] = set()

    def add(u: models.User | None) -> None:
        if u is not None and u.active and u.farm_id == farm_id and u.id not in seen:
            seen.add(u.id)
            users.append(u)

    if rows:
        for r in rows:
            if r.user_id:
                add(db.get(models.User, r.user_id))
        roles = {r.role for r in rows if r.role}
        if roles:
            for u in db.scalars(select(models.User).where(models.User.farm_id == farm_id, models.User.role.in_(sorted(roles)), models.User.active.is_(True)).order_by(models.User.name)):
                add(u)
        return users
    for u in db.scalars(select(models.User).where(models.User.farm_id == farm_id, models.User.role.in_(DEFAULT_ROLES[route_code]), models.User.active.is_(True)).order_by(models.User.role, models.User.name)):
        add(u)
    if route_code in _STOCK_ROUTES:
        for perm in db.scalars(select(models.UserModulePermission).where(
                models.UserModulePermission.farm_id == farm_id, models.UserModulePermission.module_code == perms.INVENTORY, models.UserModulePermission.can_configure.is_(True))):
            add(db.get(models.User, perm.user_id))
    return users


def primary_recipient(db: Session, farm_id: str, route_code: str, *, prefer_role: str | None = None) -> models.User | None:
    people = recipients(db, farm_id, route_code)
    if prefer_role:
        for u in people:
            if u.role == prefer_role:
                return u
    return people[0] if people else None


def set_routes(db: Session, farm_id: str, route_code: str, entries: list[dict], *, user_id: str) -> list[plm.NotificationRoute]:
    """Replaces the farm's configuration for one route. An empty list
    returns the route to the built-in default."""
    if route_code not in plm.ROUTE_CODES:
        raise RoutingError(f"route_code must be one of {list(plm.ROUTE_CODES)}")
    for r in configured_routes(db, farm_id, route_code):
        r.active = False
    out = []
    for e in entries:
        role, target = e.get("role"), e.get("user_id")
        if not role and not target:
            raise RoutingError("Each route entry names a role or a user.")
        if target:
            u = db.get(models.User, target)
            if u is None or u.farm_id != farm_id:
                raise RoutingError("User not found on this farm", 404)
        row = plm.NotificationRoute(id=new_id(), farm_id=farm_id, route_code=route_code, role=role, user_id=target, channel=e.get("channel") or "in_app",
                                    active=True, created_by=user_id, created_at=now())
        db.add(row)
        out.append(row)
    db.flush()
    write_event(db, farm_id=farm_id, entity_type="farm", entity_id=farm_id, event_type="notification_routes_changed",
                payload={"route_code": route_code, "entries": [{"role": r.role, "user_id": r.user_id} for r in out]}, created_by=user_id)
    return out


def routes_overview(db: Session, farm_id: str) -> list[dict]:
    out = []
    for code in plm.ROUTE_CODES:
        rows = configured_routes(db, farm_id, code)
        out.append({
            "route_code": code, "configured": [{"id": r.id, "role": r.role, "user_id": r.user_id, "channel": r.channel} for r in rows],
            "default_roles": list(DEFAULT_ROLES[code]), "using_default": not rows,
            "effective_recipients": [{"id": u.id, "name": u.name, "role": u.role} for u in recipients(db, farm_id, code)],
        })
    return out
