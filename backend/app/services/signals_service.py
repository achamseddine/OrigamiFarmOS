"""Everything on this farm that currently wants someone's attention.

One generator, two consumers: the notification bell (`api/v1/notifications.py`,
which persists these as rows so read/unread survives) and the Today's
Priorities feed (`api/v1/priorities.py`, which merges them with open
tasks). Deriving both from the same place is what makes tapping a bell
item and tapping a priority card land on the same record.

Every signal carries `entity_type`/`entity_id` — tech spec's implementation
principle: "A displayed alert must navigate to the object that caused it."
A signal with nothing to navigate to should not be raised at all.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core import permissions as perms
from app.domain import models, mouneh_models
from app.domain import visits_models as vm
from app.repositories.base import ensure_utc, now

# Recommendation categories -> the module a user must hold to see them.
_RECOMMENDATION_MODULE = {
    "health": perms.ANIMAL_HEALTH,
    "feed": perms.FEED_NUTRITION,
    "egg": perms.EGG_PRODUCTION,
    "withdrawal": perms.ANIMAL_HEALTH,
    "harvest": perms.PRODUCE_HARVEST,
    "finance": perms.FINANCE,
}

_PRIORITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}


@dataclass
class Signal:
    """One actionable item. `source_type`/`source_id` identify the thing
    that produced it (so it is not raised twice); `entity_type`/`entity_id`
    identify what the user should be taken to.
    """

    source_type: str
    source_id: str
    module_code: str
    notification_type: str
    title: str
    description: str
    priority: str
    entity_type: str
    entity_id: str
    kind: str = "alert"  # alert | task
    status: str = "pending"
    due_at: str | None = None
    assigned_to: str | None = None
    metadata: dict = field(default_factory=dict)

    def sort_key(self) -> tuple[int, str]:
        return (_PRIORITY_RANK.get(self.priority, 5), self.title)


def _rank(priority: str) -> int:
    return _PRIORITY_RANK.get(priority, 5)


# ---------------------------------------------------------------------------
# Individual sources
# ---------------------------------------------------------------------------
def _recommendation_signals(db: Session, farm_id: str) -> list[Signal]:
    rows = db.scalars(
        select(models.Recommendation).where(
            models.Recommendation.farm_id == farm_id,
            models.Recommendation.status == "generated",
        )
    ).all()
    signals = []
    for rec in rows:
        module = _RECOMMENDATION_MODULE.get(rec.category, perms.AI_INTELLIGENCE)
        signals.append(
            Signal(
                source_type="recommendation",
                source_id=rec.id,
                module_code=module,
                notification_type=f"{rec.category}_alert",
                title=rec.title,
                description=rec.entity_label or rec.suggested_action or "",
                priority=rec.priority,
                # An entity-linked recommendation opens that animal/field;
                # a farm-wide one opens the recommendation itself.
                entity_type=rec.entity_type or "recommendation",
                entity_id=rec.entity_id or rec.id,
                metadata={"category": rec.category, "confidence": rec.confidence, "recommendation_id": rec.id},
            )
        )
    return signals


def _low_stock_signals(db: Session, farm_id: str) -> list[Signal]:
    rows = db.scalars(select(models.InventoryItem).where(models.InventoryItem.farm_id == farm_id)).all()
    signals = []
    for item in rows:
        # reorder_level defaults to 0, which means "no threshold set" —
        # without this guard every empty item would raise a false alarm.
        if not item.reorder_level or item.current_qty > item.reorder_level:
            continue
        critical = item.current_qty <= item.reorder_level * 0.5
        shortfall = max(item.reorder_level - item.current_qty, 0)
        signals.append(
            Signal(
                source_type="inventory_item",
                source_id=item.id,
                module_code=perms.FEED_NUTRITION if (item.category or "").lower() != "produce" else perms.INVENTORY,
                notification_type="low_stock",
                title=f"Low stock: {item.name}",
                description=(
                    f"{item.current_qty:.0f} {item.unit} left — {shortfall:.0f} {item.unit} below the reorder level."
                ),
                priority="high" if critical else "medium",
                entity_type="inventory_item",
                entity_id=item.id,
                metadata={"current_qty": item.current_qty, "reorder_level": item.reorder_level},
            )
        )
    return signals


def _withdrawal_signals(db: Session, farm_id: str) -> list[Signal]:
    rows = db.scalars(
        select(models.Animal).where(
            models.Animal.farm_id == farm_id,
            models.Animal.active.is_(True),
            models.Animal.withdrawal_until.is_not(None),
        )
    ).all()
    current = now()
    signals = []
    for animal in rows:
        if ensure_utc(animal.withdrawal_until) <= current:
            continue
        until = ensure_utc(animal.withdrawal_until).date().isoformat()
        signals.append(
            Signal(
                source_type="withdrawal",
                source_id=animal.id,
                module_code=perms.ANIMAL_HEALTH,
                notification_type="withdrawal_active",
                title=f"Withdrawal active: {animal.name} #{animal.tag}",
                description=f"Milk and meat cannot be sold until {until} ({animal.withdrawal_reason or 'medication'}).",
                priority="high",
                entity_type="animal",
                entity_id=animal.id,
                metadata={"withdrawal_until": until},
            )
        )
    return signals


def _overdue_task_signals(db: Session, farm_id: str) -> list[Signal]:
    rows = db.scalars(
        select(models.Task).where(models.Task.farm_id == farm_id, models.Task.status != "completed")
    ).all()
    current = now()
    signals = []
    for task in rows:
        if task.due_at is None or ensure_utc(task.due_at) >= current:
            continue
        signals.append(
            Signal(
                source_type="task_overdue",
                source_id=task.id,
                module_code=perms.TASKS,
                notification_type="task_overdue",
                title=f"Overdue task: {task.title}",
                description=task.description or "This task passed its due time.",
                priority="high" if task.priority == "high" else "medium",
                entity_type="task",
                entity_id=task.id,
                assigned_to=task.assigned_to,
                metadata={"due_at": ensure_utc(task.due_at).isoformat()},
            )
        )
    return signals


def _mouneh_signals(db: Session, farm_id: str) -> list[Signal]:
    signals: list[Signal] = []
    for stock in db.scalars(
        select(mouneh_models.FinishedGoodsStock).where(mouneh_models.FinishedGoodsStock.farm_id == farm_id)
    ):
        product = db.get(mouneh_models.MounehProduct, stock.product_id)
        threshold = product.low_stock_threshold if product else None
        if threshold is None or stock.quantity_available > threshold:
            continue
        signals.append(
            Signal(
                source_type="mouneh_stock",
                source_id=stock.id,
                module_code=perms.MOUNEH_INVENTORY,
                notification_type="mouneh_stock_low",
                title=f"Mouneh stock low: {product.name if product else stock.product_id}",
                description=f"{stock.quantity_available:.0f} units left, below the {threshold:.0f} threshold.",
                priority="medium",
                entity_type="mouneh_product",
                entity_id=stock.product_id,
                metadata={"quantity_available": stock.quantity_available},
            )
        )
    for batch in db.scalars(
        select(mouneh_models.ProductionBatch).where(
            mouneh_models.ProductionBatch.farm_id == farm_id,
            mouneh_models.ProductionBatch.status == "in_progress",
        )
    ):
        product = db.get(mouneh_models.MounehProduct, batch.product_id)
        signals.append(
            Signal(
                source_type="mouneh_batch",
                source_id=batch.id,
                module_code=perms.MOUNEH_PRODUCTION,
                notification_type="batch_in_progress",
                title=f"Batch in progress: {product.name if product else batch.product_id}",
                description=f"Batch {batch.batch_code or batch.id[:8]} is still open and needs completing.",
                priority="medium",
                entity_type="mouneh_batch",
                entity_id=batch.id,
            )
        )
    return signals


def _visit_signals(db: Session, farm_id: str) -> list[Signal]:
    today = date.today()
    horizon = today + timedelta(days=1)
    sessions = db.scalars(
        select(vm.VisitSession).where(
            vm.VisitSession.farm_id == farm_id,
            vm.VisitSession.date >= today,
            vm.VisitSession.date <= horizon,
        )
    ).all()
    signals = []
    for session in sessions:
        bookings = db.scalars(
            select(vm.VisitBooking).where(
                vm.VisitBooking.session_id == session.id,
                vm.VisitBooking.status.in_(("confirmed", "checked_in")),
            )
        ).all()
        if not bookings:
            continue
        guests = sum(b.guest_count for b in bookings)
        when = "today" if session.date == today else "tomorrow"
        signals.append(
            Signal(
                source_type="visit_session",
                source_id=session.id,
                module_code=perms.FARM_VISITS,
                notification_type="visit_upcoming",
                title=f"{len(bookings)} booking(s) {when}: {guests} visitors",
                description=f"Session {session.start_time}–{session.end_time} on {session.date.isoformat()}.",
                priority="high" if session.date == today else "medium",
                entity_type="visit_session",
                entity_id=session.id,
                metadata={"guests": guests, "bookings": len(bookings)},
            )
        )
    return signals


def _pending_payment_signals(db: Session, farm_id: str) -> list[Signal]:
    rows = db.scalars(
        select(models.Sale).where(models.Sale.farm_id == farm_id, models.Sale.payment_status != "paid")
    ).all()
    if not rows:
        return []
    total = sum(s.amount for s in rows)
    newest = max(rows, key=lambda s: ensure_utc(s.sold_at))
    return [
        Signal(
            source_type="pending_payments",
            source_id=farm_id,
            module_code=perms.FINANCE,
            notification_type="payment_pending",
            title=f"{len(rows)} sale(s) awaiting payment",
            description=f"${total:,.0f} outstanding across {len(rows)} sale(s).",
            priority="medium",
            entity_type="sale",
            entity_id=newest.id,
            metadata={"count": len(rows), "total": round(total, 2)},
        )
    ]


_SOURCES = (
    _recommendation_signals,
    _low_stock_signals,
    _withdrawal_signals,
    _overdue_task_signals,
    _mouneh_signals,
    _visit_signals,
    _pending_payment_signals,
)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
def collect_signals(db: Session, farm_id: str) -> list[Signal]:
    """Every current alert on the farm, most urgent first. A source that
    raises (e.g. a module whose tables are empty on a fresh farm) must not
    take the whole feed down with it — the bell degrades to fewer items,
    never to an error page.
    """
    signals: list[Signal] = []
    for source in _SOURCES:
        try:
            signals.extend(source(db, farm_id))
        except Exception:  # noqa: BLE001 - one bad source must not break the feed
            continue
    signals.sort(key=lambda s: s.sort_key())
    return signals


def open_task_signals(db: Session, farm_id: str) -> list[Signal]:
    """Open tasks as priority items (tech spec §5: priorities are not only
    alerts). Overdue ones are already raised as alerts by
    [_overdue_task_signals], so they are skipped here to avoid showing the
    same task twice in one list.
    """
    rows = db.scalars(
        select(models.Task).where(models.Task.farm_id == farm_id, models.Task.status != "completed")
    ).all()
    current = now()
    signals = []
    for task in rows:
        if task.due_at is not None and ensure_utc(task.due_at) < current:
            continue
        signals.append(
            Signal(
                source_type="task",
                source_id=task.id,
                module_code=perms.TASKS,
                notification_type="task",
                title=task.title,
                description=task.description or "",
                priority=task.priority or "medium",
                entity_type="task",
                entity_id=task.id,
                kind="task",
                status=task.status,
                due_at=ensure_utc(task.due_at).isoformat() if task.due_at else None,
                assigned_to=task.assigned_to,
            )
        )
    return signals


def visible_to(signals: list[Signal], permission_map: dict[str, dict[str, bool]]) -> list[Signal]:
    """Filters a feed down to what this user is responsible for — an
    Animals-only employee should not be shown the farm's finance alerts.
    """
    return [s for s in signals if permission_map.get(s.module_code, {}).get(perms.VIEW, False)]
