"""The farm's money in two currencies (v0.8.0).

The farm keeps its books in its own currency (USD). A sale or a bill may
be agreed in Lebanese pounds: it is recorded in LBP with the exchange rate
of that day and counted in USD everywhere — the original amount, currency
and rate stay on the record (`sales` / `expenses`: original_amount,
original_currency, exchange_rate).

The rate is the farm manager's to set: "1 USD = 89,500 LBP from 1 Nov".
Rates are a history, never edited: a new rate from a date is a new row,
and a record uses the rate in force on its own day unless the person
entering it gives the rate they actually used.
"""
from __future__ import annotations

import uuid
from datetime import date, datetime, timezone

from sqlalchemy import Date, DateTime, Float, ForeignKey, Index, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base

# The farm's books are in USD; LBP is the other currency money changes hands in.
BASE_CURRENCY = "USD"
CURRENCIES = ("USD", "LBP")


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


class ExchangeRate(Base):
    """How many units of `currency` make one USD, from `effective_date`."""

    __tablename__ = "exchange_rates"
    __table_args__ = (Index("ix_exchange_rates_farm_currency_date", "farm_id", "currency", "effective_date"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    currency: Mapped[str] = mapped_column(String(10))
    rate_per_usd: Mapped[float] = mapped_column(Float)
    effective_date: Mapped[date] = mapped_column(Date)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    set_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
