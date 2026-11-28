"""Purchase requisitions and their approvals (database/PROCUREMENT-SCHEMA.md
§5–§6).

Procurement owns sourcing, requisition and approval; inventory owns stock.
An approved requisition is not a purchase and never a receipt. A
replenishment rule (pharmacy threshold, feed reorder) may open one DRAFT
requisition for a shortage; a person submits and a manager approves —
the approval authority is snapshotted at decision time so a later change
of delegation does not rewrite who could decide.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, CheckConstraint, DateTime, Float, ForeignKey, Index, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


REQUISITION_STATUSES = ("draft", "submitted", "approved", "rejected", "cancelled", "ordered", "received")
LINE_STATUSES = ("open", "approved", "rejected", "cancelled", "ordered", "received")
APPROVAL_DECISIONS = ("approved", "rejected")


class PurchaseRequisition(Base):
    __tablename__ = "purchase_requisitions"
    __table_args__ = (
        UniqueConstraint("farm_id", "requisition_no", name="uq_purchase_requisition_no"),
        Index("ix_purchase_requisitions_status", "farm_id", "status"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    requisition_no: Mapped[str] = mapped_column(String(80))
    requested_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"))
    requested_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    needed_by: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # pharmacy_replenishment | feed_replenishment | manual | maintenance
    purpose_code: Mapped[str | None] = mapped_column(String(60), nullable=True)
    status: Mapped[str] = mapped_column(String(30), default="draft")
    justification: Mapped[str | None] = mapped_column(Text, nullable=True)
    # pharmacy_stock_alert | feed_performance_alert | feed_demand_forecast
    source_type: Mapped[str | None] = mapped_column(String(60), nullable=True)
    source_reference_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    total_estimated_amount: Mapped[float | None] = mapped_column(Float, nullable=True)
    currency: Mapped[str | None] = mapped_column(String(3), nullable=True)
    submitted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    decided_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    task_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    lines: Mapped[list["PurchaseRequisitionLine"]] = relationship(back_populates="requisition", cascade="all, delete-orphan", order_by="PurchaseRequisitionLine.line_no")


class PurchaseRequisitionLine(Base):
    __tablename__ = "purchase_requisition_lines"
    __table_args__ = (UniqueConstraint("requisition_id", "line_no", name="uq_purchase_requisition_line_no"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    requisition_id: Mapped[str] = mapped_column(String(36), ForeignKey("purchase_requisitions.id"))
    line_no: Mapped[int] = mapped_column(Integer, default=1)
    inventory_item_id: Mapped[str] = mapped_column(String(36), ForeignKey("inventory_items.id"))
    requested_quantity: Mapped[float] = mapped_column(Float)
    uom_code: Mapped[str] = mapped_column(String(30), ForeignKey("units_of_measure.code"))
    estimated_unit_price: Mapped[float | None] = mapped_column(Float, nullable=True)
    preferred_supplier_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("suppliers.id"), nullable=True)
    specification: Mapped[str | None] = mapped_column(Text, nullable=True)
    status: Mapped[str] = mapped_column(String(30), default="open")
    source_recommendation_id: Mapped[str | None] = mapped_column(String(36), nullable=True)

    requisition: Mapped["PurchaseRequisition"] = relationship(back_populates="lines")


class ProcurementApproval(Base):
    __tablename__ = "procurement_approvals"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    # purchase_requisition | purchase_order
    document_type: Mapped[str] = mapped_column(String(40))
    document_id: Mapped[str] = mapped_column(String(36))
    approval_stage: Mapped[str] = mapped_column(String(60), default="manager")
    decision: Mapped[str] = mapped_column(String(30))
    decided_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"))
    decided_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    authority_snapshot: Mapped[dict] = mapped_column(JSON, default=dict)
    comments: Mapped[str | None] = mapped_column(Text, nullable=True)


# ------------------------------------------------- Package 2: ordering and receiving
# PROCUREMENT-SCHEMA §4 (supplier_item), §7 (purchase_order), §8 (goods_receipt).
# A purchase order is not stock and a receipt is not an invoice: accepted
# goods become stock through the inventory ledger (a feed lot and its
# receipt movement), and the supplier's bill is the finance record
# (purchases_service, v0.8.9). What was ordered, received, accepted, billed
# and paid is read from those records, never stored as a running balance.
PO_STATUSES = ("draft", "approved", "partially_received", "received", "closed", "cancelled")
PO_OPEN = ("approved", "partially_received")


class SupplierItem(Base):
    """A supplier's catalog entry for one inventory item, with the price it
    quotes now. Several suppliers can sell the same ingredient at different
    prices; the supplier's code never replaces the item's identity. A price
    change is an audit entry; orders keep the price they were placed at."""

    __tablename__ = "supplier_items"
    __table_args__ = (
        UniqueConstraint("supplier_id", "inventory_item_id", "supplier_item_code", name="uq_supplier_item"),
        Index("ix_supplier_items_item", "farm_id", "inventory_item_id"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    supplier_id: Mapped[str] = mapped_column(String(36), ForeignKey("suppliers.id"))
    inventory_item_id: Mapped[str] = mapped_column(String(36), ForeignKey("inventory_items.id"))
    supplier_item_code: Mapped[str] = mapped_column(String(120), default="")
    description: Mapped[str | None] = mapped_column(String(250), nullable=True)
    purchase_uom: Mapped[str] = mapped_column(String(30), ForeignKey("units_of_measure.code"))
    pack_quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    minimum_order_quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    standard_lead_time_days: Mapped[float | None] = mapped_column(Float, nullable=True)
    # The price quoted per purchase unit, in [currency].
    unit_price: Mapped[float | None] = mapped_column(Float, nullable=True)
    currency: Mapped[str] = mapped_column(String(3), default="USD")
    price_updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    status: Mapped[str] = mapped_column(String(30), default="active")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class PurchaseOrder(Base):
    __tablename__ = "purchase_orders"
    __table_args__ = (
        UniqueConstraint("farm_id", "po_no", name="uq_purchase_order_no"),
        Index("ix_purchase_orders_status", "farm_id", "status"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    supplier_id: Mapped[str] = mapped_column(String(36), ForeignKey("suppliers.id"))
    po_no: Mapped[str] = mapped_column(String(80))
    requisition_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("purchase_requisitions.id"), nullable=True)
    order_date: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    expected_delivery_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    currency: Mapped[str] = mapped_column(String(3), default="USD")
    # The rate agreed for an LBP order (USD 1 = rate LBP); the day's rate otherwise.
    exchange_rate: Mapped[float | None] = mapped_column(Float, nullable=True)
    # How the supplier is paid for each delivery: paid | credit | partial
    payment_terms: Mapped[str] = mapped_column(String(20), default="credit")
    status: Mapped[str] = mapped_column(String(30), default="draft")
    subtotal: Mapped[float] = mapped_column(Float, default=0)
    total_amount: Mapped[float] = mapped_column(Float, default=0)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"))
    approved_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    closed_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    lines: Mapped[list["PurchaseOrderLine"]] = relationship(back_populates="order", cascade="all, delete-orphan", order_by="PurchaseOrderLine.line_no")


class PurchaseOrderLine(Base):
    __tablename__ = "purchase_order_lines"
    __table_args__ = (UniqueConstraint("purchase_order_id", "line_no", name="uq_purchase_order_line_no"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    purchase_order_id: Mapped[str] = mapped_column(String(36), ForeignKey("purchase_orders.id"))
    requisition_line_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("purchase_requisition_lines.id"), nullable=True)
    line_no: Mapped[int] = mapped_column(Integer, default=1)
    inventory_item_id: Mapped[str] = mapped_column(String(36), ForeignKey("inventory_items.id"))
    # The feed product the goods are received as (feed lots and their ledger).
    feed_product_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("feed_products.id"), nullable=True)
    ordered_quantity: Mapped[float] = mapped_column(Float)
    uom_code: Mapped[str] = mapped_column(String(30), ForeignKey("units_of_measure.code"))
    # The price the order was placed at, per [uom_code], in the order's currency.
    unit_price: Mapped[float] = mapped_column(Float)
    line_total: Mapped[float] = mapped_column(Float)
    status: Mapped[str] = mapped_column(String(30), default="open")

    order: Mapped["PurchaseOrder"] = relationship(back_populates="lines")


class GoodsReceipt(Base):
    __tablename__ = "goods_receipts"
    __table_args__ = (UniqueConstraint("farm_id", "receipt_no", name="uq_goods_receipt_no"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    supplier_id: Mapped[str] = mapped_column(String(36), ForeignKey("suppliers.id"))
    purchase_order_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("purchase_orders.id"), nullable=True, index=True)
    receipt_no: Mapped[str] = mapped_column(String(80))
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    received_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    delivery_note_no: Mapped[str | None] = mapped_column(String(120), nullable=True)
    status: Mapped[str] = mapped_column(String(30), default="posted")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    lines: Mapped[list["GoodsReceiptLine"]] = relationship(back_populates="receipt", cascade="all, delete-orphan", order_by="GoodsReceiptLine.line_no")


class GoodsReceiptLine(Base):
    __tablename__ = "goods_receipt_lines"
    __table_args__ = (
        UniqueConstraint("goods_receipt_id", "line_no", name="uq_goods_receipt_line_no"),
        CheckConstraint("received_quantity >= 0 AND accepted_quantity >= 0 AND rejected_quantity >= 0 "
                        "AND accepted_quantity + rejected_quantity <= received_quantity + 0.000001", name="ck_goods_receipt_line_quantities"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    goods_receipt_id: Mapped[str] = mapped_column(String(36), ForeignKey("goods_receipts.id"))
    purchase_order_line_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("purchase_order_lines.id"), nullable=True, index=True)
    line_no: Mapped[int] = mapped_column(Integer, default=1)
    inventory_item_id: Mapped[str] = mapped_column(String(36), ForeignKey("inventory_items.id"))
    received_quantity: Mapped[float] = mapped_column(Float)
    accepted_quantity: Mapped[float] = mapped_column(Float)
    rejected_quantity: Mapped[float] = mapped_column(Float, default=0)
    uom_code: Mapped[str] = mapped_column(String(30), ForeignKey("units_of_measure.code"))
    # The lot the accepted goods became (its receipt movement is the ledger's).
    feed_lot_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("feed_lots.id"), nullable=True)
    # The supplier's bill for it (expenses, purchases_service).
    expense_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("expenses.id"), nullable=True)
    quality_grade: Mapped[str | None] = mapped_column(String(20), nullable=True)
    rejection_reason: Mapped[str | None] = mapped_column(String(200), nullable=True)

    receipt: Mapped["GoodsReceipt"] = relationship(back_populates="lines")
