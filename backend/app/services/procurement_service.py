"""Purchase requisitions (database/PROCUREMENT-SCHEMA.md §5–§6).

A requisition is a request to buy: lines of inventory items in a unit,
with an estimated price and a preferred supplier. A replenishment rule
may open one DRAFT per unresolved shortage; a person submits it; a
manager approves or rejects it, and the authority behind the decision is
snapshotted. Nothing here orders or receives stock — an approved
requisition is not a purchase (§1) — but submitted and approved lines
count as *confirmed incoming* for the pharmacy's reorder arithmetic, and
a receipt that names the requisition closes it.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core import permissions as perms
from app.domain import models
from app.domain import procurement_models as prm
from app.repositories.base import ensure_utc, new_id, now, write_event
from app.services import routing_service as routing
from app.services import uom_service
from app.services.feed_inventory_service import FeedError

INCOMING_STATUSES = ("submitted", "approved", "ordered")
TASK_SOURCE = "purchase_requisition"


class ProcurementError(FeedError):
    pass


def get_requisition(db: Session, requisition_id: str, farm_id: str) -> prm.PurchaseRequisition:
    r = db.get(prm.PurchaseRequisition, requisition_id)
    if r is None or r.farm_id != farm_id:
        raise ProcurementError("Requisition not found", 404)
    return r


def next_requisition_no(db: Session, farm_id: str) -> str:
    n = (db.scalar(select(func.count(prm.PurchaseRequisition.id)).where(prm.PurchaseRequisition.farm_id == farm_id)) or 0) + 1
    while db.scalar(select(prm.PurchaseRequisition.id).where(prm.PurchaseRequisition.farm_id == farm_id, prm.PurchaseRequisition.requisition_no == f"REQ-{n:06d}")):
        n += 1
    return f"REQ-{n:06d}"


def open_for_source(db: Session, farm_id: str, source_type: str, source_reference_id: str) -> prm.PurchaseRequisition | None:
    """The unresolved requisition a shortage already opened, if any —
    never a duplicate draft for the same shortage (notification rules)."""
    return db.scalar(select(prm.PurchaseRequisition).where(
        prm.PurchaseRequisition.farm_id == farm_id, prm.PurchaseRequisition.source_type == source_type, prm.PurchaseRequisition.source_reference_id == source_reference_id,
        prm.PurchaseRequisition.status.in_(("draft",) + INCOMING_STATUSES)))


def create_requisition(db: Session, farm_id: str, *, lines: list[dict], requested_by: str, purpose_code: str | None = None, needed_by: datetime | None = None,
                       justification: str | None = None, source_type: str | None = None, source_reference_id: str | None = None, currency: str | None = None,
                       user_id: str) -> prm.PurchaseRequisition:
    if not lines:
        raise ProcurementError("A requisition needs at least one line.")
    farm = db.get(models.Farm, farm_id)
    req = prm.PurchaseRequisition(
        id=new_id(), farm_id=farm_id, requisition_no=next_requisition_no(db, farm_id), requested_by=requested_by, requested_at=now(),
        needed_by=ensure_utc(needed_by) if needed_by else None, purpose_code=purpose_code, status="draft", justification=justification, source_type=source_type,
        source_reference_id=source_reference_id, currency=currency or (farm.default_currency if farm else None), created_at=now(),
    )
    total, priced = 0.0, False
    for i, line in enumerate(lines, start=1):
        item = db.get(models.InventoryItem, line["inventory_item_id"])
        if item is None or item.farm_id != farm_id:
            raise ProcurementError("Inventory item not found", 404)
        qty = float(line.get("requested_quantity") or 0)
        if qty <= 0:
            raise ProcurementError(f"Requested quantity for {item.name} must be greater than zero.")
        unit = uom_service.require(db, line.get("uom_code") or item.unit, what="unit")
        price = line.get("estimated_unit_price")
        if price is None and item.unit_cost is not None and uom_service.compatible(db, unit, item.unit):
            price = round(item.unit_cost * uom_service.convert(db, 1, unit, item.unit), 6)
        supplier_id = line.get("preferred_supplier_id")
        if supplier_id and (db.get(models.Supplier, supplier_id) is None):
            raise ProcurementError("Preferred supplier not found", 404)
        req.lines.append(prm.PurchaseRequisitionLine(
            id=new_id(), line_no=i, inventory_item_id=item.id, requested_quantity=qty, uom_code=unit, estimated_unit_price=price, preferred_supplier_id=supplier_id,
            specification=line.get("specification"), status="open", source_recommendation_id=line.get("source_recommendation_id"),
        ))
        if price is not None:
            total += price * qty
            priced = True
    req.total_estimated_amount = round(total, 4) if priced else None
    db.add(req)
    db.flush()
    buyer = routing.primary_recipient(db, farm_id, "procurement_requisition")
    first = req.lines[0]
    item = db.get(models.InventoryItem, first.inventory_item_id)
    summary = f"{item.name} × {first.requested_quantity:g} {first.uom_code}" + (f" and {len(req.lines) - 1} more line(s)" if len(req.lines) > 1 else "")
    task = models.Task(
        id=new_id(), farm_id=farm_id, title=f"Draft requisition {req.requisition_no}: {summary}"[:300],
        description=(f"DRAFT purchase requisition ({purpose_code or 'manual'}). {justification or ''} Review, submit and approve before any order is placed.").strip()[:1500],
        assigned_to=buyer.id if buyer else None, due_at=ensure_utc(needed_by) if needed_by else now() + timedelta(days=3), priority="medium", status="open",
        source_type=TASK_SOURCE, source_id=req.id,
    )
    db.add(task)
    req.task_id = task.id
    db.flush()
    write_event(db, farm_id=farm_id, entity_type="purchase_requisition", entity_id=req.id, event_type="purchase_requisition_created",
                payload={"requisition_no": req.requisition_no, "purpose": purpose_code, "source": source_type, "source_id": source_reference_id,
                         "lines": [{"inventory_item_id": l.inventory_item_id, "quantity": l.requested_quantity, "uom": l.uom_code} for l in req.lines],
                         "assigned_to": task.assigned_to}, created_by=user_id)
    return req


def submit(db: Session, req: prm.PurchaseRequisition, *, user_id: str) -> prm.PurchaseRequisition:
    if req.status != "draft":
        raise ProcurementError(f"Requisition {req.requisition_no} is {req.status}; only a draft can be submitted.")
    req.status = "submitted"
    req.submitted_at = now()
    write_event(db, farm_id=req.farm_id, entity_type="purchase_requisition", entity_id=req.id, event_type="purchase_requisition_submitted",
                payload={"requisition_no": req.requisition_no}, created_by=user_id)
    _on_incoming_changed(db, req, user_id=user_id)
    return req


def _authority(db: Session, user: models.User) -> dict:
    role_ok = user.role in ("owner", "manager")
    perm_ok = False
    row = db.scalar(select(models.UserModulePermission).where(models.UserModulePermission.user_id == user.id, models.UserModulePermission.module_code == perms.INVENTORY))
    if row is not None and row.can_approve:
        perm_ok = True
    return {"user_id": user.id, "role": user.role, "basis": "role" if role_ok else ("inventory.approve" if perm_ok else None), "decided_at": now().isoformat()}


def decide(db: Session, req: prm.PurchaseRequisition, *, decision: str, user: models.User, comments: str | None = None) -> prm.PurchaseRequisition:
    """Approval / rejection by someone with authority (§6): a manager or
    owner, or a person granted inventory approve. The authority is
    snapshotted on the approval row at decision time."""
    if decision not in prm.APPROVAL_DECISIONS:
        raise ProcurementError("decision must be approved or rejected")
    if req.status not in ("draft", "submitted"):
        raise ProcurementError(f"Requisition {req.requisition_no} is {req.status} and cannot be decided.")
    authority = _authority(db, user)
    if authority["basis"] is None:
        raise ProcurementError("Approving a purchase requisition needs a farm manager, the owner, or inventory approve permission.", 403)
    if decision == "rejected" and not (comments and comments.strip()):
        raise ProcurementError("Say why the requisition is rejected.")
    db.add(prm.ProcurementApproval(id=new_id(), farm_id=req.farm_id, document_type="purchase_requisition", document_id=req.id, approval_stage="manager",
                                   decision=decision, decided_by=user.id, decided_at=now(), authority_snapshot=authority, comments=comments))
    req.status = decision
    req.decided_at = now()
    req.decided_by = user.id
    for line in req.lines:
        line.status = decision
    if req.task_id:
        t = db.get(models.Task, req.task_id)
        if t is not None and t.status == "open":
            t.status = "done"
    write_event(db, farm_id=req.farm_id, entity_type="purchase_requisition", entity_id=req.id,
                event_type="purchase_requisition_approved" if decision == "approved" else "purchase_requisition_rejected",
                payload={"requisition_no": req.requisition_no, "by": user.id, "authority": authority["basis"], "comments": comments}, created_by=user.id)
    _on_incoming_changed(db, req, user_id=user.id)
    return req


def cancel(db: Session, req: prm.PurchaseRequisition, *, reason: str, user_id: str) -> prm.PurchaseRequisition:
    if req.status in ("received", "cancelled"):
        return req
    if req.status == "ordered":
        raise ProcurementError("An ordered requisition is cancelled through its purchase order.")
    if not reason or not reason.strip():
        raise ProcurementError("Say why the requisition is cancelled.")
    req.status = "cancelled"
    for line in req.lines:
        line.status = "cancelled"
    if req.task_id:
        t = db.get(models.Task, req.task_id)
        if t is not None and t.status == "open":
            t.status = "done"
    write_event(db, farm_id=req.farm_id, entity_type="purchase_requisition", entity_id=req.id, event_type="purchase_requisition_cancelled",
                payload={"requisition_no": req.requisition_no, "reason": reason}, created_by=user_id)
    _on_incoming_changed(db, req, user_id=user_id)
    return req


def mark_received(db: Session, req: prm.PurchaseRequisition, *, inventory_item_id: str | None = None, user_id: str) -> prm.PurchaseRequisition:
    """A goods receipt that names the requisition closes its line(s); when
    every line is received the requisition is received. Receipt of stock
    itself is the inventory module's fact."""
    if req.status not in INCOMING_STATUSES and req.status != "draft":
        return req
    for line in req.lines:
        if inventory_item_id is None or line.inventory_item_id == inventory_item_id:
            line.status = "received"
    if all(l.status in ("received", "cancelled", "rejected") for l in req.lines):
        req.status = "received"
        if req.task_id:
            t = db.get(models.Task, req.task_id)
            if t is not None and t.status == "open":
                t.status = "done"
    write_event(db, farm_id=req.farm_id, entity_type="purchase_requisition", entity_id=req.id, event_type="purchase_requisition_received",
                payload={"requisition_no": req.requisition_no, "inventory_item_id": inventory_item_id, "status": req.status}, created_by=user_id)
    _on_incoming_changed(db, req, user_id=user_id)
    return req


def incoming_quantity(db: Session, farm_id: str, inventory_item_id: str, unit: str) -> float:
    """Confirmed incoming supply for the item, in `unit` (§9 of the
    pharmacy schema: recommended = target − eligible − confirmed incoming)."""
    total = 0.0
    rows = db.execute(select(prm.PurchaseRequisitionLine).join(prm.PurchaseRequisition, prm.PurchaseRequisition.id == prm.PurchaseRequisitionLine.requisition_id).where(
        prm.PurchaseRequisition.farm_id == farm_id, prm.PurchaseRequisition.status.in_(INCOMING_STATUSES), prm.PurchaseRequisitionLine.inventory_item_id == inventory_item_id,
        prm.PurchaseRequisitionLine.status.in_(("open", "approved", "ordered")))).scalars().all()
    for line in rows:
        try:
            total += uom_service.convert(db, line.requested_quantity, line.uom_code, unit)
        except Exception:  # noqa: BLE001 - a line in an unconvertible unit does not count as incoming
            continue
    return round(total, 6)


def _on_incoming_changed(db: Session, req: prm.PurchaseRequisition, *, user_id: str) -> None:
    """Procurement incoming-supply change re-evaluates the pharmacy
    policies of the medicines on the requisition (notification rules)."""
    from app.domain import pharmacy_models as pm  # local imports: the pharmacy imports this module
    from app.services import pharmacy_service as ph

    for line in req.lines:
        product = db.get(pm.MedicineProduct, line.inventory_item_id)
        if product is not None:
            ph.evaluate_item(db, product, user_id=user_id)


def requisition_dict(db: Session, r: prm.PurchaseRequisition) -> dict:
    requester = db.get(models.User, r.requested_by)
    approvals = db.scalars(select(prm.ProcurementApproval).where(prm.ProcurementApproval.document_type == "purchase_requisition", prm.ProcurementApproval.document_id == r.id)
                           .order_by(prm.ProcurementApproval.decided_at)).all()
    lines = []
    for l in r.lines:
        item = db.get(models.InventoryItem, l.inventory_item_id)
        supplier = db.get(models.Supplier, l.preferred_supplier_id) if l.preferred_supplier_id else None
        lines.append({"id": l.id, "line_no": l.line_no, "inventory_item_id": l.inventory_item_id, "item_name": item.name if item else None,
                      "requested_quantity": l.requested_quantity, "uom_code": l.uom_code, "estimated_unit_price": l.estimated_unit_price,
                      "preferred_supplier_id": l.preferred_supplier_id, "preferred_supplier_name": supplier.name if supplier else None,
                      "specification": l.specification, "status": l.status, "source_recommendation_id": l.source_recommendation_id})
    return {
        "id": r.id, "farm_id": r.farm_id, "requisition_no": r.requisition_no, "requested_by": r.requested_by, "requested_by_name": requester.name if requester else None,
        "requested_at": r.requested_at, "needed_by": r.needed_by, "purpose_code": r.purpose_code, "status": r.status, "justification": r.justification,
        "source_type": r.source_type, "source_reference_id": r.source_reference_id, "total_estimated_amount": r.total_estimated_amount, "currency": r.currency,
        "submitted_at": r.submitted_at, "decided_at": r.decided_at, "decided_by": r.decided_by, "task_id": r.task_id, "created_at": r.created_at, "lines": lines,
        "approvals": [{"id": a.id, "decision": a.decision, "decided_by": a.decided_by, "decided_at": a.decided_at, "authority": a.authority_snapshot, "comments": a.comments} for a in approvals],
    }
