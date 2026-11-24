"""Selling milk, and the milk tank it is sold from (v0.7.9).

Milk recorded as *stored* goes into the farm's tank. It leaves the tank
when it is sold — a milk sale: the litres, the price per litre, the buyer,
paid or still to be paid — or when it is otherwise lost or used (spoiled,
fed to calves, taken home), recorded as a tank adjustment. A count of the
tank is an adjustment too: the difference between what the records say
and what is really there.

The tank is never a stored, editable number (CLAUDE.md: "Inventory is
ledger-driven", "No duplicate shadow inventory"): it is worked out every
time from the milk records, the sales and the adjustments.

Each sale also writes the farm's revenue record (`sales`, product_type
"milk") that Sales & Finance and the reports read; a cancelled sale is
reversed by a second, negative revenue record — history is never edited.
"""
from __future__ import annotations

import uuid
from datetime import date, datetime, timezone

from sqlalchemy import Date, DateTime, Float, ForeignKey, Index, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base

MILK_PAYMENT_STATUSES = ("paid", "pending")
MILK_SALE_STATUSES = ("recorded", "cancelled")
# Why milk left (or came back to) the tank outside a sale.
TANK_ADJUSTMENT_REASONS = ("spoiled", "calves", "home_use", "count", "other")


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


class MilkSale(Base):
    __tablename__ = "milk_sales"
    __table_args__ = (Index("ix_milk_sales_farm_sold", "farm_id", "sold_at"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    sold_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    liters: Mapped[float] = mapped_column(Float)
    price_per_liter: Mapped[float] = mapped_column(Float)
    amount: Mapped[float] = mapped_column(Float)
    currency: Mapped[str] = mapped_column(String(10), default="USD")
    customer_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("customers.id"), nullable=True)
    # The buyer as named on the sale, kept even if the customer is renamed.
    buyer_name: Mapped[str | None] = mapped_column(String(200), nullable=True)
    payment_status: Mapped[str] = mapped_column(String(20), default="pending")
    paid_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    reference: Mapped[str | None] = mapped_column(String(120), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    status: Mapped[str] = mapped_column(String(20), default="recorded")
    cancel_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    cancelled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # The revenue record this sale wrote, and the one that reversed it.
    sale_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("sales.id"), nullable=True)
    reversal_sale_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    recorded_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    # v0.8.1 — the milking it was handed over after (morning / midday /
    # evening of a farm day); null for a sale made at any other time.
    session: Mapped[str | None] = mapped_column(String(10), nullable=True)
    collection_day: Mapped[date | None] = mapped_column(Date, nullable=True)


class MilkTankAdjustment(Base):
    __tablename__ = "milk_tank_adjustments"
    __table_args__ = (Index("ix_milk_tank_adjustments_farm", "farm_id", "occurred_at"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    # Signed: milk out of the tank is negative, milk found by a count positive.
    liters: Mapped[float] = mapped_column(Float)
    reason: Mapped[str] = mapped_column(String(20))
    # For a count: the litres really in the tank.
    counted_level: Mapped[float | None] = mapped_column(Float, nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    recorded_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    # v0.8.1 — milk fed to the calves after a milking: which one.
    session: Mapped[str | None] = mapped_column(String(10), nullable=True)
    collection_day: Mapped[date | None] = mapped_column(Date, nullable=True)
