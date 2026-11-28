"""Request bodies for purchase requisitions (database/PROCUREMENT-SCHEMA.md §5–§6)."""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field


class RequisitionLineIn(BaseModel):
    # The item to buy: an inventory item, or a feed (its inventory item).
    inventory_item_id: str | None = None
    feed_product_id: str | None = None
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
    # Send it to the manager now (an employee asking to buy feed) rather
    # than keeping a draft to submit later.
    submit: bool = False


class RequisitionDecision(BaseModel):
    comments: str | None = None


class RequisitionCancel(BaseModel):
    reason: str


# --------------------------------------------- Package 2: quotes, orders, receipts
class SupplierQuoteIn(BaseModel):
    """`POST /procurement/supplier-items` — the price a supplier quotes for
    an item (PROCUREMENT-SCHEMA §4). The same item from another supplier is
    another quote; a new price replaces this supplier's (kept in the audit)."""

    supplier_id: str | None = None
    supplier_name: str | None = None
    inventory_item_id: str | None = None
    feed_product_id: str | None = None
    unit_price: float | None = Field(None, ge=0)
    currency: str = "USD"
    purchase_uom: str | None = None
    supplier_item_code: str | None = None
    description: str | None = None
    minimum_order_quantity: float | None = Field(None, gt=0)
    standard_lead_time_days: float | None = Field(None, ge=0)


class PurchaseOrderLineIn(BaseModel):
    feed_product_id: str | None = None
    inventory_item_id: str | None = None
    quantity: float = Field(gt=0)
    unit: str | None = None
    # Per [unit], in the order's currency; the supplier's quote when left out.
    unit_price: float | None = Field(None, ge=0)


class PurchaseOrderIn(BaseModel):
    """`POST /procurement/purchase-orders` — a draft order to one supplier
    (§7): direct, or from an approved requisition (`requisition_id`)."""

    supplier_id: str | None = None
    # A supplier named for the first time is added to the farm's suppliers.
    supplier_name: str | None = None
    lines: list[PurchaseOrderLineIn] = Field(default_factory=list)
    requisition_id: str | None = None
    expected_delivery_date: datetime | None = None
    currency: str = "USD"
    exchange_rate: float | None = Field(None, gt=0)
    # Each delivery's bill: paid on delivery, or on credit (paid later, in parts).
    payment_terms: str = "credit"
    notes: str | None = None
    # Approve it at once (the manager placing their own order).
    approve: bool = False


class PurchaseOrderDecision(BaseModel):
    comments: str | None = None


class PurchaseOrderClose(BaseModel):
    reason: str = Field(min_length=1, max_length=500)


class GoodsReceiptLineIn(BaseModel):
    purchase_order_line_id: str
    received_quantity: float = Field(ge=0)
    rejected_quantity: float = Field(0, ge=0)
    rejection_reason: str | None = None
    quality_grade: str | None = None
    quality_notes: str | None = None
    lot_code: str | None = None


class GoodsReceiptIn(BaseModel):
    """`POST /procurement/purchase-orders/{id}/receive` — a delivery against
    an approved order (§8), partial or whole."""

    lines: list[GoodsReceiptLineIn] = Field(default_factory=list)
    received_at: datetime | None = None
    delivery_note_no: str | None = None
    # paid on delivery | credit (the order's terms when left out)
    payment: str | None = None
    invoice_reference: str | None = None
