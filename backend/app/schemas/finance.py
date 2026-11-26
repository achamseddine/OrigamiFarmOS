"""Requests for Origami's financials (v0.8.0) — app/api/v1/finance.py."""
from __future__ import annotations

from datetime import date, datetime

from pydantic import BaseModel


class ExchangeRateCreate(BaseModel):
    """POST /finance/exchange-rates — 1 USD = [rate_per_usd] [currency] from [effective_date]."""

    currency: str = "LBP"
    rate_per_usd: float
    # Today when left out; never in the future.
    effective_date: date | None = None
    notes: str | None = None


class SaleCreate(BaseModel):
    """POST /finance/sales — any product sold (milk: Sell milk; Mouneh: its shop)."""

    # eggs | produce | animals | farm_products | other
    product_type: str
    product_label: str | None = None
    quantity: float | None = None
    unit: str | None = None
    # Per unit, in [currency]. Or give the [total] instead.
    unit_price: float | None = None
    total: float | None = None
    # USD (default) | LBP — LBP is converted at [exchange_rate], or at the
    # farm's rate for the sale's day when it is left out.
    currency: str = "USD"
    exchange_rate: float | None = None
    sold_at: datetime | None = None
    customer_id: str | None = None
    buyer_name: str | None = None
    # paid | pending (to be paid later)
    payment_status: str = "paid"
    reference: str | None = None
    notes: str | None = None
    # dairy | poultry | livestock | crops | mouneh | visits | general; from the product when left out.
    activity: str | None = None
    confirm_duplicate: bool = False


class ExpenseCreate(BaseModel):
    """POST /finance/expenses — an expense paid, or a bill still to pay."""

    category: str
    description: str | None = None
    amount: float
    currency: str = "USD"
    exchange_rate: float | None = None
    incurred_at: datetime | None = None
    supplier_id: str | None = None
    supplier_name: str | None = None
    # paid | pending (a bill to pay; give the due date)
    payment_status: str = "paid"
    due_date: datetime | None = None
    reference: str | None = None
    notes: str | None = None
    activity: str | None = None
    confirm_duplicate: bool = False


class MarkPaid(BaseModel):
    """POST …/paid — when it was paid (now when left out)."""

    paid_at: datetime | None = None


class CancelWithReason(BaseModel):
    reason: str = ""


class PaymentCreate(BaseModel):
    """POST /finance/payments — one payment for several sales of one buyer
    (the milk collector's weekly payment)."""

    sale_ids: list[str]
    amount_received: float
    currency: str = "USD"
    exchange_rate: float | None = None
    paid_at: datetime | None = None
    reference: str | None = None
    notes: str | None = None
    confirm_duplicate: bool = False
    # Toward one sale, the rest still owed (no difference row): the sale is
    # paid in part until its parts cover it.
    part_payment: bool = False
