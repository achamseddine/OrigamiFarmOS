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

from sqlalchemy import Date, DateTime, Float, ForeignKey, Index, Integer, String, Text
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


class CustomerPayment(Base):
    """Money a customer paid for several sales at once — the milk collector's
    weekly payment for every collection of the week. The sales it settles
    point to it (`sales.payment_id`); when the money received differs from
    what the sales came to, the difference is its own revenue row
    (`difference_sale_id`), so revenue is what was really received."""

    __tablename__ = "customer_payments"
    __table_args__ = (Index("ix_customer_payments_farm_paid", "farm_id", "paid_at"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    customer_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("customers.id"), nullable=True)
    buyer_name: Mapped[str | None] = mapped_column(String(200), nullable=True)
    paid_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    sales_count: Mapped[int] = mapped_column(Integer, default=0)
    # In USD: what the sales came to, and what was received.
    amount_due: Mapped[float] = mapped_column(Float)
    amount_received: Mapped[float] = mapped_column(Float)
    original_amount: Mapped[float | None] = mapped_column(Float, nullable=True)
    original_currency: Mapped[str | None] = mapped_column(String(10), nullable=True)
    exchange_rate: Mapped[float | None] = mapped_column(Float, nullable=True)
    difference_sale_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    # v0.8.8 — a receipt toward one sale paid in parts (or the refund of
    # those parts when it is cancelled). Null for a payment that settles its
    # sales in full; those sales point to it instead (`sales.payment_id`).
    sale_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("sales.id"), nullable=True, index=True)
    reference: Mapped[str | None] = mapped_column(String(120), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    recorded_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


SUPPLIER_PAYMENT_KINDS = ("payment", "refund", "credit")


class SupplierPayment(Base):
    """What settles a supplier's bill (v0.8.9, audit I-9/I-14), one row each:

    * payment — money the farm paid the supplier (cash out, on its day);
    * refund — money the supplier paid back (cash in: a negative amount);
    * credit — a credit note for goods returned (no money moves).

    `amount` is the cash in USD on its day (zero for a credit); `settles` is
    what it takes off the bill, in the bill's own currency (an LBP bill paid
    in LBP is settled in LBP whatever the rate did). A row recorded by
    mistake is never edited: it is reversed by a negative row
    (`reversal_of_id`)."""

    __tablename__ = "supplier_payments"
    __table_args__ = (Index("ix_supplier_payments_farm_paid", "farm_id", "paid_at"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    expense_id: Mapped[str] = mapped_column(String(36), ForeignKey("expenses.id"), index=True)
    supplier_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("suppliers.id"), nullable=True)
    # payment | refund | credit
    kind: Mapped[str] = mapped_column(String(20), default="payment")
    paid_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    amount: Mapped[float] = mapped_column(Float, default=0)
    settles: Mapped[float] = mapped_column(Float, default=0)
    original_amount: Mapped[float | None] = mapped_column(Float, nullable=True)
    original_currency: Mapped[str | None] = mapped_column(String(10), nullable=True)
    exchange_rate: Mapped[float | None] = mapped_column(Float, nullable=True)
    # recorded | reversed (undone by a later row) | reversal (the undoing row)
    status: Mapped[str] = mapped_column(String(20), default="recorded", server_default="recorded")
    reversal_of_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    reference: Mapped[str | None] = mapped_column(String(120), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    recorded_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

