from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, field_validator

from app.schemas.common import ORMModel


class FeedTransactionCreate(BaseModel):
    """POST /feed/transactions.

    Validation rule (tech spec §14): "Inventory should not go negative
    without explicit override."
    """

    item_id: str
    direction: str  # 'in' | 'out'
    quantity: float
    unit: str | None = None
    reason: str | None = None
    linked_entity_type: str | None = None
    linked_entity_id: str | None = None
    allow_negative: bool = False

    @field_validator("direction")
    @classmethod
    def direction_valid(cls, v: str) -> str:
        if v not in {"in", "out"}:
            raise ValueError("direction must be 'in' or 'out'")
        return v

    @field_validator("quantity")
    @classmethod
    def quantity_positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("quantity must be greater than zero")
        return v


class InventoryItemOut(ORMModel):
    id: str
    farm_id: str
    name: str
    category: str | None = None
    unit: str
    current_qty: float
    reorder_level: float
    supplier_label: str | None = None
    unit_cost: float | None = None
    last_purchase: datetime | None = None

    @property
    def is_low_stock(self) -> bool:
        return self.current_qty <= self.reorder_level
