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

from sqlalchemy import JSON, DateTime, Float, ForeignKey, Index, Integer, String, Text, UniqueConstraint
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
