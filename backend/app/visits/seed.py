"""Demo data for the Farm Visits & Agri-Tourism module.

Tech spec v0.6: "Use weekend-only as default sample data for Lebanese
farm context" and "Do not hard-code Friday/Saturday/Sunday ... they are
examples of dynamic products/activities." The opening calendar below is
plain data written through the same rows the Opening Calendar screen
would write — nothing in app/api/v1/visits.py branches on a specific
weekday or a specific activity name.
"""
from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import mouneh_models
from app.domain import models as core_models
from app.domain import visits_models as vm
from app.repositories.base import new_id

FARM_ID = "farm-origami"


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _next_weekday(from_date: date, target_weekday: int) -> date:
    """target_weekday: 0=Monday .. 6=Sunday (Python's date.weekday())."""
    days_ahead = (target_weekday - from_date.weekday()) % 7
    days_ahead = days_ahead or 7
    return from_date + timedelta(days=days_ahead)


def _last_weekday(from_date: date, target_weekday: int) -> date:
    days_back = (from_date.weekday() - target_weekday) % 7
    days_back = days_back or 7
    return from_date - timedelta(days=days_back)


def seed_visits_demo_data(db: Session, farm_id: str = FARM_ID) -> None:
    existing = db.scalars(
        select(mouneh_models.ModuleLicense).where(
            mouneh_models.ModuleLicense.farm_id == farm_id, mouneh_models.ModuleLicense.module_code == vm.VISITS_MODULE_CODE
        )
    ).first()
    if existing is not None:
        print("Visits demo data already present — skipping.")
        return

    super_user_id = "user-super-1"  # seeded by app/mouneh/seed.py, which always runs first (see app/seed.py)
    license_row = mouneh_models.ModuleLicense(
        id=new_id(), farm_id=farm_id, module_code=vm.VISITS_MODULE_CODE, status="active", plan="farmos_experience",
        starts_at=_now() - timedelta(days=30), activated_by=super_user_id,
        features_json={"pos_integration": True, "staff_costing": True, "analytics": True},
    )
    db.add(license_row)

    # ---- Opening calendar: Friday/Saturday/Sunday, as an EXAMPLE only ---
    today = _now().date()
    weekend_open_time = time(9, 0)
    weekend_close_time = time(17, 0)
    for weekday in range(7):
        is_weekend = weekday in (4, 5, 6)  # Friday, Saturday, Sunday
        db.add(
            vm.VisitOpeningCalendar(
                id=new_id(), farm_id=farm_id, weekday=weekday, is_open=is_weekend,
                open_time=weekend_open_time if is_weekend else None,
                close_time=weekend_close_time if is_weekend else None,
                default_capacity=60 if is_weekend else 0,
                notes="Weekend agri-tourism opening" if is_weekend else None,
                created_by=super_user_id,
            )
        )

    # ---- Visitors -------------------------------------------------------
    visitor_family = vm.VisitorProfile(id="visitor-nour", farm_id=farm_id, full_name="Nour Khalil", phone="+961 71 555 010", preferred_language="ar", consent_marketing=True, created_by=super_user_id)
    visitor_walkin = vm.VisitorProfile(id="visitor-samir", farm_id=farm_id, full_name="Samir Aoun", phone="+961 03 555 020", preferred_language="ar", created_by=super_user_id)
    visitor_school = vm.VisitorProfile(id="visitor-school", farm_id=farm_id, full_name="Beirut Hills School (Ms. Farah)", phone="+961 01 555 030", email="trips@beiruthills.example", preferred_language="en", consent_marketing=True, notes="Group of 20 students, grade 4. Allergy: two students, tree nuts.", created_by=super_user_id)
    db.add_all([visitor_family, visitor_walkin, visitor_school])

    # ---- Packages ---------------------------------------------------------
    family_package = vm.VisitPackage(
        id="package-family-day", farm_id=farm_id, name="Family Farm Day",
        description="Entrance, guided animal tour, picnic area access and product tasting.",
        base_price=15, currency="USD", duration_minutes=180,
        included_items_json={"activity_ids": [], "product_lines": [{"finished_goods_product": "makdous_tasting", "quantity": 1}]},
        created_by=super_user_id,
    )
    school_package = vm.VisitPackage(
        id="package-school-visit", farm_id=farm_id, name="School Harvest Visit",
        description="Fixed per-student educational visit: farm tour, harvest picking, hygiene talk.",
        base_price=8, currency="USD", duration_minutes=120,
        included_items_json={"activity_ids": [], "product_lines": []},
        created_by=super_user_id,
    )
    db.add_all([family_package, school_package])

    # ---- Activities (dynamic; Horse Ride is only an example) --------------
    horse_ride = vm.VisitActivity(
        id="activity-horse-ride", farm_id=farm_id, name="Horse Ride", activity_type="ride",
        price=10, capacity_per_slot=4, duration_minutes=20,
        requires_staff_role="horse_handler", requires_animal_id="horse-h07",
        welfare_limit_json={"max_uses_per_day": 10, "min_rest_minutes_between_uses": 20},
        created_by=super_user_id,
    )
    cheese_workshop = vm.VisitActivity(
        id="activity-cheese-workshop", farm_id=farm_id, name="Cheese Making Workshop", activity_type="workshop",
        price=12, capacity_per_slot=8, duration_minutes=45, created_by=super_user_id,
    )
    db.add_all([horse_ride, cheese_workshop])
    db.flush()

    # ---- Sessions: an upcoming Saturday + a completed last Sunday --------
    upcoming_saturday = _next_weekday(today, 5)
    upcoming_sunday = _next_weekday(today, 6)
    past_sunday = _last_weekday(today, 6)

    session_upcoming = vm.VisitSession(
        id="session-upcoming-sat", farm_id=farm_id, date=upcoming_saturday, start_time=time(9, 0), end_time=time(17, 0),
        capacity=60, status="open", expected_staff_cost=90, created_by=super_user_id,
    )
    session_upcoming_2 = vm.VisitSession(
        id="session-upcoming-sun", farm_id=farm_id, date=upcoming_sunday, start_time=time(9, 0), end_time=time(17, 0),
        capacity=60, status="open", expected_staff_cost=90, created_by=super_user_id,
    )
    session_past = vm.VisitSession(
        id="session-past-sun", farm_id=farm_id, date=past_sunday, start_time=time(9, 0), end_time=time(17, 0),
        capacity=60, status="completed", created_by=super_user_id,
    )
    db.add_all([session_upcoming, session_upcoming_2, session_past])

    # ---- Staff roster for the upcoming Saturday (special weekend rates) --
    db.add_all([
        vm.VisitStaffRoster(id=new_id(), farm_id=farm_id, session_id=session_upcoming.id, worker_id="user-rami", role="guide", start_time=time(8, 30), end_time=time(17, 30), hourly_rate=6, total_cost=54, created_by=super_user_id),
        vm.VisitStaffRoster(id=new_id(), farm_id=farm_id, session_id=session_upcoming.id, worker_id="user-worker-1", role="horse_handler", start_time=time(8, 30), end_time=time(17, 30), hourly_rate=8, total_cost=72, created_by=super_user_id),
        vm.VisitStaffRoster(id=new_id(), farm_id=farm_id, session_id=session_upcoming.id, worker_id="user-acct-1", role="cashier", start_time=time(8, 30), end_time=time(17, 30), hourly_rate=5, total_cost=45, created_by=super_user_id),
    ])
    # The already-completed Sunday's roster (for its own profitability record).
    db.add_all([
        vm.VisitStaffRoster(id=new_id(), farm_id=farm_id, session_id=session_past.id, worker_id="user-rami", role="guide", start_time=time(8, 30), end_time=time(17, 30), hourly_rate=6, total_cost=54, created_by=super_user_id),
        vm.VisitStaffRoster(id=new_id(), farm_id=farm_id, session_id=session_past.id, worker_id="user-acct-1", role="cashier", start_time=time(8, 30), end_time=time(17, 30), hourly_rate=5, total_cost=45, created_by=super_user_id),
    ])

    # ---- Direct costs -----------------------------------------------------
    for session in (session_upcoming, session_past):
        db.add_all([
            vm.VisitCost(id=new_id(), farm_id=farm_id, session_id=session.id, category="cleaning", description="Bathrooms, waste collection", amount=20, allocation_method="per_session", created_by=super_user_id),
            vm.VisitCost(id=new_id(), farm_id=farm_id, session_id=session.id, category="utilities", description="Water and electricity for the visit day", amount=15, allocation_method="per_session", created_by=super_user_id),
            vm.VisitCost(id=new_id(), farm_id=farm_id, session_id=session.id, category="tasting", description="Tasting samples and disposable cups", amount=18, allocation_method="per_guest", created_by=super_user_id),
        ])

    # ---- Bookings across statuses -----------------------------------------
    # 1. Confirmed family booking with a Horse Ride add-on for the Saturday session.
    booking_confirmed = vm.VisitBooking(
        id="booking-family-sat", farm_id=farm_id, visitor_id=visitor_family.id, session_id=session_upcoming.id, package_id=family_package.id,
        status="confirmed", adults=2, children=2, total_amount=family_package.base_price * 4 + horse_ride.price * 2,
        deposit_amount=20, balance_due=family_package.base_price * 4 + horse_ride.price * 2 - 20, source="whatsapp",
        confirmed_at=_now() - timedelta(days=2), created_by=super_user_id,
    )
    db.add(booking_confirmed)
    db.flush()
    db.add(
        vm.VisitBookingActivity(
            id=new_id(), booking_id=booking_confirmed.id, activity_id=horse_ride.id,
            scheduled_at=datetime.combine(upcoming_saturday, time(11, 0), tzinfo=timezone.utc), quantity=2, unit_price=horse_ride.price,
        )
    )

    # 2. Walk-in already checked in for the Saturday session.
    booking_checked_in = vm.VisitBooking(
        id="booking-walkin-sat", farm_id=farm_id, visitor_id=visitor_walkin.id, session_id=session_upcoming.id, package_id=family_package.id,
        status="checked_in", adults=1, children=0, total_amount=family_package.base_price, deposit_amount=0,
        balance_due=family_package.base_price, source="walk_in", confirmed_at=_now(), checked_in_at=_now(), created_by=super_user_id,
    )
    db.add(booking_checked_in)

    # 3. School group booking, still a draft awaiting confirmation for next Sunday.
    booking_draft = vm.VisitBooking(
        id="booking-school-sun", farm_id=farm_id, visitor_id=visitor_school.id, session_id=session_upcoming_2.id, package_id=school_package.id,
        status="draft", adults=2, children=20, total_amount=school_package.base_price * 22, deposit_amount=0,
        balance_due=school_package.base_price * 22, source="phone", notes="Awaiting school's payment confirmation.", created_by=super_user_id,
    )
    db.add(booking_draft)

    # 4. A cancelled booking, for status-mix realism.
    booking_cancelled = vm.VisitBooking(
        id="booking-cancelled", farm_id=farm_id, visitor_id=visitor_walkin.id, session_id=session_upcoming_2.id, package_id=family_package.id,
        status="cancelled", adults=2, children=0, total_amount=family_package.base_price * 2, deposit_amount=0,
        balance_due=0, source="manual", cancelled_at=_now() - timedelta(days=1), notes="Cancellation reason: family reschedule.", created_by=super_user_id,
    )
    db.add(booking_cancelled)

    # 5. A completed booking from last Sunday, with a retail purchase, feedback and a minor incident.
    booking_completed = vm.VisitBooking(
        id="booking-completed-sun", farm_id=farm_id, visitor_id=visitor_family.id, session_id=session_past.id, package_id=family_package.id,
        status="completed", adults=2, children=1, total_amount=family_package.base_price * 3, deposit_amount=family_package.base_price * 3,
        balance_due=0, source="website", confirmed_at=_now() - timedelta(days=9), checked_in_at=_now() - timedelta(days=7, hours=-1),
        completed_at=_now() - timedelta(days=7), created_by=super_user_id,
    )
    db.add(booking_completed)
    db.flush()

    # Retail sale linked to the completed booking — sells actual Makdous
    # finished-goods stock (Mouneh module), demonstrating "visitor sales
    # deduct finished goods stock" cross-module integration.
    makdous_stock = db.get(mouneh_models.FinishedGoodsStock, "stock-makdous-001")
    if makdous_stock is not None and makdous_stock.quantity_available >= 2:
        sale = core_models.Sale(
            id=new_id(), farm_id=farm_id, customer_id=None, product_type="visitor_retail", product_label="Visitor farm shop purchase",
            amount=round(2 * 6.5, 2), payment_status="paid", sold_at=_now() - timedelta(days=7),
        )
        db.add(sale)
        makdous_stock.quantity_available -= 2
        makdous_stock.quantity_sold += 2
        db.add(
            mouneh_models.MounehSaleLine(
                id=new_id(), farm_id=farm_id, product_id=makdous_stock.product_id, batch_id=makdous_stock.batch_id,
                finished_goods_stock_id=makdous_stock.id, quantity=2, unit_price=6.5, discount=0, customer_id=None,
                channel="retail", cost_per_unit=makdous_stock.unit_cost, revenue=13.0, margin=13.0 - 2 * makdous_stock.unit_cost,
                sold_at=_now() - timedelta(days=7), sold_by=super_user_id,
            )
        )
        db.add(
            vm.VisitRetailSale(
                id=new_id(), farm_id=farm_id, booking_id=booking_completed.id, visitor_id=visitor_family.id, sale_id=sale.id,
                channel="farm_shop", notes="2 jars of Makdous bought after the tour.",
            )
        )

    db.add(
        vm.VisitorFeedback(
            id=new_id(), farm_id=farm_id, booking_id=booking_completed.id, rating=5,
            comments="Wonderful morning — kids loved feeding the goats.", would_return=True, submitted_at=_now() - timedelta(days=6),
        )
    )
    db.add(
        vm.VisitIncident(
            id=new_id(), farm_id=farm_id, session_id=session_past.id, booking_id=None, incident_type="weather", severity="low",
            description="Brief rain shower around midday.", action_taken="Moved the tasting session under the covered picnic area.",
            created_by=super_user_id,
        )
    )

    for entity_type, entity_id, event_type, payload in [
        ("visit_session", session_upcoming.id, "session_created", {"date": upcoming_saturday.isoformat()}),
        ("visit_booking", booking_confirmed.id, "booking_status_changed", {"to": "confirmed"}),
        ("visit_booking", booking_completed.id, "booking_status_changed", {"to": "completed"}),
    ]:
        db.add(
            vm.VisitEvent(id=new_id(), farm_id=farm_id, entity_type=entity_type, entity_id=entity_id, event_type=event_type, payload_json=payload, created_by=super_user_id, created_at=_now())
        )

    print(f"Seeded Farm Visits & Agri-Tourism demo data for farm '{farm_id}'.")
