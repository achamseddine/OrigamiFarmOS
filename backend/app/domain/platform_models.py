"""Platform masters the domain modules share (FOUNDATION-SCHEMA.md,
ASSET-MAINTENANCE-SCHEMA.md §2, MEDICINE-NOTIFICATION-RULES.md
§Notification behavior, FEED-PERFORMANCE-INTELLIGENCE.md §12).

* `units_of_measure` — the UOM table the schema documents reference. A
  unit is a row with a dimension and a factor to the dimension's base
  unit; the conversion engine in `app/feeding/uom.py` resolves against
  this catalogue, so a medicine's strength, a lot's unit and a protocol's
  dose unit are references, not free text. Natural-key codes, as every
  other reference table in this codebase (species, life stages).
* `farm_assets` — durable resources: a mixer wagon, a cooling tank, a
  milking machine. A numbered mix names the asset it was mixed on.
* `notification_routes` — who a farm wants told about what: a route code
  (pharmacy stock, emergency escalation, …) to a role or a person. The
  domain alert stays authoritative; routing only decides the recipients.
* `scheduled_job_runs` — the run log of the background cycles (feed
  performance, pharmacy scan, emergency reassessment check), so a manager
  can see when the farm was last evaluated and why a run failed.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, Boolean, DateTime, Float, ForeignKey, Index, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


UOM_DIMENSIONS = ("mass", "volume", "count", "concentration", "dose_rate", "energy", "time", "length", "area", "other")
ASSET_TYPES = ("mixer", "tractor", "pump", "generator", "milking_machine", "cooling_tank", "incubator", "sprayer", "vehicle", "building", "other")
ASSET_STATUSES = ("active", "out_of_service", "retired")
ROUTE_CODES = (
    "pharmacy_stock", "pharmacy_critical", "pharmacy_expiry", "emergency_escalation", "emergency_manager", "emergency_veterinarian",
    "emergency_reassessment", "feed_performance", "procurement_requisition",
)
JOB_CODES = ("feed_performance_cycle", "pharmacy_scan", "emergency_reassessment_check")


class UnitOfMeasure(Base):
    __tablename__ = "units_of_measure"

    code: Mapped[str] = mapped_column(String(30), primary_key=True)
    name_en: Mapped[str] = mapped_column(String(80))
    name_ar: Mapped[str | None] = mapped_column(String(80), nullable=True)
    dimension: Mapped[str] = mapped_column(String(30), default="other")
    # The unit quantities in this dimension convert through; null for the
    # base unit itself and for dimensions with no conversions.
    base_unit_code: Mapped[str | None] = mapped_column(String(30), ForeignKey("units_of_measure.code"), nullable=True)
    factor_to_base: Mapped[float] = mapped_column(Float, default=1.0)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    sort_order: Mapped[int] = mapped_column(Integer, default=100)


class FarmAsset(Base):
    __tablename__ = "farm_assets"
    __table_args__ = (UniqueConstraint("farm_id", "code", name="uq_farm_asset_code"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    code: Mapped[str] = mapped_column(String(80))
    name: Mapped[str] = mapped_column(String(180))
    asset_type: Mapped[str] = mapped_column(String(60), default="other")
    manufacturer: Mapped[str | None] = mapped_column(String(120), nullable=True)
    model: Mapped[str | None] = mapped_column(String(120), nullable=True)
    serial_number: Mapped[str | None] = mapped_column(String(150), nullable=True)
    acquisition_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    acquisition_cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    currency: Mapped[str | None] = mapped_column(String(3), nullable=True)
    current_location_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("locations.id"), nullable=True)
    status: Mapped[str] = mapped_column(String(30), default="active")
    parent_asset_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("farm_assets.id"), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class NotificationRoute(Base):
    """One recipient rule: this farm wants `route_code` to reach this role
    or this person. No rows for a route means the built-in default
    (managers and owners; veterinarians for the clinical routes)."""

    __tablename__ = "notification_routes"
    __table_args__ = (Index("ix_notification_routes_farm_route", "farm_id", "route_code"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    route_code: Mapped[str] = mapped_column(String(60))
    role: Mapped[str | None] = mapped_column(String(30), nullable=True)
    user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)
    # in_app today; push / email / sms belong to the notification subsystem
    channel: Mapped[str] = mapped_column(String(20), default="in_app")
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class ScheduledJobRun(Base):
    __tablename__ = "scheduled_job_runs"
    __table_args__ = (Index("ix_scheduled_job_runs_job", "farm_id", "job_code", "started_at"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("farms.id"), nullable=True)
    job_code: Mapped[str] = mapped_column(String(60))
    # scheduler | manual | startup
    trigger: Mapped[str] = mapped_column(String(20), default="scheduler")
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # running | succeeded | failed
    status: Mapped[str] = mapped_column(String(20), default="running")
    summary_json: Mapped[dict] = mapped_column(JSON, default=dict)
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
