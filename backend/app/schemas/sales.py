from __future__ import annotations

from datetime import datetime

from app.schemas.common import ORMModel


class CustomerOut(ORMModel):
    id: str
    farm_id: str
    name: str
    phone: str | None = None


class SupplierOut(ORMModel):
    id: str
    farm_id: str
    name: str
    phone: str | None = None


class SaleOut(ORMModel):
    id: str
    farm_id: str
    customer_id: str | None = None
    product_type: str
    product_label: str | None = None
    quantity: float | None = None
    unit: str | None = None
    amount: float
    currency: str
    payment_status: str
    sold_at: datetime
    # v0.8.0
    status: str = "recorded"
    unit_price: float | None = None
    buyer_name: str | None = None
    reference: str | None = None
    paid_at: datetime | None = None
    original_amount: float | None = None
    original_currency: str | None = None
    exchange_rate: float | None = None
    activity: str | None = None


class ExpenseOut(ORMModel):
    id: str
    farm_id: str
    supplier_id: str | None = None
    category: str
    amount: float
    currency: str
    linked_entity_type: str | None = None
    linked_entity_id: str | None = None
    incurred_at: datetime
    # v0.8.0
    description: str | None = None
    supplier_label: str | None = None
    payment_status: str = "paid"
    due_date: datetime | None = None
    paid_at: datetime | None = None
    status: str = "recorded"
    reference: str | None = None
    original_amount: float | None = None
    original_currency: str | None = None
    exchange_rate: float | None = None
    activity: str | None = None
