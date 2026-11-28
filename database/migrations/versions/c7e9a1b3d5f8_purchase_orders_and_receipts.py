"""Ordering and receiving (master prompt Package 2; PROCUREMENT-SCHEMA §4,
§7, §8).

Revision ID: c7e9a1b3d5f8
Revises: b5d7f9a1c3e6
Create Date: 2026-11-26

Schema
- supplier_items: a supplier's catalog entry and quoted price for one
  inventory item — several suppliers can sell the same ingredient at
  different prices; unique (supplier_id, inventory_item_id,
  supplier_item_code).
- purchase_orders / purchase_order_lines: what was ordered from whom, at
  which price, from which requisition; po_no unique per farm. A line keeps
  the price and unit it was ordered in.
- goods_receipts / goods_receipt_lines: each delivery against an order —
  received, accepted and rejected (accepted + rejected never more than
  received), the feed lot the accepted goods became and the supplier's
  bill for it. receipt_no unique per farm.

Data: none is rewritten. Deliveries recorded before have no order and keep
their lots and bills. Downgrade drops the five tables.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "c7e9a1b3d5f8"
down_revision = "b5d7f9a1c3e6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "supplier_items",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("supplier_id", sa.String(36), sa.ForeignKey("suppliers.id"), nullable=False),
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("inventory_items.id"), nullable=False),
        sa.Column("supplier_item_code", sa.String(120), nullable=False),
        sa.Column("description", sa.String(250), nullable=True),
        sa.Column("purchase_uom", sa.String(30), sa.ForeignKey("units_of_measure.code"), nullable=False),
        sa.Column("pack_quantity", sa.Float(), nullable=True),
        sa.Column("minimum_order_quantity", sa.Float(), nullable=True),
        sa.Column("standard_lead_time_days", sa.Float(), nullable=True),
        sa.Column("unit_price", sa.Float(), nullable=True),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("price_updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("status", sa.String(30), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("supplier_id", "inventory_item_id", "supplier_item_code", name="uq_supplier_item"),
    )
    op.create_index("ix_supplier_items_item", "supplier_items", ["farm_id", "inventory_item_id"])

    op.create_table(
        "purchase_orders",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("supplier_id", sa.String(36), sa.ForeignKey("suppliers.id"), nullable=False),
        sa.Column("po_no", sa.String(80), nullable=False),
        sa.Column("requisition_id", sa.String(36), sa.ForeignKey("purchase_requisitions.id"), nullable=True),
        sa.Column("order_date", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expected_delivery_date", sa.DateTime(timezone=True), nullable=True),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("exchange_rate", sa.Float(), nullable=True),
        sa.Column("payment_terms", sa.String(20), nullable=False),
        sa.Column("status", sa.String(30), nullable=False),
        sa.Column("subtotal", sa.Float(), nullable=False),
        sa.Column("total_amount", sa.Float(), nullable=False),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_by", sa.String(36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("approved_by", sa.String(36), nullable=True),
        sa.Column("approved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("closed_reason", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("farm_id", "po_no", name="uq_purchase_order_no"),
    )
    op.create_index("ix_purchase_orders_status", "purchase_orders", ["farm_id", "status"])

    op.create_table(
        "purchase_order_lines",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("purchase_order_id", sa.String(36), sa.ForeignKey("purchase_orders.id"), nullable=False),
        sa.Column("requisition_line_id", sa.String(36), sa.ForeignKey("purchase_requisition_lines.id"), nullable=True),
        sa.Column("line_no", sa.Integer(), nullable=False),
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("inventory_items.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=True),
        sa.Column("ordered_quantity", sa.Float(), nullable=False),
        sa.Column("uom_code", sa.String(30), sa.ForeignKey("units_of_measure.code"), nullable=False),
        sa.Column("unit_price", sa.Float(), nullable=False),
        sa.Column("line_total", sa.Float(), nullable=False),
        sa.Column("status", sa.String(30), nullable=False),
        sa.UniqueConstraint("purchase_order_id", "line_no", name="uq_purchase_order_line_no"),
    )

    op.create_table(
        "goods_receipts",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("supplier_id", sa.String(36), sa.ForeignKey("suppliers.id"), nullable=False),
        sa.Column("purchase_order_id", sa.String(36), sa.ForeignKey("purchase_orders.id"), nullable=True),
        sa.Column("receipt_no", sa.String(80), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("received_by", sa.String(36), nullable=True),
        sa.Column("delivery_note_no", sa.String(120), nullable=True),
        sa.Column("status", sa.String(30), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("farm_id", "receipt_no", name="uq_goods_receipt_no"),
    )
    op.create_index("ix_goods_receipts_purchase_order_id", "goods_receipts", ["purchase_order_id"])

    op.create_table(
        "goods_receipt_lines",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("goods_receipt_id", sa.String(36), sa.ForeignKey("goods_receipts.id"), nullable=False),
        sa.Column("purchase_order_line_id", sa.String(36), sa.ForeignKey("purchase_order_lines.id"), nullable=True),
        sa.Column("line_no", sa.Integer(), nullable=False),
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("inventory_items.id"), nullable=False),
        sa.Column("received_quantity", sa.Float(), nullable=False),
        sa.Column("accepted_quantity", sa.Float(), nullable=False),
        sa.Column("rejected_quantity", sa.Float(), nullable=False),
        sa.Column("uom_code", sa.String(30), sa.ForeignKey("units_of_measure.code"), nullable=False),
        sa.Column("feed_lot_id", sa.String(36), sa.ForeignKey("feed_lots.id"), nullable=True),
        sa.Column("expense_id", sa.String(36), sa.ForeignKey("expenses.id"), nullable=True),
        sa.Column("quality_grade", sa.String(20), nullable=True),
        sa.Column("rejection_reason", sa.String(200), nullable=True),
        sa.UniqueConstraint("goods_receipt_id", "line_no", name="uq_goods_receipt_line_no"),
        sa.CheckConstraint("received_quantity >= 0 AND accepted_quantity >= 0 AND rejected_quantity >= 0 "
                           "AND accepted_quantity + rejected_quantity <= received_quantity + 0.000001", name="ck_goods_receipt_line_quantities"),
    )
    op.create_index("ix_goods_receipt_lines_purchase_order_line_id", "goods_receipt_lines", ["purchase_order_line_id"])


def downgrade() -> None:
    op.drop_index("ix_goods_receipt_lines_purchase_order_line_id", table_name="goods_receipt_lines")
    op.drop_table("goods_receipt_lines")
    op.drop_index("ix_goods_receipts_purchase_order_id", table_name="goods_receipts")
    op.drop_table("goods_receipts")
    op.drop_table("purchase_order_lines")
    op.drop_index("ix_purchase_orders_status", table_name="purchase_orders")
    op.drop_table("purchase_orders")
    op.drop_index("ix_supplier_items_item", table_name="supplier_items")
    op.drop_table("supplier_items")
