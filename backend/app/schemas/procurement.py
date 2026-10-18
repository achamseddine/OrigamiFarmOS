"""Request bodies for purchase requisitions (database/PROCUREMENT-SCHEMA.md §5–§6)."""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field


class RequisitionLineIn(BaseModel):
    inventory_item_id: str
    requested_quantity: float
    uom_code: str | None = None
    estimated_unit_price: float | None = None
    preferred_supplier_id: str | None = None
    specification: str | None = None


class RequisitionIn(BaseModel):
    """`POST /procurement/requisitions` — a manual request to buy. It is
    created as a DRAFT; submit and approve are separate steps."""

    lines: list[RequisitionLineIn] = Field(default_factory=list)
    purpose_code: str | None = None
    needed_by: datetime | None = None
    justification: str | None = None
    currency: str | None = None


class RequisitionDecision(BaseModel):
    comments: str | None = None


class RequisitionCancel(BaseModel):
    reason: str
