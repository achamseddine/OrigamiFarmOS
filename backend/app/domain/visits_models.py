"""Farm Visits & Agri-Tourism — SQLAlchemy models (tech spec v0.6 §4).

Its own bounded context, same as `mouneh_models.py` — kept out of
`domain/models.py` and gated behind the same generic `ModuleLicense`
table (module_code="visits_agritourism") rather than a second license
mechanism, since that table was already designed to hold any number of
per-farm module rows.

Every table carries farm_id, created_at, updated_at, created_by,
sync_status and deleted_at (soft delete) per tech spec §4's "all tables
include tenant_id/farm_id ... unless otherwise stated" — line-item child
rows (booking activities) skip the full set the same way
`mouneh_recipe_items`/`batch_input_consumptions` do, since they are only
ever reached through their parent.

Nothing here hard-codes "Friday/Saturday/Sunday" or "horse ride" — see
app/visits/seed.py for the demo data that happens to use them as
examples of a configurable opening calendar and a dynamic activity.
"""
from __future__ import annotations

from datetime import date, datetime, time

from sqlalchemy import JSON, Boolean, Date, DateTime, Float, ForeignKey, Integer, String, Text, Time, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base
from app.domain.models import _now, _uuid

VISITS_MODULE_CODE = "visits_agritourism"


class VisitOpeningCalendar(Base):
    """RULE-VIS-003: opening days are configurable per farm, never
    hard-coded to a weekend."""

    __tablename__ = "visit_opening_calendar"
    __table_args__ = (UniqueConstraint("farm_id", "weekday", name="uq_visit_calendar_farm_weekday"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    weekday: Mapped[int] = mapped_column(Integer)  # 0=Monday .. 6=Sunday (Python date.weekday())
    is_open: Mapped[bool] = mapped_column(Boolean, default=False)
    open_time: Mapped[time | None] = mapped_column(Time, nullable=True)
    close_time: Mapped[time | None] = mapped_column(Time, nullable=True)
    default_capacity: Mapped[int] = mapped_column(Integer, default=0)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    sync_status: Mapped[str] = mapped_column(String(20), default="synced")
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class VisitSession(Base):
    __tablename__ = "visit_sessions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    date: Mapped[date] = mapped_column(Date)
    start_time: Mapped[time] = mapped_column(Time)
    end_time: Mapped[time] = mapped_column(Time)
    capacity: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(20), default="open")  # open|full|closed|cancelled|completed
    weather_note: Mapped[str | None] = mapped_column(Text, nullable=True)
    expected_staff_cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    sync_status: Mapped[str] = mapped_column(String(20), default="synced")
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    bookings: Mapped[list["VisitBooking"]] = relationship(back_populates="session")


class VisitPackage(Base):
    """A sellable bundled experience. `included_items_json` is a free-form
    description ({"activity_ids": [...], "product_lines": [...]}) — the
    Package Builder lets a manager compose any package, so nothing here
    is a fixed catalog entry (tech spec: "do not hard-code ... they are
    examples of dynamic products/activities")."""

    __tablename__ = "visit_packages"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    name: Mapped[str] = mapped_column(String(200))
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    base_price: Mapped[float] = mapped_column(Float, default=0)
    currency: Mapped[str] = mapped_column(String(10), default="USD")
    duration_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    included_items_json: Mapped[dict] = mapped_column(JSON, default=dict)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    sync_status: Mapped[str] = mapped_column(String(20), default="synced")
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class VisitActivity(Base):
    """An individual bookable activity — "horse ride" is only ever demo
    data (see app/visits/seed.py); a manager can create any activity
    through the Activity Manager screen (RULE unchanged from the
    Mouneh module's "dynamic product" principle)."""

    __tablename__ = "visit_activities"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    name: Mapped[str] = mapped_column(String(200))
    activity_type: Mapped[str] = mapped_column(String(30), default="other")  # tour|ride|workshop|tasting|event|other
    price: Mapped[float] = mapped_column(Float, default=0)
    capacity_per_slot: Mapped[int] = mapped_column(Integer, default=1)
    duration_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    requires_staff_role: Mapped[str | None] = mapped_column(String(50), nullable=True)
    requires_animal_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("animals.id"), nullable=True)
    # e.g. {"max_uses_per_day": 6, "min_rest_minutes_between_uses": 30} — RULE-VIS-004.
    welfare_limit_json: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    sync_status: Mapped[str] = mapped_column(String(20), default="synced")
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class VisitorProfile(Base):
    """Visitor CRM record — deliberately separate from `customers`
    (core Sales & Finance) since it carries visitor-specific consent and
    preference fields (RULE-VIS-010: permission-controlled PII)."""

    __tablename__ = "visitor_profiles"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    full_name: Mapped[str] = mapped_column(String(200))
    phone: Mapped[str | None] = mapped_column(String(50), nullable=True)
    email: Mapped[str | None] = mapped_column(String(200), nullable=True)
    preferred_language: Mapped[str] = mapped_column(String(5), default="en")
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    consent_marketing: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    sync_status: Mapped[str] = mapped_column(String(20), default="synced")
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class VisitBooking(Base):
    """A visitor reservation. `total_amount`/`balance_due` are stored for
    invoicing/payment tracking; profitability analytics (app/visits/analytics.py)
    recomputes revenue from the granular package/activity/retail lines
    instead of trusting this summary field, so a later manual override
    here never skews a report.

    Status transitions are validated by `app/visits/analytics.py::validate_status_transition`
    (RULE-VIS-008) and every transition writes a `VisitEvent` row —
    never overwritten, matching "booking status transitions must be
    auditable."
    """

    __tablename__ = "visit_bookings"
    __table_args__ = (UniqueConstraint("farm_id", "idempotency_key", name="uq_visit_booking_farm_idempotency"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    visitor_id: Mapped[str] = mapped_column(String(36), ForeignKey("visitor_profiles.id"))
    session_id: Mapped[str] = mapped_column(String(36), ForeignKey("visit_sessions.id"))
    package_id: Mapped[str] = mapped_column(String(36), ForeignKey("visit_packages.id"))
    status: Mapped[str] = mapped_column(String(20), default="draft")
    # draft|confirmed|checked_in|completed|cancelled|no_show|refunded
    adults: Mapped[int] = mapped_column(Integer, default=1)
    children: Mapped[int] = mapped_column(Integer, default=0)
    total_amount: Mapped[float] = mapped_column(Float, default=0)
    deposit_amount: Mapped[float] = mapped_column(Float, default=0)
    balance_due: Mapped[float] = mapped_column(Float, default=0)
    source: Mapped[str] = mapped_column(String(20), default="manual")  # manual|whatsapp|website|phone|walk_in
    payment_method: Mapped[str | None] = mapped_column(String(30), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    idempotency_key: Mapped[str | None] = mapped_column(String(100), nullable=True)
    confirmed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    checked_in_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    cancelled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    sync_status: Mapped[str] = mapped_column(String(20), default="synced")
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    session: Mapped[VisitSession] = relationship(back_populates="bookings")
    activities: Mapped[list["VisitBookingActivity"]] = relationship(back_populates="booking", cascade="all, delete-orphan")

    @property
    def guest_count(self) -> int:
        return self.adults + self.children


class VisitBookingActivity(Base):
    __tablename__ = "visit_booking_activities"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    booking_id: Mapped[str] = mapped_column(String(36), ForeignKey("visit_bookings.id"))
    activity_id: Mapped[str] = mapped_column(String(36), ForeignKey("visit_activities.id"))
    scheduled_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    quantity: Mapped[int] = mapped_column(Integer, default=1)
    unit_price: Mapped[float] = mapped_column(Float, default=0)
    status: Mapped[str] = mapped_column(String(20), default="scheduled")  # scheduled|completed|cancelled|missed
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    booking: Mapped[VisitBooking] = relationship(back_populates="activities")
    activity: Mapped[VisitActivity] = relationship()


class VisitStaffRoster(Base):
    __tablename__ = "visit_staff_roster"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    session_id: Mapped[str] = mapped_column(String(36), ForeignKey("visit_sessions.id"))
    worker_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"))
    role: Mapped[str] = mapped_column(String(50))  # guide|cashier|cleaner|horse_handler|...
    start_time: Mapped[time] = mapped_column(Time)
    end_time: Mapped[time] = mapped_column(Time)
    hourly_rate: Mapped[float] = mapped_column(Float, default=0)
    total_cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    sync_status: Mapped[str] = mapped_column(String(20), default="synced")
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class VisitCost(Base):
    __tablename__ = "visit_costs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    session_id: Mapped[str] = mapped_column(String(36), ForeignKey("visit_sessions.id"))
    category: Mapped[str] = mapped_column(String(30))
    # staff|cleaning|utilities|tasting|marketing|safety|maintenance|other
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    amount: Mapped[float] = mapped_column(Float, default=0)
    allocation_method: Mapped[str] = mapped_column(String(20), default="per_session")
    # per_session|per_guest|per_package|per_activity
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    sync_status: Mapped[str] = mapped_column(String(20), default="synced")
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class VisitRetailSale(Base):
    """Links a POS sale made during/after a visit back to the booking and
    to the core `sales` table (RULE-VIS-006: "must flow into Sales &
    Finance reporting") — the inventory deduction itself happens on the
    referenced `sale_id`'s line items, recorded the same way a farm-shop
    sale would be."""

    __tablename__ = "visit_retail_sales"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    booking_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("visit_bookings.id"), nullable=True)
    visitor_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("visitor_profiles.id"), nullable=True)
    sale_id: Mapped[str] = mapped_column(String(36), ForeignKey("sales.id"))
    channel: Mapped[str] = mapped_column(String(30), default="farm_shop")  # farm_shop|tasting_upgrade|delivery_after_visit
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    sync_status: Mapped[str] = mapped_column(String(20), default="synced")


class VisitorFeedback(Base):
    __tablename__ = "visitor_feedback"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    booking_id: Mapped[str] = mapped_column(String(36), ForeignKey("visit_bookings.id"))
    rating: Mapped[int] = mapped_column(Integer)
    comments: Mapped[str | None] = mapped_column(Text, nullable=True)
    would_return: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    submitted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class VisitIncident(Base):
    __tablename__ = "visit_incidents"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    session_id: Mapped[str] = mapped_column(String(36), ForeignKey("visit_sessions.id"))
    booking_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("visit_bookings.id"), nullable=True)
    incident_type: Mapped[str] = mapped_column(String(30))  # safety|animal|weather|payment|complaint|other
    severity: Mapped[str] = mapped_column(String(10), default="low")  # low|medium|high
    description: Mapped[str] = mapped_column(Text)
    action_taken: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    sync_status: Mapped[str] = mapped_column(String(20), default="synced")


class VisitEvent(Base):
    """Visits-scoped mirror of the core `events` table (same pattern as
    `mouneh_models.MounehEvent`) — every state transition and cost/sale
    write gets one of these so history is never silently lost."""

    __tablename__ = "visit_events"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    entity_type: Mapped[str] = mapped_column(String(40))
    entity_id: Mapped[str] = mapped_column(String(36))
    event_type: Mapped[str] = mapped_column(String(50))
    payload_json: Mapped[dict] = mapped_column(JSON, default=dict)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
