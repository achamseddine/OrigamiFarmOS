"""Farm Visits & Agri-Tourism — pure analytics/validation engine (tech
spec v0.6 §5 "Business Rules" and §9 "Analytics Formulas").

Pure functions: everything here takes plain values in and returns plain
values/dataclasses out, no DB access, so capacity checks, the booking
status machine, and every profitability formula are unit testable
directly (see tests/test_visits_analytics.py). Mirrors the pattern
already used by app/recommendations/engine.py and app/mouneh/costing.py
— the DB-touching side (app/services/visits_service.py) loads real rows
and calls these.
"""
from __future__ import annotations

from dataclasses import dataclass

# ---------------------------------------------------------------------------
# RULE-VIS-008: booking status state machine
# ---------------------------------------------------------------------------
BOOKING_STATUSES = {"draft", "confirmed", "checked_in", "completed", "cancelled", "no_show", "refunded"}

ALLOWED_TRANSITIONS: dict[str, set[str]] = {
    "draft": {"confirmed", "cancelled"},
    "confirmed": {"checked_in", "cancelled", "no_show"},
    "checked_in": {"completed", "cancelled"},
    "completed": {"refunded"},
    "cancelled": {"refunded"},
    "no_show": {"refunded"},
    "refunded": set(),
}


def validate_status_transition(current: str, new: str) -> None:
    if current not in BOOKING_STATUSES:
        raise ValueError(f"Unknown booking status: {current!r}")
    if new not in BOOKING_STATUSES:
        raise ValueError(f"Unknown booking status: {new!r}")
    if new not in ALLOWED_TRANSITIONS.get(current, set()):
        raise ValueError(f"Cannot move a booking from {current!r} to {new!r}")


# ---------------------------------------------------------------------------
# RULE-VIS-002: session capacity
# ---------------------------------------------------------------------------
def validate_session_capacity(*, capacity: int, already_booked: int, requested: int) -> None:
    """Raises if confirming `requested` more guests would exceed `capacity`,
    given `already_booked` guests already hold a confirmed/checked_in/
    completed booking on that session."""
    if requested < 0:
        raise ValueError("requested guest count cannot be negative")
    if already_booked + requested > capacity:
        available = max(capacity - already_booked, 0)
        raise ValueError(f"Session capacity is {capacity}; only {available} spot(s) remain, cannot confirm {requested} more.")


# ---------------------------------------------------------------------------
# RULE-VIS-004: activity slot capacity + welfare limits
# ---------------------------------------------------------------------------
def validate_activity_capacity(*, capacity_per_slot: int, already_booked: int, requested: int) -> None:
    if requested < 0:
        raise ValueError("requested quantity cannot be negative")
    if already_booked + requested > capacity_per_slot:
        available = max(capacity_per_slot - already_booked, 0)
        raise ValueError(f"This activity slot holds {capacity_per_slot}; only {available} spot(s) remain.")


def validate_welfare_limit(*, welfare_limit: dict | None, uses_today: int, requested: int) -> None:
    """RULE-VIS-004: horse-ride/animal-interaction style activities can
    declare a `max_uses_per_day` in their welfare_limit_json; nothing
    here is specific to horses — any activity can set this."""
    if not welfare_limit:
        return
    max_per_day = welfare_limit.get("max_uses_per_day")
    if max_per_day is not None and uses_today + requested > max_per_day:
        raise ValueError(f"This activity is limited to {max_per_day} use(s) per day for animal welfare; {uses_today} already scheduled today.")


def validate_handler_assignment(*, requires_staff_role: str | None, assigned_roles: set[str]) -> None:
    """RULE-VIS-005: an activity that requires a staff role (e.g. "horse
    handler") can only be scheduled if someone with that role is on the
    session's roster."""
    if requires_staff_role and requires_staff_role not in assigned_roles:
        raise ValueError(f"This activity requires a staff member with role {requires_staff_role!r} assigned to the session first.")


# ---------------------------------------------------------------------------
# Tech spec v0.6 §9 "Analytics Formulas"
# ---------------------------------------------------------------------------
def _safe_div(numerator: float, denominator: float) -> float:
    return numerator / denominator if denominator else 0.0


def compute_visitor_revenue(*, package_revenue: float, activity_revenue: float, retail_revenue: float) -> float:
    """"Visitor Revenue = Booking revenue + activity add-ons + visitor
    retail sales." `package_revenue` here is the package-only component
    of booking revenue (guests x package price) — activities are counted
    once, via `activity_revenue`, never folded into both to avoid
    double-counting a booking's own add-on lines."""
    return round(package_revenue + activity_revenue + retail_revenue, 2)


def compute_direct_visit_cost(
    *, staff_cost: float, activity_cost: float, included_product_cost: float, cleaning_utilities_cost: float, other_cost: float
) -> float:
    return round(staff_cost + activity_cost + included_product_cost + cleaning_utilities_cost + other_cost, 2)


def compute_gross_margin(*, visitor_revenue: float, direct_visit_cost: float) -> float:
    return round(visitor_revenue - direct_visit_cost, 2)


def compute_revenue_per_visitor(*, visitor_revenue: float, checked_in_visitors: int) -> float:
    return round(_safe_div(visitor_revenue, checked_in_visitors), 2)


def compute_activity_utilization(*, sold_slots: int, available_slots: int) -> float:
    """Returned as a 0-100 percentage."""
    return round(_safe_div(sold_slots, available_slots) * 100, 1)


def compute_retail_conversion(*, visitors_with_purchase: int, checked_in_visitors: int) -> float:
    """Returned as a 0-100 percentage."""
    return round(_safe_div(visitors_with_purchase, checked_in_visitors) * 100, 1)


def compute_average_basket_value(*, retail_sales_total: float, purchase_count: int) -> float:
    return round(_safe_div(retail_sales_total, purchase_count), 2)


def compute_package_profitability(*, package_revenue: float, allocated_costs: float) -> float:
    return round(package_revenue - allocated_costs, 2)


@dataclass(frozen=True)
class ProfitabilitySummary:
    visitor_revenue: float
    direct_visit_cost: float
    gross_margin: float
    revenue_per_visitor: float
    retail_conversion_pct: float
    average_basket_value: float
    checked_in_visitors: int


def summarize_profitability(
    *,
    package_revenue: float,
    activity_revenue: float,
    retail_revenue: float,
    staff_cost: float,
    activity_cost: float,
    included_product_cost: float,
    cleaning_utilities_cost: float,
    other_cost: float,
    checked_in_visitors: int,
    visitors_with_purchase: int,
    purchase_count: int,
) -> ProfitabilitySummary:
    revenue = compute_visitor_revenue(package_revenue=package_revenue, activity_revenue=activity_revenue, retail_revenue=retail_revenue)
    cost = compute_direct_visit_cost(
        staff_cost=staff_cost,
        activity_cost=activity_cost,
        included_product_cost=included_product_cost,
        cleaning_utilities_cost=cleaning_utilities_cost,
        other_cost=other_cost,
    )
    return ProfitabilitySummary(
        visitor_revenue=revenue,
        direct_visit_cost=cost,
        gross_margin=compute_gross_margin(visitor_revenue=revenue, direct_visit_cost=cost),
        revenue_per_visitor=compute_revenue_per_visitor(visitor_revenue=revenue, checked_in_visitors=checked_in_visitors),
        retail_conversion_pct=compute_retail_conversion(visitors_with_purchase=visitors_with_purchase, checked_in_visitors=checked_in_visitors),
        average_basket_value=compute_average_basket_value(retail_sales_total=retail_revenue, purchase_count=purchase_count),
        checked_in_visitors=checked_in_visitors,
    )
