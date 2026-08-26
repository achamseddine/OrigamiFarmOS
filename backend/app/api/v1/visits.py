"""Farm Visits & Agri-Tourism — tech spec v0.6.

No shared URL prefix (the spec lists bare paths like `/visit-sessions`,
`/visit-bookings`, ...), so every route spells out its full path and the
whole router (except the status check) is gated behind the farm's
"visits_agritourism" module license via router-level `dependencies=`.
Nothing here hard-codes "Friday/Saturday/Sunday" or "horse ride" — see
app/visits/seed.py for the demo data that happens to use them as
examples.
"""
from __future__ import annotations

from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import (
    get_current_user,
    require_cashier_role,
    require_incident_report_role,
    require_manager_role,
    require_module_license,
    require_visit_operations_role,
)
from app.db.base import get_db
from app.domain import models, mouneh_models, visits_models as vm
from app.repositories.base import new_id, now
from app.schemas.visits import (
    BookingActivitySelection,
    OpeningCalendarDayOut,
    OpeningCalendarDayUpsert,
    VisitActivityCreate,
    VisitActivityOut,
    VisitBookingCancelRequest,
    VisitBookingCreate,
    VisitBookingOut,
    VisitCostCreate,
    VisitCostOut,
    VisitDashboardOut,
    VisitIncidentCreate,
    VisitIncidentOut,
    VisitorFeedbackCreate,
    VisitorFeedbackOut,
    VisitorProfileCreate,
    VisitorProfileOut,
    VisitPackageCreate,
    VisitPackageOut,
    VisitProfitabilityOut,
    VisitRetailSaleCreate,
    VisitRetailSaleOut,
    VisitSessionCreate,
    VisitSessionOut,
    VisitSessionUpdate,
    VisitStaffRosterCreate,
    VisitStaffRosterOut,
)
from app.services import visits_service
from app.visits import analytics

MODULE_CODE = vm.VISITS_MODULE_CODE

status_router = APIRouter(tags=["visits"])
router = APIRouter(tags=["visits"], dependencies=[Depends(require_module_license(MODULE_CODE))])


def _write_event(db: Session, *, farm_id: str, entity_type: str, entity_id: str, event_type: str, payload: dict, user_id: str) -> None:
    db.add(
        vm.VisitEvent(
            id=new_id(), farm_id=farm_id, entity_type=entity_type, entity_id=entity_id,
            event_type=event_type, payload_json=payload, created_by=user_id, created_at=now(),
        )
    )


# ---------------------------------------------------------------------------
# Module status (works even when inactive, so the UI can show "ask a
# super user to activate this")
# ---------------------------------------------------------------------------
@status_router.get("/modules/visits/status")
def visits_module_status(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> dict:
    license_row = db.scalars(
        select(mouneh_models.ModuleLicense).where(
            mouneh_models.ModuleLicense.farm_id == current_user.farm_id, mouneh_models.ModuleLicense.module_code == MODULE_CODE
        )
    ).one_or_none()
    active = license_row is not None and license_row.status in {"active", "trial"}
    return {
        "module_code": MODULE_CODE,
        "status": license_row.status if license_row else "inactive",
        "active": active,
        "features": license_row.features_json if license_row else {},
    }


# ---------------------------------------------------------------------------
# Opening calendar (RULE-VIS-003: configurable, never hard-coded)
# ---------------------------------------------------------------------------
@router.get("/visit-calendar", response_model=list[OpeningCalendarDayOut])
def list_opening_calendar(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[vm.VisitOpeningCalendar]:
    return list(
        db.scalars(
            select(vm.VisitOpeningCalendar)
            .where(vm.VisitOpeningCalendar.farm_id == current_user.farm_id)
            .order_by(vm.VisitOpeningCalendar.weekday)
        )
    )


@router.post("/visit-calendar", response_model=OpeningCalendarDayOut, status_code=status.HTTP_201_CREATED)
def upsert_opening_calendar_day(
    payload: OpeningCalendarDayUpsert, db: Session = Depends(get_db), current_user: models.User = Depends(require_manager_role)
) -> vm.VisitOpeningCalendar:
    row = db.scalars(
        select(vm.VisitOpeningCalendar).where(
            vm.VisitOpeningCalendar.farm_id == current_user.farm_id, vm.VisitOpeningCalendar.weekday == payload.weekday
        )
    ).one_or_none()
    if row is None:
        row = vm.VisitOpeningCalendar(id=new_id(), farm_id=current_user.farm_id, weekday=payload.weekday)
        db.add(row)
    row.is_open = payload.is_open
    row.open_time = payload.open_time
    row.close_time = payload.close_time
    row.default_capacity = payload.default_capacity
    row.notes = payload.notes
    row.created_by = row.created_by or current_user.id
    _write_event(db, farm_id=current_user.farm_id, entity_type="visit_opening_calendar", entity_id=row.id, event_type="calendar_day_updated", payload={"weekday": payload.weekday, "is_open": payload.is_open}, user_id=current_user.id)
    db.commit()
    db.refresh(row)
    return row


# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------
def _session_or_404(db: Session, session_id: str, farm_id: str) -> vm.VisitSession:
    session = db.get(vm.VisitSession, session_id)
    if session is None or session.farm_id != farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Visit session not found")
    return session


@router.post("/visit-sessions", response_model=VisitSessionOut, status_code=status.HTTP_201_CREATED)
def create_session(payload: VisitSessionCreate, db: Session = Depends(get_db), current_user: models.User = Depends(require_manager_role)) -> vm.VisitSession:
    session = vm.VisitSession(
        id=new_id(), farm_id=current_user.farm_id, created_by=current_user.id,
        **payload.model_dump(),
    )
    db.add(session)
    _write_event(db, farm_id=current_user.farm_id, entity_type="visit_session", entity_id=session.id, event_type="session_created", payload={"date": payload.date.isoformat(), "capacity": payload.capacity}, user_id=current_user.id)
    db.commit()
    db.refresh(session)
    return session


@router.get("/visit-sessions", response_model=list[VisitSessionOut])
def list_sessions(
    date_from: date | None = None,
    date_to: date | None = None,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> list[vm.VisitSession]:
    stmt = select(vm.VisitSession).where(vm.VisitSession.farm_id == current_user.farm_id)
    if date_from:
        stmt = stmt.where(vm.VisitSession.date >= date_from)
    if date_to:
        stmt = stmt.where(vm.VisitSession.date <= date_to)
    return list(db.scalars(stmt.order_by(vm.VisitSession.date, vm.VisitSession.start_time)))


@router.get("/visit-sessions/{session_id}", response_model=VisitSessionOut)
def get_session(session_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> vm.VisitSession:
    return _session_or_404(db, session_id, current_user.farm_id)


@router.patch("/visit-sessions/{session_id}", response_model=VisitSessionOut)
def update_session(
    session_id: str, payload: VisitSessionUpdate, db: Session = Depends(get_db), current_user: models.User = Depends(require_manager_role)
) -> vm.VisitSession:
    """RULE-VIS-009: the manager can close a session (weather, safety,
    staffing, private event) by setting status='closed'/'cancelled'."""
    session = _session_or_404(db, session_id, current_user.farm_id)
    changes = payload.model_dump(exclude_unset=True)
    for field, value in changes.items():
        setattr(session, field, value)
    _write_event(db, farm_id=current_user.farm_id, entity_type="visit_session", entity_id=session.id, event_type="session_updated", payload=changes, user_id=current_user.id)
    db.commit()
    db.refresh(session)
    return session


# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
@router.post("/visit-packages", response_model=VisitPackageOut, status_code=status.HTTP_201_CREATED)
def create_package(payload: VisitPackageCreate, db: Session = Depends(get_db), current_user: models.User = Depends(require_manager_role)) -> vm.VisitPackage:
    package = vm.VisitPackage(id=new_id(), farm_id=current_user.farm_id, created_by=current_user.id, **payload.model_dump())
    db.add(package)
    _write_event(db, farm_id=current_user.farm_id, entity_type="visit_package", entity_id=package.id, event_type="package_created", payload={"name": payload.name}, user_id=current_user.id)
    db.commit()
    db.refresh(package)
    return package


@router.get("/visit-packages", response_model=list[VisitPackageOut])
def list_packages(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[vm.VisitPackage]:
    return list(db.scalars(select(vm.VisitPackage).where(vm.VisitPackage.farm_id == current_user.farm_id).order_by(vm.VisitPackage.name)))


# ---------------------------------------------------------------------------
# Activities
# ---------------------------------------------------------------------------
@router.post("/visit-activities", response_model=VisitActivityOut, status_code=status.HTTP_201_CREATED)
def create_activity(payload: VisitActivityCreate, db: Session = Depends(get_db), current_user: models.User = Depends(require_manager_role)) -> vm.VisitActivity:
    activity = vm.VisitActivity(id=new_id(), farm_id=current_user.farm_id, created_by=current_user.id, **payload.model_dump())
    db.add(activity)
    _write_event(db, farm_id=current_user.farm_id, entity_type="visit_activity", entity_id=activity.id, event_type="activity_created", payload={"name": payload.name, "activity_type": payload.activity_type}, user_id=current_user.id)
    db.commit()
    db.refresh(activity)
    return activity


@router.get("/visit-activities", response_model=list[VisitActivityOut])
def list_activities(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[vm.VisitActivity]:
    return list(db.scalars(select(vm.VisitActivity).where(vm.VisitActivity.farm_id == current_user.farm_id).order_by(vm.VisitActivity.name)))


# ---------------------------------------------------------------------------
# Visitors (CRM)
# ---------------------------------------------------------------------------
@router.post("/visitors", response_model=VisitorProfileOut, status_code=status.HTTP_201_CREATED)
def create_visitor(payload: VisitorProfileCreate, db: Session = Depends(get_db), current_user: models.User = Depends(require_visit_operations_role)) -> vm.VisitorProfile:
    visitor = vm.VisitorProfile(id=new_id(), farm_id=current_user.farm_id, created_by=current_user.id, **payload.model_dump())
    db.add(visitor)
    _write_event(db, farm_id=current_user.farm_id, entity_type="visitor_profile", entity_id=visitor.id, event_type="visitor_created", payload={"full_name": payload.full_name}, user_id=current_user.id)
    db.commit()
    db.refresh(visitor)
    return visitor


@router.get("/visitors", response_model=list[VisitorProfileOut])
def list_visitors(db: Session = Depends(get_db), current_user: models.User = Depends(require_visit_operations_role)) -> list[vm.VisitorProfile]:
    """RULE-VIS-010: visitor PII is permission-controlled — only
    visit-operations roles (owner/manager/visitor_coordinator) can list
    visitor CRM records; nobody else gets a route to it in this router."""
    return list(db.scalars(select(vm.VisitorProfile).where(vm.VisitorProfile.farm_id == current_user.farm_id).order_by(vm.VisitorProfile.full_name)))


# ---------------------------------------------------------------------------
# Bookings (RULE-VIS-002/004/005/008)
# ---------------------------------------------------------------------------
def _booking_or_404(db: Session, booking_id: str, farm_id: str) -> vm.VisitBooking:
    booking = db.get(vm.VisitBooking, booking_id)
    if booking is None or booking.farm_id != farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Booking not found")
    return booking


def _validate_and_price_activities(
    db: Session, activities: list[BookingActivitySelection], *, exclude_booking_activity_ids: set[str] | None = None
) -> list[tuple[vm.VisitActivity, int]]:
    exclude_booking_activity_ids = exclude_booking_activity_ids or set()
    resolved: list[tuple[vm.VisitActivity, int]] = []
    for sel in activities:
        activity = db.get(vm.VisitActivity, sel.activity_id)
        if activity is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, f"Activity {sel.activity_id} not found")
        already = visits_service.activity_booked_quantity(db, activity.id, sel.scheduled_at)
        try:
            analytics.validate_activity_capacity(capacity_per_slot=activity.capacity_per_slot, already_booked=already, requested=sel.quantity)
            uses_today = visits_service.activity_uses_on_day(db, activity.id, sel.scheduled_at.date())
            analytics.validate_welfare_limit(welfare_limit=activity.welfare_limit_json, uses_today=uses_today, requested=sel.quantity)
            # Handler assignment (RULE-VIS-005) is re-checked at confirm
            # time, once the session's staff roster is more likely final.
        except ValueError as exc:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(exc)) from exc
        resolved.append((activity, sel.quantity))
    return resolved


@router.post("/visit-bookings", response_model=VisitBookingOut, status_code=status.HTTP_201_CREATED)
def create_booking(payload: VisitBookingCreate, db: Session = Depends(get_db), current_user: models.User = Depends(require_visit_operations_role)) -> vm.VisitBooking:
    session = _session_or_404(db, payload.session_id, current_user.farm_id)
    package = db.get(vm.VisitPackage, payload.package_id)
    if package is None or package.farm_id != current_user.farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Package not found")

    if payload.visitor_id:
        visitor = db.get(vm.VisitorProfile, payload.visitor_id)
        if visitor is None or visitor.farm_id != current_user.farm_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Visitor not found")
    elif payload.visitor:
        visitor = vm.VisitorProfile(id=new_id(), farm_id=current_user.farm_id, created_by=current_user.id, **payload.visitor.model_dump())
        db.add(visitor)
        db.flush()
    else:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Provide visitor_id or a new visitor's details")

    if payload.idempotency_key:
        dup = db.scalars(
            select(vm.VisitBooking).where(vm.VisitBooking.farm_id == current_user.farm_id, vm.VisitBooking.idempotency_key == payload.idempotency_key)
        ).one_or_none()
        if dup is not None:
            return dup

    resolved_activities = _validate_and_price_activities(db, payload.activities)
    guest_count = payload.adults + payload.children
    total_amount, _activity_revenue = visits_service.compute_booking_amount(package, resolved_activities, guest_count=guest_count)

    booking = vm.VisitBooking(
        id=new_id(), farm_id=current_user.farm_id, visitor_id=visitor.id, session_id=session.id, package_id=package.id,
        status="draft", adults=payload.adults, children=payload.children, total_amount=total_amount,
        deposit_amount=payload.deposit_amount, balance_due=round(total_amount - payload.deposit_amount, 2),
        source=payload.source, payment_method=payload.payment_method, notes=payload.notes,
        idempotency_key=payload.idempotency_key, created_by=current_user.id,
    )
    db.add(booking)
    db.flush()
    for activity, qty in resolved_activities:
        sel = next(s for s in payload.activities if s.activity_id == activity.id)
        db.add(vm.VisitBookingActivity(id=new_id(), booking_id=booking.id, activity_id=activity.id, scheduled_at=sel.scheduled_at, quantity=qty, unit_price=activity.price))

    _write_event(db, farm_id=current_user.farm_id, entity_type="visit_booking", entity_id=booking.id, event_type="booking_created", payload={"session_id": session.id, "guest_count": guest_count, "source": payload.source}, user_id=current_user.id)
    db.commit()
    db.refresh(booking)
    return booking


@router.get("/visit-bookings", response_model=list[VisitBookingOut])
def list_bookings(
    session_id: str | None = None,
    status_filter: str | None = Query(default=None, alias="status"),
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> list[vm.VisitBooking]:
    stmt = select(vm.VisitBooking).where(vm.VisitBooking.farm_id == current_user.farm_id)
    if session_id:
        stmt = stmt.where(vm.VisitBooking.session_id == session_id)
    if status_filter:
        stmt = stmt.where(vm.VisitBooking.status == status_filter)
    return list(db.scalars(stmt.order_by(vm.VisitBooking.created_at.desc())))


def _transition(db: Session, booking: vm.VisitBooking, new_status: str, *, user_id: str, timestamp_field: str | None = None) -> None:
    try:
        analytics.validate_status_transition(booking.status, new_status)
    except ValueError as exc:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(exc)) from exc
    old_status = booking.status
    booking.status = new_status
    if timestamp_field:
        setattr(booking, timestamp_field, now())
    _write_event(db, farm_id=booking.farm_id, entity_type="visit_booking", entity_id=booking.id, event_type="booking_status_changed", payload={"from": old_status, "to": new_status}, user_id=user_id)


@router.post("/visit-bookings/{booking_id}/confirm", response_model=VisitBookingOut)
def confirm_booking(booking_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(require_visit_operations_role)) -> vm.VisitBooking:
    """RULE-VIS-002: cannot confirm if the session capacity would be
    exceeded."""
    booking = _booking_or_404(db, booking_id, current_user.farm_id)
    session = db.get(vm.VisitSession, booking.session_id)
    already_booked = visits_service.session_confirmed_guest_count(db, booking.session_id, exclude_booking_id=booking.id)
    try:
        analytics.validate_session_capacity(capacity=session.capacity, already_booked=already_booked, requested=booking.guest_count)
    except ValueError as exc:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(exc)) from exc

    for ba in booking.activities:
        activity = db.get(vm.VisitActivity, ba.activity_id)
        if activity and activity.requires_staff_role:
            roles = visits_service.session_assigned_roles(db, booking.session_id)
            try:
                analytics.validate_handler_assignment(requires_staff_role=activity.requires_staff_role, assigned_roles=roles)
            except ValueError as exc:
                raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(exc)) from exc

    _transition(db, booking, "confirmed", user_id=current_user.id, timestamp_field="confirmed_at")
    db.commit()
    db.refresh(booking)
    return booking


@router.post("/visit-bookings/{booking_id}/check-in", response_model=VisitBookingOut)
def check_in_booking(booking_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(require_visit_operations_role)) -> vm.VisitBooking:
    booking = _booking_or_404(db, booking_id, current_user.farm_id)
    _transition(db, booking, "checked_in", user_id=current_user.id, timestamp_field="checked_in_at")
    db.commit()
    db.refresh(booking)
    return booking


@router.post("/visit-bookings/{booking_id}/complete", response_model=VisitBookingOut)
def complete_booking(booking_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(require_visit_operations_role)) -> vm.VisitBooking:
    booking = _booking_or_404(db, booking_id, current_user.farm_id)
    _transition(db, booking, "completed", user_id=current_user.id, timestamp_field="completed_at")
    db.commit()
    db.refresh(booking)
    return booking


@router.post("/visit-bookings/{booking_id}/no-show", response_model=VisitBookingOut)
def mark_booking_no_show(booking_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(require_visit_operations_role)) -> vm.VisitBooking:
    booking = _booking_or_404(db, booking_id, current_user.farm_id)
    _transition(db, booking, "no_show", user_id=current_user.id)
    db.commit()
    db.refresh(booking)
    return booking


@router.post("/visit-bookings/{booking_id}/cancel", response_model=VisitBookingOut)
def cancel_booking(booking_id: str, payload: VisitBookingCancelRequest = VisitBookingCancelRequest(), db: Session = Depends(get_db), current_user: models.User = Depends(require_visit_operations_role)) -> vm.VisitBooking:
    booking = _booking_or_404(db, booking_id, current_user.farm_id)
    target = "refunded" if (payload.refund and booking.status in {"completed", "cancelled", "no_show"}) else "cancelled"
    _transition(db, booking, target, user_id=current_user.id, timestamp_field="cancelled_at" if target == "cancelled" else None)
    if payload.reason:
        booking.notes = f"{booking.notes + ' | ' if booking.notes else ''}Cancellation reason: {payload.reason}"
    db.commit()
    db.refresh(booking)
    return booking


# ---------------------------------------------------------------------------
# Staff roster + costs (RULE-VIS-005/007)
# ---------------------------------------------------------------------------
@router.post("/visit-staff-roster", response_model=VisitStaffRosterOut, status_code=status.HTTP_201_CREATED)
def create_staff_roster_entry(payload: VisitStaffRosterCreate, db: Session = Depends(get_db), current_user: models.User = Depends(require_manager_role)) -> vm.VisitStaffRoster:
    session = _session_or_404(db, payload.session_id, current_user.farm_id)
    hours = (
        datetime.combine(date.today(), payload.end_time) - datetime.combine(date.today(), payload.start_time)
    ).total_seconds() / 3600
    total_cost = round(max(hours, 0) * payload.hourly_rate, 2)
    entry = vm.VisitStaffRoster(id=new_id(), farm_id=current_user.farm_id, total_cost=total_cost, created_by=current_user.id, **payload.model_dump())
    db.add(entry)
    _write_event(db, farm_id=current_user.farm_id, entity_type="visit_staff_roster", entity_id=entry.id, event_type="roster_entry_created", payload={"session_id": session.id, "role": payload.role}, user_id=current_user.id)
    db.commit()
    db.refresh(entry)
    return entry


@router.get("/visit-staff-roster", response_model=list[VisitStaffRosterOut])
def list_staff_roster(session_id: str | None = None, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[vm.VisitStaffRoster]:
    stmt = select(vm.VisitStaffRoster).where(vm.VisitStaffRoster.farm_id == current_user.farm_id)
    if session_id:
        stmt = stmt.where(vm.VisitStaffRoster.session_id == session_id)
    return list(db.scalars(stmt))


@router.post("/visit-costs", response_model=VisitCostOut, status_code=status.HTTP_201_CREATED)
def create_cost(payload: VisitCostCreate, db: Session = Depends(get_db), current_user: models.User = Depends(require_manager_role)) -> vm.VisitCost:
    _session_or_404(db, payload.session_id, current_user.farm_id)
    cost = vm.VisitCost(id=new_id(), farm_id=current_user.farm_id, created_by=current_user.id, **payload.model_dump())
    db.add(cost)
    _write_event(db, farm_id=current_user.farm_id, entity_type="visit_cost", entity_id=cost.id, event_type="cost_recorded", payload={"category": payload.category, "amount": payload.amount}, user_id=current_user.id)
    db.commit()
    db.refresh(cost)
    return cost


@router.get("/visit-costs", response_model=list[VisitCostOut])
def list_costs(session_id: str | None = None, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[vm.VisitCost]:
    stmt = select(vm.VisitCost).where(vm.VisitCost.farm_id == current_user.farm_id)
    if session_id:
        stmt = stmt.where(vm.VisitCost.session_id == session_id)
    return list(db.scalars(stmt))


# ---------------------------------------------------------------------------
# Retail / POS (RULE-VIS-006)
# ---------------------------------------------------------------------------
@router.post("/visit-retail-sales", response_model=VisitRetailSaleOut, status_code=status.HTTP_201_CREATED)
def record_retail_sale(payload: VisitRetailSaleCreate, db: Session = Depends(get_db), current_user: models.User = Depends(require_cashier_role)) -> dict:
    """Deducts inventory (plain items or Mouneh finished goods) and
    creates a core `Sale` row so the purchase flows into Sales & Finance
    (RULE-VIS-006), then links it back to the booking/visitor."""
    from app.domain import models as core_models

    total_amount = 0.0
    for line in payload.lines:
        if bool(line.inventory_item_id) == bool(line.finished_goods_stock_id):
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Each line needs exactly one of inventory_item_id or finished_goods_stock_id")
        total_amount += line.quantity * line.unit_price

    sale = core_models.Sale(
        id=new_id(), farm_id=current_user.farm_id, customer_id=None, product_type="visitor_retail",
        product_label="Visitor farm shop purchase", amount=round(total_amount, 2), payment_status=payload.payment_status, sold_at=now(),
    )
    db.add(sale)
    db.flush()

    for line in payload.lines:
        if line.inventory_item_id:
            item = db.get(core_models.InventoryItem, line.inventory_item_id)
            if item is None or item.farm_id != current_user.farm_id:
                raise HTTPException(status.HTTP_404_NOT_FOUND, f"Inventory item {line.inventory_item_id} not found")
            item.current_qty -= line.quantity
            db.add(core_models.InventoryTransaction(id=new_id(), item_id=item.id, direction="out", quantity=line.quantity, unit_cost=line.unit_price, reason="visitor_retail_sale", linked_entity_type="sale", linked_entity_id=sale.id, created_at=now()))
        else:
            from app.domain import mouneh_models as mm

            stock = db.get(mm.FinishedGoodsStock, line.finished_goods_stock_id)
            if stock is None or stock.farm_id != current_user.farm_id:
                raise HTTPException(status.HTTP_404_NOT_FOUND, f"Finished goods stock {line.finished_goods_stock_id} not found")
            if line.quantity > stock.quantity_available:
                raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"Only {stock.quantity_available} units available")
            stock.quantity_available -= line.quantity
            stock.quantity_sold += line.quantity
            margin = line.quantity * (line.unit_price - stock.unit_cost)
            db.add(mm.MounehSaleLine(id=new_id(), farm_id=current_user.farm_id, product_id=stock.product_id, batch_id=stock.batch_id, finished_goods_stock_id=stock.id, quantity=line.quantity, unit_price=line.unit_price, discount=0, customer_id=None, channel="retail", cost_per_unit=stock.unit_cost, revenue=line.quantity * line.unit_price, margin=margin, sold_at=now(), sold_by=current_user.id))

    retail_sale = vm.VisitRetailSale(id=new_id(), farm_id=current_user.farm_id, booking_id=payload.booking_id, visitor_id=payload.visitor_id, sale_id=sale.id, channel=payload.channel, notes=None)
    db.add(retail_sale)
    _write_event(db, farm_id=current_user.farm_id, entity_type="visit_retail_sale", entity_id=retail_sale.id, event_type="retail_sale_recorded", payload={"total_amount": round(total_amount, 2), "channel": payload.channel}, user_id=current_user.id)
    db.commit()
    db.refresh(retail_sale)
    return {"id": retail_sale.id, "booking_id": retail_sale.booking_id, "visitor_id": retail_sale.visitor_id, "sale_id": sale.id, "channel": retail_sale.channel, "total_amount": round(total_amount, 2)}


@router.get("/visit-retail-sales")
def list_retail_sales(booking_id: str | None = None, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[dict]:
    from app.domain import models as core_models

    stmt = select(vm.VisitRetailSale).where(vm.VisitRetailSale.farm_id == current_user.farm_id)
    if booking_id:
        stmt = stmt.where(vm.VisitRetailSale.booking_id == booking_id)
    rows = list(db.scalars(stmt))
    out = []
    for r in rows:
        sale = db.get(core_models.Sale, r.sale_id)
        out.append({"id": r.id, "booking_id": r.booking_id, "visitor_id": r.visitor_id, "sale_id": r.sale_id, "channel": r.channel, "total_amount": sale.amount if sale else 0})
    return out


# ---------------------------------------------------------------------------
# Feedback + incidents
# ---------------------------------------------------------------------------
@router.post("/visitor-feedback", response_model=VisitorFeedbackOut, status_code=status.HTTP_201_CREATED)
def submit_feedback(payload: VisitorFeedbackCreate, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> vm.VisitorFeedback:
    booking = _booking_or_404(db, payload.booking_id, current_user.farm_id)
    feedback = vm.VisitorFeedback(id=new_id(), farm_id=current_user.farm_id, booking_id=booking.id, rating=payload.rating, comments=payload.comments, would_return=payload.would_return, submitted_at=now())
    db.add(feedback)
    db.commit()
    db.refresh(feedback)
    return feedback


@router.get("/visitor-feedback", response_model=list[VisitorFeedbackOut])
def list_feedback(booking_id: str | None = None, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[vm.VisitorFeedback]:
    stmt = select(vm.VisitorFeedback).where(vm.VisitorFeedback.farm_id == current_user.farm_id)
    if booking_id:
        stmt = stmt.where(vm.VisitorFeedback.booking_id == booking_id)
    return list(db.scalars(stmt.order_by(vm.VisitorFeedback.submitted_at.desc())))


@router.post("/visit-incidents", response_model=VisitIncidentOut, status_code=status.HTTP_201_CREATED)
def report_incident(payload: VisitIncidentCreate, db: Session = Depends(get_db), current_user: models.User = Depends(require_incident_report_role)) -> vm.VisitIncident:
    _session_or_404(db, payload.session_id, current_user.farm_id)
    incident = vm.VisitIncident(id=new_id(), farm_id=current_user.farm_id, created_by=current_user.id, **payload.model_dump())
    db.add(incident)
    _write_event(db, farm_id=current_user.farm_id, entity_type="visit_incident", entity_id=incident.id, event_type="incident_reported", payload={"incident_type": payload.incident_type, "severity": payload.severity}, user_id=current_user.id)
    db.commit()
    db.refresh(incident)
    return incident


@router.get("/visit-incidents", response_model=list[VisitIncidentOut])
def list_incidents(session_id: str | None = None, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[vm.VisitIncident]:
    stmt = select(vm.VisitIncident).where(vm.VisitIncident.farm_id == current_user.farm_id)
    if session_id:
        stmt = stmt.where(vm.VisitIncident.session_id == session_id)
    return list(db.scalars(stmt.order_by(vm.VisitIncident.created_at.desc())))


# ---------------------------------------------------------------------------
# Reports + dashboard
# ---------------------------------------------------------------------------
@router.get("/reports/visit-profitability", response_model=VisitProfitabilityOut)
def visit_profitability(
    session_id: str | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    if session_id:
        _session_or_404(db, session_id, current_user.farm_id)
        result = visits_service.session_profitability(db, session_id)
        scope = f"session:{session_id}"
    else:
        start = date_from or date.today()
        end = date_to or date.today()
        result = visits_service.range_profitability(db, current_user.farm_id, start, end)
        scope = f"range:{start.isoformat()}..{end.isoformat()}"
    return {"scope": scope, **result}


@router.get("/visits/dashboard", response_model=VisitDashboardOut)
def visits_dashboard(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> dict:
    license_row = db.scalars(
        select(mouneh_models.ModuleLicense).where(mouneh_models.ModuleLicense.farm_id == current_user.farm_id, mouneh_models.ModuleLicense.module_code == MODULE_CODE)
    ).one_or_none()
    today = date.today()
    upcoming = list(db.scalars(select(vm.VisitSession).where(vm.VisitSession.farm_id == current_user.farm_id, vm.VisitSession.date >= today).order_by(vm.VisitSession.date)))
    today_sessions = [s for s in upcoming if s.date == today]
    today_session_ids = [s.id for s in today_sessions]
    today_bookings = list(
        db.scalars(
            select(vm.VisitBooking).where(vm.VisitBooking.session_id.in_(today_session_ids), vm.VisitBooking.status.in_(("confirmed", "checked_in", "completed")))
        )
    ) if today_session_ids else []
    today_expected_visitors = sum(b.guest_count for b in today_bookings)
    today_expected_revenue = sum(b.total_amount for b in today_bookings)
    open_incidents_count = (
        len(list(db.scalars(select(vm.VisitIncident).where(vm.VisitIncident.farm_id == current_user.farm_id, vm.VisitIncident.session_id.in_(today_session_ids)))))
        if today_session_ids
        else 0
    )

    return {
        "module_status": license_row.status if license_row else "inactive",
        "upcoming_sessions": len(upcoming),
        "today_bookings": len(today_bookings),
        "today_expected_visitors": today_expected_visitors,
        "today_expected_revenue": round(today_expected_revenue, 2),
        "open_incidents": open_incidents_count,
        "sessions": upcoming[:14],
    }
