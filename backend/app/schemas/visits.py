"""Farm Visits & Agri-Tourism — request/response schemas (tech spec v0.6
§4 "Data Model" + §6 "API Endpoints")."""
from __future__ import annotations

from datetime import date, datetime, time

from pydantic import BaseModel, field_validator

from app.schemas.common import ORMModel

SESSION_STATUSES = {"open", "full", "closed", "cancelled", "completed"}
BOOKING_STATUSES = {"draft", "confirmed", "checked_in", "completed", "cancelled", "no_show", "refunded"}
BOOKING_SOURCES = {"manual", "whatsapp", "website", "phone", "walk_in"}
ACTIVITY_TYPES = {"tour", "ride", "workshop", "tasting", "event", "other"}
BOOKING_ACTIVITY_STATUSES = {"scheduled", "completed", "cancelled", "missed"}
COST_CATEGORIES = {"staff", "cleaning", "utilities", "tasting", "marketing", "safety", "maintenance", "other"}
COST_ALLOCATION_METHODS = {"per_session", "per_guest", "per_package", "per_activity"}
RETAIL_CHANNELS = {"farm_shop", "tasting_upgrade", "delivery_after_visit"}
INCIDENT_TYPES = {"safety", "animal", "weather", "payment", "complaint", "other"}
INCIDENT_SEVERITIES = {"low", "medium", "high"}


# ---------------------------------------------------------------------------
# Opening calendar (REQ-VIS: configurable, never hard-coded weekends)
# ---------------------------------------------------------------------------
class OpeningCalendarDayUpsert(BaseModel):
    weekday: int
    is_open: bool = False
    open_time: time | None = None
    close_time: time | None = None
    default_capacity: int = 0
    notes: str | None = None

    @field_validator("weekday")
    @classmethod
    def weekday_range(cls, v: int) -> int:
        if not (0 <= v <= 6):
            raise ValueError("weekday must be between 0 (Monday) and 6 (Sunday)")
        return v

    @field_validator("default_capacity")
    @classmethod
    def capacity_non_negative(cls, v: int) -> int:
        if v < 0:
            raise ValueError("default_capacity cannot be negative")
        return v


class OpeningCalendarDayOut(ORMModel):
    id: str
    weekday: int
    is_open: bool
    open_time: time | None = None
    close_time: time | None = None
    default_capacity: int
    notes: str | None = None


# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------
class VisitSessionCreate(BaseModel):
    date: date
    start_time: time
    end_time: time
    capacity: int
    weather_note: str | None = None
    expected_staff_cost: float | None = None

    @field_validator("capacity")
    @classmethod
    def capacity_positive(cls, v: int) -> int:
        if v <= 0:
            raise ValueError("capacity must be greater than zero")
        return v


class VisitSessionUpdate(BaseModel):
    capacity: int | None = None
    status: str | None = None
    weather_note: str | None = None
    expected_staff_cost: float | None = None

    @field_validator("status")
    @classmethod
    def status_valid(cls, v: str | None) -> str | None:
        if v is not None and v not in SESSION_STATUSES:
            raise ValueError(f"status must be one of {sorted(SESSION_STATUSES)}")
        return v


class VisitSessionOut(ORMModel):
    id: str
    farm_id: str
    date: date
    start_time: time
    end_time: time
    capacity: int
    status: str
    weather_note: str | None = None
    expected_staff_cost: float | None = None


# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
class VisitPackageCreate(BaseModel):
    name: str
    description: str | None = None
    base_price: float = 0
    currency: str = "USD"
    duration_minutes: int | None = None
    included_items_json: dict = {}
    active: bool = True

    @field_validator("name")
    @classmethod
    def name_non_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("name cannot be empty")
        return v.strip()

    @field_validator("base_price")
    @classmethod
    def base_price_non_negative(cls, v: float) -> float:
        if v < 0:
            raise ValueError("base_price cannot be negative")
        return v


class VisitPackageOut(ORMModel):
    id: str
    farm_id: str
    name: str
    description: str | None = None
    base_price: float
    currency: str
    duration_minutes: int | None = None
    included_items_json: dict
    active: bool


# ---------------------------------------------------------------------------
# Activities
# ---------------------------------------------------------------------------
class VisitActivityCreate(BaseModel):
    name: str
    activity_type: str = "other"
    price: float = 0
    capacity_per_slot: int = 1
    duration_minutes: int | None = None
    requires_staff_role: str | None = None
    requires_animal_id: str | None = None
    welfare_limit_json: dict | None = None
    active: bool = True

    @field_validator("name")
    @classmethod
    def name_non_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("name cannot be empty")
        return v.strip()

    @field_validator("activity_type")
    @classmethod
    def activity_type_valid(cls, v: str) -> str:
        if v not in ACTIVITY_TYPES:
            raise ValueError(f"activity_type must be one of {sorted(ACTIVITY_TYPES)}")
        return v

    @field_validator("capacity_per_slot")
    @classmethod
    def capacity_positive(cls, v: int) -> int:
        if v <= 0:
            raise ValueError("capacity_per_slot must be greater than zero")
        return v


class VisitActivityOut(ORMModel):
    id: str
    farm_id: str
    name: str
    activity_type: str
    price: float
    capacity_per_slot: int
    duration_minutes: int | None = None
    requires_staff_role: str | None = None
    requires_animal_id: str | None = None
    welfare_limit_json: dict | None = None
    active: bool


# ---------------------------------------------------------------------------
# Visitors
# ---------------------------------------------------------------------------
class VisitorProfileCreate(BaseModel):
    full_name: str
    phone: str | None = None
    email: str | None = None
    preferred_language: str = "en"
    notes: str | None = None
    consent_marketing: bool = False

    @field_validator("full_name")
    @classmethod
    def full_name_non_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("full_name cannot be empty")
        return v.strip()


class VisitorProfileOut(ORMModel):
    id: str
    farm_id: str
    full_name: str
    phone: str | None = None
    email: str | None = None
    preferred_language: str
    notes: str | None = None
    consent_marketing: bool


# ---------------------------------------------------------------------------
# Bookings
# ---------------------------------------------------------------------------
class BookingActivitySelection(BaseModel):
    activity_id: str
    scheduled_at: datetime
    quantity: int = 1

    @field_validator("quantity")
    @classmethod
    def quantity_positive(cls, v: int) -> int:
        if v <= 0:
            raise ValueError("quantity must be greater than zero")
        return v


class VisitBookingCreate(BaseModel):
    visitor_id: str | None = None
    visitor: VisitorProfileCreate | None = None  # create-on-the-fly for walk-ins
    session_id: str
    package_id: str
    adults: int = 1
    children: int = 0
    activities: list[BookingActivitySelection] = []
    deposit_amount: float = 0
    source: str = "manual"
    payment_method: str | None = None
    notes: str | None = None
    idempotency_key: str | None = None

    @field_validator("adults", "children")
    @classmethod
    def guests_non_negative(cls, v: int) -> int:
        if v < 0:
            raise ValueError("guest counts cannot be negative")
        return v

    @field_validator("source")
    @classmethod
    def source_valid(cls, v: str) -> str:
        if v not in BOOKING_SOURCES:
            raise ValueError(f"source must be one of {sorted(BOOKING_SOURCES)}")
        return v


class VisitBookingCancelRequest(BaseModel):
    reason: str | None = None
    refund: bool = False


class BookingActivityOut(ORMModel):
    id: str
    activity_id: str
    scheduled_at: datetime
    quantity: int
    unit_price: float
    status: str


class VisitBookingOut(ORMModel):
    id: str
    farm_id: str
    visitor_id: str
    session_id: str
    package_id: str
    status: str
    adults: int
    children: int
    total_amount: float
    deposit_amount: float
    balance_due: float
    source: str
    payment_method: str | None = None
    notes: str | None = None
    confirmed_at: datetime | None = None
    checked_in_at: datetime | None = None
    completed_at: datetime | None = None
    cancelled_at: datetime | None = None
    activities: list[BookingActivityOut] = []


# ---------------------------------------------------------------------------
# Staff roster + costs
# ---------------------------------------------------------------------------
class VisitStaffRosterCreate(BaseModel):
    session_id: str
    worker_id: str
    role: str
    start_time: time
    end_time: time
    hourly_rate: float = 0

    @field_validator("hourly_rate")
    @classmethod
    def hourly_rate_non_negative(cls, v: float) -> float:
        if v < 0:
            raise ValueError("hourly_rate cannot be negative")
        return v


class VisitStaffRosterOut(ORMModel):
    id: str
    session_id: str
    worker_id: str
    role: str
    start_time: time
    end_time: time
    hourly_rate: float
    total_cost: float | None = None


class VisitCostCreate(BaseModel):
    session_id: str
    category: str
    description: str | None = None
    amount: float
    allocation_method: str = "per_session"

    @field_validator("category")
    @classmethod
    def category_valid(cls, v: str) -> str:
        if v not in COST_CATEGORIES:
            raise ValueError(f"category must be one of {sorted(COST_CATEGORIES)}")
        return v

    @field_validator("allocation_method")
    @classmethod
    def allocation_method_valid(cls, v: str) -> str:
        if v not in COST_ALLOCATION_METHODS:
            raise ValueError(f"allocation_method must be one of {sorted(COST_ALLOCATION_METHODS)}")
        return v

    @field_validator("amount")
    @classmethod
    def amount_non_negative(cls, v: float) -> float:
        if v < 0:
            raise ValueError("amount cannot be negative")
        return v


class VisitCostOut(ORMModel):
    id: str
    session_id: str
    category: str
    description: str | None = None
    amount: float
    allocation_method: str


# ---------------------------------------------------------------------------
# Retail / POS
# ---------------------------------------------------------------------------
class RetailSaleLine(BaseModel):
    """Either a plain inventory item (eggs, milk, produce) or a Mouneh
    finished-goods line — never both."""

    inventory_item_id: str | None = None
    finished_goods_stock_id: str | None = None
    quantity: float
    unit_price: float

    @field_validator("quantity", "unit_price")
    @classmethod
    def positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("value must be greater than zero")
        return v


class VisitRetailSaleCreate(BaseModel):
    booking_id: str | None = None
    visitor_id: str | None = None
    channel: str = "farm_shop"
    payment_status: str = "paid"
    lines: list[RetailSaleLine]

    @field_validator("channel")
    @classmethod
    def channel_valid(cls, v: str) -> str:
        if v not in RETAIL_CHANNELS:
            raise ValueError(f"channel must be one of {sorted(RETAIL_CHANNELS)}")
        return v

    @field_validator("lines")
    @classmethod
    def lines_non_empty(cls, v: list[RetailSaleLine]) -> list[RetailSaleLine]:
        if not v:
            raise ValueError("a retail sale needs at least one line item")
        return v


class VisitRetailSaleOut(ORMModel):
    id: str
    booking_id: str | None = None
    visitor_id: str | None = None
    sale_id: str
    channel: str
    total_amount: float


# ---------------------------------------------------------------------------
# Feedback + incidents
# ---------------------------------------------------------------------------
class VisitorFeedbackCreate(BaseModel):
    booking_id: str
    rating: int
    comments: str | None = None
    would_return: bool | None = None

    @field_validator("rating")
    @classmethod
    def rating_range(cls, v: int) -> int:
        if not (1 <= v <= 5):
            raise ValueError("rating must be between 1 and 5")
        return v


class VisitorFeedbackOut(ORMModel):
    id: str
    booking_id: str
    rating: int
    comments: str | None = None
    would_return: bool | None = None
    submitted_at: datetime


class VisitIncidentCreate(BaseModel):
    session_id: str
    booking_id: str | None = None
    incident_type: str
    severity: str = "low"
    description: str
    action_taken: str | None = None

    @field_validator("incident_type")
    @classmethod
    def incident_type_valid(cls, v: str) -> str:
        if v not in INCIDENT_TYPES:
            raise ValueError(f"incident_type must be one of {sorted(INCIDENT_TYPES)}")
        return v

    @field_validator("severity")
    @classmethod
    def severity_valid(cls, v: str) -> str:
        if v not in INCIDENT_SEVERITIES:
            raise ValueError(f"severity must be one of {sorted(INCIDENT_SEVERITIES)}")
        return v


class VisitIncidentOut(ORMModel):
    id: str
    session_id: str
    booking_id: str | None = None
    incident_type: str
    severity: str
    description: str
    action_taken: str | None = None
    created_at: datetime


# ---------------------------------------------------------------------------
# Dashboards / reports
# ---------------------------------------------------------------------------
class VisitProfitabilityOut(BaseModel):
    scope: str  # e.g. "session:<id>" or "range:2026-08-01..2026-08-31"
    package_revenue: float
    activity_revenue: float
    retail_revenue: float
    visitor_revenue: float
    staff_cost: float
    activity_cost: float
    included_product_cost: float
    cleaning_utilities_cost: float
    other_cost: float
    direct_visit_cost: float
    gross_margin: float
    checked_in_visitors: int
    revenue_per_visitor: float
    retail_conversion_pct: float
    average_basket_value: float
    by_package: list[dict]
    by_activity: list[dict]


class VisitDashboardOut(BaseModel):
    module_status: str
    upcoming_sessions: int
    today_bookings: int
    today_expected_visitors: int
    today_expected_revenue: float
    open_incidents: int
    sessions: list[VisitSessionOut]
