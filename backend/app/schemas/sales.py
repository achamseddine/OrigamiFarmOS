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
