"""Purchase requisitions (database/PROCUREMENT-SCHEMA.md §5–§6).

Anyone with inventory view reads; inventory create opens and submits a
draft; approval and rejection need a manager, the owner, or inventory
approve — the service snapshots the authority on the decision. Nothing
here orders or receives stock.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_any_permission, require_permission
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.domain import procurement_models as prm
from app.schemas.procurement import (GoodsReceiptIn, PurchaseOrderClose, PurchaseOrderDecision, PurchaseOrderIn, RequisitionCancel, RequisitionDecision,
                                    RequisitionIn, SupplierQuoteIn)
from app.services import procurement_service as procurement
from app.services import purchase_orders_service as orders

router = APIRouter(prefix="/procurement", tags=["procurement"])

# Feed staff ask to buy feed from the Feed module (v0.7.8): Feed &
# Nutrition counts as well as Inventory for reading and asking.
_view = require_any_permission(perms.INVENTORY, perms.FEED_NUTRITION, action=perms.VIEW)
_create = require_any_permission(perms.INVENTORY, perms.FEED_NUTRITION, action=perms.CREATE)
_edit = require_permission(perms.INVENTORY, perms.EDIT)


@router.get("/requisitions")
def list_requisitions(req_status: str | None = Query(None, alias="status"), inventory_item_id: str | None = None, limit: int = Query(100, ge=1, le=500),
                      db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    stmt = select(prm.PurchaseRequisition).where(prm.PurchaseRequisition.farm_id == user.farm_id)
    if req_status == "open":
        stmt = stmt.where(prm.PurchaseRequisition.status.in_(("draft", "submitted", "approved", "ordered")))
    elif req_status:
        stmt = stmt.where(prm.PurchaseRequisition.status == req_status)
    rows = list(db.scalars(stmt.order_by(prm.PurchaseRequisition.requested_at.desc()).limit(limit)))
    if inventory_item_id:
        rows = [r for r in rows if any(l.inventory_item_id == inventory_item_id for l in r.lines)]
    return [procurement.requisition_dict(db, r) for r in rows]


@router.post("/requisitions", status_code=status.HTTP_201_CREATED)
def create_requisition(payload: RequisitionIn, db: Session = Depends(get_db), user: models.User = Depends(_create)) -> dict:
    """A manual DRAFT requisition. Submitting and approving are separate
    steps; an approved requisition is not a purchase."""
    lines = [procurement.resolve_line(db, user.farm_id, l.model_dump()) for l in payload.lines]
    req = procurement.create_requisition(db, user.farm_id, lines=lines, requested_by=user.id, purpose_code=payload.purpose_code or "manual",
                                         needed_by=payload.needed_by, justification=payload.justification, source_type="manual", currency=payload.currency, user_id=user.id)
    if payload.submit:
        procurement.submit(db, req, user_id=user.id)
        procurement.notify_submitted(db, req, user)
    db.commit()
    return procurement.requisition_dict(db, req)


@router.get("/requisitions/{requisition_id}")
def get_requisition(requisition_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return procurement.requisition_dict(db, procurement.get_requisition(db, requisition_id, user.farm_id))


@router.post("/requisitions/{requisition_id}/submit")
def submit_requisition(requisition_id: str, db: Session = Depends(get_db), user: models.User = Depends(_create)) -> dict:
    req = procurement.submit(db, procurement.get_requisition(db, requisition_id, user.farm_id), user_id=user.id)
    procurement.notify_submitted(db, req, user)
    db.commit()
    return procurement.requisition_dict(db, req)


@router.post("/requisitions/{requisition_id}/approve")
def approve_requisition(requisition_id: str, payload: RequisitionDecision | None = None, db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> dict:
    """Approval with the deciding authority snapshotted (§6). Refused for
    anyone without it."""
    req = procurement.decide(db, procurement.get_requisition(db, requisition_id, user.farm_id), decision="approved", user=user, comments=payload.comments if payload else None)
    db.commit()
    return procurement.requisition_dict(db, req)


@router.post("/requisitions/{requisition_id}/reject")
def reject_requisition(requisition_id: str, payload: RequisitionDecision, db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> dict:
    req = procurement.decide(db, procurement.get_requisition(db, requisition_id, user.farm_id), decision="rejected", user=user, comments=payload.comments)
    db.commit()
    return procurement.requisition_dict(db, req)


@router.post("/requisitions/{requisition_id}/cancel")
def cancel_requisition(requisition_id: str, payload: RequisitionCancel, db: Session = Depends(get_db), user: models.User = Depends(_edit)) -> dict:
    req = procurement.cancel(db, procurement.get_requisition(db, requisition_id, user.farm_id), reason=payload.reason, user_id=user.id)
    db.commit()
    return procurement.requisition_dict(db, req)


# ---------------------------------------------- Package 2: quotes, orders, receipts
# Ordering is buying: drafting an order needs Inventory or Feed create,
# placing it (approval), closing or cancelling it the manager (Inventory or
# Feed approval, or the owner/manager role, checked by the service).
# Receiving against an approved order is the staff's (Inventory or Feed
# create) — the order is the authority, as an approved request was.
_buy_view = require_any_permission(perms.INVENTORY, perms.FEED_NUTRITION, action=perms.VIEW)
_buy_create = require_any_permission(perms.INVENTORY, perms.FEED_NUTRITION, action=perms.CREATE)
_buy_approve = require_any_permission(perms.INVENTORY, perms.FEED_NUTRITION, action=perms.APPROVE)


def _item_id(db: Session, user: models.User, inventory_item_id: str | None, feed_product_id: str | None) -> str:
    if feed_product_id:
        from app.services import feed_inventory_service as inv

        return inv.get_product(db, feed_product_id, user.farm_id).inventory_item_id
    if not inventory_item_id:
        raise procurement.ProcurementError("Name the item (inventory_item_id or feed_product_id).")
    return inventory_item_id


@router.get("/supplier-items")
def list_quotes(inventory_item_id: str | None = None, feed_product_id: str | None = None, db: Session = Depends(get_db),
                user: models.User = Depends(_buy_view)) -> list[dict]:
    """Who sells this item and for how much — cheapest first (in USD at
    today's rate) — with each supplier's last delivery price."""
    return orders.quotes_for(db, user.farm_id, _item_id(db, user, inventory_item_id, feed_product_id))


@router.post("/supplier-items", status_code=status.HTTP_201_CREATED)
def set_quote(payload: SupplierQuoteIn, db: Session = Depends(get_db), user: models.User = Depends(_buy_approve)) -> dict:
    """A supplier's price for an item (the manager's: prices decide orders)."""
    q = orders.set_quote(db, user, supplier_id=orders.resolve_supplier(db, user.farm_id, payload.supplier_id, payload.supplier_name), inventory_item_id=_item_id(db, user, payload.inventory_item_id, payload.feed_product_id),
                         unit_price=payload.unit_price, currency=payload.currency, purchase_uom=payload.purchase_uom,
                         supplier_item_code=payload.supplier_item_code, description=payload.description,
                         minimum_order_quantity=payload.minimum_order_quantity, standard_lead_time_days=payload.standard_lead_time_days)
    db.commit()
    return orders.quote_dict(db, q)


@router.get("/purchase-orders")
def list_orders(order_status: str | None = Query(None, alias="status"), limit: int = Query(100, ge=1, le=500), db: Session = Depends(get_db),
                user: models.User = Depends(_buy_view)) -> list[dict]:
    stmt = select(prm.PurchaseOrder).where(prm.PurchaseOrder.farm_id == user.farm_id)
    if order_status == "open":
        stmt = stmt.where(prm.PurchaseOrder.status.in_(("draft",) + prm.PO_OPEN))
    elif order_status:
        stmt = stmt.where(prm.PurchaseOrder.status == order_status)
    return [orders.order_dict(db, po) for po in db.scalars(stmt.order_by(prm.PurchaseOrder.order_date.desc()).limit(limit))]


@router.post("/purchase-orders", status_code=status.HTTP_201_CREATED)
def create_order(payload: PurchaseOrderIn, db: Session = Depends(get_db), user: models.User = Depends(_buy_create)) -> dict:
    """A draft order to one supplier, direct or from an approved request;
    `approve` places it at once when the person may."""
    po = orders.create_order(db, user, supplier_id=orders.resolve_supplier(db, user.farm_id, payload.supplier_id, payload.supplier_name), lines=[l.model_dump() for l in payload.lines], requisition_id=payload.requisition_id,
                             expected_delivery_date=payload.expected_delivery_date, currency=payload.currency, exchange_rate=payload.exchange_rate,
                             payment_terms=payload.payment_terms, notes=payload.notes)
    if payload.approve:
        orders.approve_order(db, user, po)
    db.commit()
    return orders.order_dict(db, po)


@router.get("/purchase-orders/{order_id}")
def get_order(order_id: str, db: Session = Depends(get_db), user: models.User = Depends(_buy_view)) -> dict:
    return orders.order_dict(db, orders.get_order(db, order_id, user.farm_id))


@router.post("/purchase-orders/{order_id}/approve")
def approve_order(order_id: str, payload: PurchaseOrderDecision | None = None, db: Session = Depends(get_db),
                  user: models.User = Depends(get_current_user)) -> dict:
    po = orders.get_order(db, order_id, user.farm_id, lock=True)
    orders.approve_order(db, user, po, comments=payload.comments if payload else None)
    db.commit()
    return orders.order_dict(db, po)


@router.post("/purchase-orders/{order_id}/cancel")
def cancel_order(order_id: str, payload: PurchaseOrderClose, db: Session = Depends(get_db), user: models.User = Depends(_buy_create)) -> dict:
    po = orders.get_order(db, order_id, user.farm_id, lock=True)
    orders.cancel_order(db, user, po, reason=payload.reason)
    db.commit()
    return orders.order_dict(db, po)


@router.post("/purchase-orders/{order_id}/close")
def close_order(order_id: str, payload: PurchaseOrderClose, db: Session = Depends(get_db), user: models.User = Depends(_buy_approve)) -> dict:
    po = orders.get_order(db, order_id, user.farm_id, lock=True)
    orders.close_order(db, user, po, reason=payload.reason)
    db.commit()
    return orders.order_dict(db, po)


@router.post("/purchase-orders/{order_id}/receive", status_code=status.HTTP_201_CREATED)
def receive_order(order_id: str, payload: GoodsReceiptIn, db: Session = Depends(get_db), user: models.User = Depends(_buy_create)) -> dict:
    """A delivery against an approved order. The order's row is locked, so
    two people receiving the same order at once cannot both take its last
    quantity."""
    po = orders.get_order(db, order_id, user.farm_id, lock=True)
    receipt = orders.receive(db, user, po, lines=[l.model_dump() for l in payload.lines], received_at=payload.received_at,
                             delivery_note_no=payload.delivery_note_no, payment=payload.payment, invoice_reference=payload.invoice_reference)
    db.commit()
    return {"receipt": orders.receipt_dict(db, receipt), "order": orders.order_dict(db, po)}


@router.get("/purchase-orders/{order_id}/match")
def match_order(order_id: str, db: Session = Depends(get_db), user: models.User = Depends(_buy_view)) -> dict:
    """Ordered, received, accepted, billed, paid and owed, per line and for
    the order — from the receipts, the lots' bills and their payments."""
    return orders.match(db, orders.get_order(db, order_id, user.farm_id))
