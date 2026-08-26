"""DB-touching side of the Farm Visits & Agri-Tourism module: loads
session/activity/booking rows and calls the pure engine
(app/visits/analytics.py) — mirrors services/mouneh_service.py.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import visits_models as vm
from app.visits import analytics

ACTIVE_BOOKING_STATUSES = ("confirmed", "checked_in", "completed")


def session_confirmed_guest_count(db: Session, session_id: str, *, exclude_booking_id: str | None = None) -> int:
    stmt = select(vm.VisitBooking).where(
        vm.VisitBooking.session_id == session_id,
        vm.VisitBooking.status.in_(ACTIVE_BOOKING_STATUSES),
    )
    if exclude_booking_id:
        stmt = stmt.where(vm.VisitBooking.id != exclude_booking_id)
    return sum(b.guest_count for b in db.scalars(stmt))


def activity_booked_quantity(db: Session, activity_id: str, scheduled_at: datetime, *, exclude_id: str | None = None) -> int:
    stmt = (
        select(vm.VisitBookingActivity)
        .join(vm.VisitBooking, vm.VisitBookingActivity.booking_id == vm.VisitBooking.id)
        .where(
            vm.VisitBookingActivity.activity_id == activity_id,
            vm.VisitBookingActivity.scheduled_at == scheduled_at,
            vm.VisitBookingActivity.status.in_(("scheduled", "completed")),
            vm.VisitBooking.status.in_(ACTIVE_BOOKING_STATUSES + ("draft",)),
        )
    )
    if exclude_id:
        stmt = stmt.where(vm.VisitBookingActivity.id != exclude_id)
    return sum(ba.quantity for ba in db.scalars(stmt))


def activity_uses_on_day(db: Session, activity_id: str, day: date) -> int:
    day_start = datetime.combine(day, datetime.min.time(), tzinfo=timezone.utc)
    day_end = day_start + timedelta(days=1)
    stmt = (
        select(vm.VisitBookingActivity)
        .join(vm.VisitBooking, vm.VisitBookingActivity.booking_id == vm.VisitBooking.id)
        .where(
            vm.VisitBookingActivity.activity_id == activity_id,
            vm.VisitBookingActivity.scheduled_at >= day_start,
            vm.VisitBookingActivity.scheduled_at < day_end,
            vm.VisitBookingActivity.status.in_(("scheduled", "completed")),
            vm.VisitBooking.status.in_(ACTIVE_BOOKING_STATUSES + ("draft",)),
        )
    )
    return sum(ba.quantity for ba in db.scalars(stmt))


def session_assigned_roles(db: Session, session_id: str) -> set[str]:
    rows = db.scalars(select(vm.VisitStaffRoster).where(vm.VisitStaffRoster.session_id == session_id))
    return {r.role for r in rows}


def compute_booking_amount(
    package: vm.VisitPackage, activities: list[tuple[vm.VisitActivity, int]], *, guest_count: int
) -> tuple[float, float]:
    """Returns (total_amount, activity_revenue). Package revenue is
    `package.base_price * guest_count`; activity revenue is summed
    separately so profitability reporting never double-counts it (see
    app/visits/analytics.py::compute_visitor_revenue docstring)."""
    package_revenue = package.base_price * guest_count
    activity_revenue = sum(activity.price * qty for activity, qty in activities)
    return round(package_revenue + activity_revenue, 2), round(activity_revenue, 2)


def _allocated_cost(costs: list[vm.VisitCost], *, guest_count: int, package_guest_count: int) -> float:
    """Rough allocation: `per_session`/`per_activity`/`per_package` costs
    are counted in full against the scope being reported on; `per_guest`
    costs are pro-rated by the guest share of that scope vs the whole
    session, so a single package's report doesn't absorb a whole
    session's cleaning bill."""
    total = 0.0
    for c in costs:
        if c.allocation_method == "per_guest" and guest_count and package_guest_count:
            total += c.amount * (guest_count / package_guest_count)
        else:
            total += c.amount
    return total


def session_profitability(db: Session, session_id: str) -> dict:
    session = db.get(vm.VisitSession, session_id)
    bookings = list(
        db.scalars(
            select(vm.VisitBooking).where(
                vm.VisitBooking.session_id == session_id,
                vm.VisitBooking.status.in_(ACTIVE_BOOKING_STATUSES),
            )
        )
    )
    return _profitability_for_bookings(db, bookings, session_ids=[session_id] if session else [])


def range_profitability(db: Session, farm_id: str, start: date, end: date) -> dict:
    session_ids = [
        s.id
        for s in db.scalars(
            select(vm.VisitSession).where(vm.VisitSession.farm_id == farm_id, vm.VisitSession.date >= start, vm.VisitSession.date <= end)
        )
    ]
    bookings: list[vm.VisitBooking] = []
    if session_ids:
        bookings = list(
            db.scalars(
                select(vm.VisitBooking).where(
                    vm.VisitBooking.session_id.in_(session_ids),
                    vm.VisitBooking.status.in_(ACTIVE_BOOKING_STATUSES),
                )
            )
        )
    return _profitability_for_bookings(db, bookings, session_ids=session_ids)


def _profitability_for_bookings(db: Session, bookings: list[vm.VisitBooking], *, session_ids: list[str]) -> dict:
    checked_in_visitors = sum(b.guest_count for b in bookings if b.status in ("checked_in", "completed"))

    package_revenue = 0.0
    activity_revenue = 0.0
    by_package: dict[str, dict] = {}
    by_activity: dict[str, dict] = {}

    for booking in bookings:
        package = db.get(vm.VisitPackage, booking.package_id)
        pkg_rev = (package.base_price if package else 0) * booking.guest_count
        package_revenue += pkg_rev
        if package:
            entry = by_package.setdefault(package.id, {"package_id": package.id, "name": package.name, "revenue": 0.0, "bookings": 0})
            entry["revenue"] += pkg_rev
            entry["bookings"] += 1

        for ba in booking.activities:
            line_revenue = ba.unit_price * ba.quantity
            activity_revenue += line_revenue
            activity = db.get(vm.VisitActivity, ba.activity_id)
            key = activity.id if activity else ba.activity_id
            entry = by_activity.setdefault(key, {"activity_id": key, "name": activity.name if activity else key, "revenue": 0.0, "slots_sold": 0})
            entry["revenue"] += line_revenue
            entry["slots_sold"] += ba.quantity

    retail_sales: list[vm.VisitRetailSale] = []
    if bookings:
        booking_ids = [b.id for b in bookings]
        retail_sales = list(db.scalars(select(vm.VisitRetailSale).where(vm.VisitRetailSale.booking_id.in_(booking_ids))))

    sale_ids = [r.sale_id for r in retail_sales]
    purchase_count = len(sale_ids)
    visitors_with_purchase = len({r.booking_id for r in retail_sales if r.booking_id})
    retail_revenue = 0.0
    if sale_ids:
        from app.domain import models as core_models

        retail_revenue = sum(s.amount for s in db.scalars(select(core_models.Sale).where(core_models.Sale.id.in_(sale_ids))))

    costs = list(db.scalars(select(vm.VisitCost).where(vm.VisitCost.session_id.in_(session_ids)))) if session_ids else []
    staff_cost = sum(
        (r.total_cost if r.total_cost is not None else 0.0)
        for r in db.scalars(select(vm.VisitStaffRoster).where(vm.VisitStaffRoster.session_id.in_(session_ids)))
    ) if session_ids else 0.0
    staff_cost += _allocated_cost([c for c in costs if c.category == "staff"], guest_count=checked_in_visitors, package_guest_count=checked_in_visitors)
    cleaning_utilities_cost = _allocated_cost(
        [c for c in costs if c.category in ("cleaning", "utilities")], guest_count=checked_in_visitors, package_guest_count=checked_in_visitors
    )
    other_cost = _allocated_cost(
        [c for c in costs if c.category not in ("staff", "cleaning", "utilities")], guest_count=checked_in_visitors, package_guest_count=checked_in_visitors
    )

    summary = analytics.summarize_profitability(
        package_revenue=round(package_revenue, 2),
        activity_revenue=round(activity_revenue, 2),
        retail_revenue=round(retail_revenue, 2),
        staff_cost=round(staff_cost, 2),
        activity_cost=0.0,  # activity delivery cost is captured via visit_costs (category=other/tasting) in this MVP
        included_product_cost=0.0,
        cleaning_utilities_cost=round(cleaning_utilities_cost, 2),
        other_cost=round(other_cost, 2),
        checked_in_visitors=checked_in_visitors,
        visitors_with_purchase=visitors_with_purchase,
        purchase_count=purchase_count,
    )

    return {
        "package_revenue": round(package_revenue, 2),
        "activity_revenue": round(activity_revenue, 2),
        "retail_revenue": round(retail_revenue, 2),
        "visitor_revenue": summary.visitor_revenue,
        "staff_cost": round(staff_cost, 2),
        "activity_cost": 0.0,
        "included_product_cost": 0.0,
        "cleaning_utilities_cost": round(cleaning_utilities_cost, 2),
        "other_cost": round(other_cost, 2),
        "direct_visit_cost": summary.direct_visit_cost,
        "gross_margin": summary.gross_margin,
        "checked_in_visitors": summary.checked_in_visitors,
        "revenue_per_visitor": summary.revenue_per_visitor,
        "retail_conversion_pct": summary.retail_conversion_pct,
        "average_basket_value": summary.average_basket_value,
        "by_package": list(by_package.values()),
        "by_activity": list(by_activity.values()),
    }
