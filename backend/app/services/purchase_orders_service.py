"""Ordering and receiving feed (master prompt Package 2; database/PROCUREMENT-SCHEMA.md
§4, §7, §8).

    a supplier's quote (several suppliers, several prices, one ingredient)
      → a purchase order (from an approved requisition, or direct) → its approval
      → deliveries against it, partial or whole: received, accepted, rejected
        — the accepted goods become a feed lot through the inventory ledger,
          with the supplier, the price ordered, the day and the quality seen
      → the supplier's bill for each delivery (purchases_service, v0.8.9)
      → payments, in parts, on the bill
      → the order's match: ordered, received, accepted, billed, paid, owed

A purchase order is not stock, a receipt is not an invoice and an approved
requisition is not a purchase (§1). Nothing here keeps a running balance:
what was received is the goods receipts, what is in stock is the ledger,
what is owed is the bills and their payments. A mix made from the lots
stays traceable to the order, the receipt and the supplier through its
ingredient lots (GET /feed-lots/{id}/trace).
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.domain import feed_models as fm
from app.domain import finance_models as fin
from app.domain import models
from app.domain import procurement_models as prm
from app.feeding import uom
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event
from app.services import feed_inventory_service as inv
from app.services import finance_service as finance
from app.services import procurement_service as procurement
from app.services import purchases_service as purchases
from app.services.procurement_service import ProcurementError

EPS = 1e-6
# A delivery may come in a little over what was ordered (a full bag, a
# rounded weighbridge ticket); more than this is refused.
OVER_DELIVERY = 0.10
MODULE = "inventory"


# ------------------------------------------------------------- lookups
def get_supplier(db: Session, supplier_id: str, farm_id: str) -> models.Supplier:
    s = db.get(models.Supplier, supplier_id)
    if s is None or s.farm_id != farm_id:
        raise ProcurementError("Supplier not found", 404)
    return s


def resolve_supplier(db: Session, farm_id: str, supplier_id: str | None, supplier_name: str | None) -> str:
    """A supplier of this farm by id, or by name (a new name adds it)."""
    sid, _name = finance._supplier(db, farm_id, supplier_id, supplier_name)
    if sid is None:
        raise ProcurementError("Name the supplier.")
    return sid


def get_order(db: Session, order_id: str, farm_id: str, *, lock: bool = False) -> prm.PurchaseOrder:
    stmt = select(prm.PurchaseOrder).where(prm.PurchaseOrder.id == order_id)
    if lock:
        stmt = stmt.with_for_update()
    po = db.scalar(stmt)
    if po is None or po.farm_id != farm_id:
        raise ProcurementError("Purchase order not found", 404)
    return po


def _product_for_item(db: Session, farm_id: str, *, inventory_item_id: str | None = None, feed_product_id: str | None = None) -> fm.FeedProduct:
    if feed_product_id:
        return inv.get_product(db, feed_product_id, farm_id)
    product = db.scalar(select(fm.FeedProduct).where(fm.FeedProduct.farm_id == farm_id, fm.FeedProduct.inventory_item_id == inventory_item_id))
    if product is None:
        raise ProcurementError("Purchase orders are for feed and feed ingredients: this item is not a feed product.")
    return product


def _next_no(db: Session, model, column, farm_id: str, prefix: str) -> str:
    n = (db.scalar(select(func.count(model.id)).where(model.farm_id == farm_id)) or 0) + 1
    while db.scalar(select(model.id).where(model.farm_id == farm_id, column == f"{prefix}-{n:06d}")):
        n += 1
    return f"{prefix}-{n:06d}"


# --------------------------------------------------- §4 suppliers' quotes
def quotes_for(db: Session, farm_id: str, inventory_item_id: str) -> list[dict]:
    """Who sells this item, and for how much now — cheapest first in USD
    at today's rate — with the price of each supplier's last delivery."""
    rows = list(db.scalars(select(prm.SupplierItem).where(prm.SupplierItem.farm_id == farm_id, prm.SupplierItem.inventory_item_id == inventory_item_id,
                                                         prm.SupplierItem.status == "active")))
    product = db.scalar(select(fm.FeedProduct).where(fm.FeedProduct.farm_id == farm_id, fm.FeedProduct.inventory_item_id == inventory_item_id))
    out = []
    for q in rows:
        usd = None
        if q.unit_price is not None:
            try:
                usd = finance.to_base(db, farm_id, q.unit_price, q.currency, None, now())[0]
            except finance.FinanceError:  # an LBP quote with no farm rate set: listed, compared last
                usd = None
        last = None
        if product is not None:
            last = db.scalar(select(fm.FeedLot).where(fm.FeedLot.feed_product_id == product.id, fm.FeedLot.supplier_id == q.supplier_id,
                                                      fm.FeedLot.unit_cost.is_not(None)).order_by(fm.FeedLot.received_at.desc()).limit(1))
        out.append({**quote_dict(db, q), "unit_price_usd": round(usd, 4) if usd is not None else None,
                    "last_delivery": None if last is None else {"lot_id": last.id, "lot_code": last.lot_code, "unit_cost_usd": last.unit_cost,
                                                                 "unit": product.unit, "received_at": ensure_utc(last.received_at).isoformat()}})
    out.sort(key=lambda d: (d["unit_price_usd"] is None, d["unit_price_usd"] or 0, d["supplier_name"]))
    return out


def set_quote(db: Session, user: models.User, *, supplier_id: str, inventory_item_id: str, unit_price: float | None, currency: str = "USD",
              purchase_uom: str | None = None, supplier_item_code: str | None = None, description: str | None = None,
              minimum_order_quantity: float | None = None, standard_lead_time_days: float | None = None) -> prm.SupplierItem:
    """The price a supplier quotes for an item, kept per supplier: a new
    price replaces the quote (the old one stays in the audit log); orders
    keep the price they were placed at."""
    supplier = get_supplier(db, supplier_id, user.farm_id)
    item = db.get(models.InventoryItem, inventory_item_id)
    if item is None or item.farm_id != user.farm_id:
        raise ProcurementError("Item not found", 404)
    product = db.scalar(select(fm.FeedProduct).where(fm.FeedProduct.farm_id == user.farm_id, fm.FeedProduct.inventory_item_id == item.id))
    unit = purchase_uom or (product.unit if product is not None else item.unit)
    if unit_price is not None and unit_price < 0:
        raise ProcurementError("A price cannot be negative.")
    currency = (currency or "USD").upper()
    if currency not in fin.CURRENCIES:
        raise ProcurementError(f"currency must be one of {list(fin.CURRENCIES)}")
    code = (supplier_item_code or "").strip()
    q = db.scalar(select(prm.SupplierItem).where(prm.SupplierItem.supplier_id == supplier.id, prm.SupplierItem.inventory_item_id == item.id,
                                                 prm.SupplierItem.supplier_item_code == code))
    before = None if q is None else {"unit_price": q.unit_price, "currency": q.currency, "purchase_uom": q.purchase_uom}
    if q is None:
        q = prm.SupplierItem(id=new_id(), farm_id=user.farm_id, supplier_id=supplier.id, inventory_item_id=item.id, supplier_item_code=code,
                             purchase_uom=unit, currency=currency, status="active", created_at=now())
        db.add(q)
    q.unit_price, q.currency, q.purchase_uom = unit_price, currency, unit
    q.description = description if description is not None else q.description
    q.minimum_order_quantity = minimum_order_quantity if minimum_order_quantity is not None else q.minimum_order_quantity
    q.standard_lead_time_days = standard_lead_time_days if standard_lead_time_days is not None else q.standard_lead_time_days
    q.price_updated_at = now()
    q.status = "active"
    db.flush()
    after = {"unit_price": q.unit_price, "currency": q.currency, "purchase_uom": q.purchase_uom}
    if before != after:
        write_audit_log(db, farm_id=user.farm_id, user_id=user.id, action="supplier_price_set", entity_type="supplier_item", entity_id=q.id,
                        module_code=MODULE, summary=f"{supplier.name}: {item.name} at {unit_price} {currency}/{unit}"[:500],
                        changes={k: {"from": (before or {}).get(k), "to": v} for k, v in after.items() if (before or {}).get(k) != v})
        write_event(db, farm_id=user.farm_id, entity_type="supplier_item", entity_id=q.id, event_type="supplier_price_set",
                    payload={"supplier_id": supplier.id, "inventory_item_id": item.id, **after}, created_by=user.id)
    return q


def quote_dict(db: Session, q: prm.SupplierItem) -> dict:
    s = db.get(models.Supplier, q.supplier_id)
    item = db.get(models.InventoryItem, q.inventory_item_id)
    return {"id": q.id, "supplier_id": q.supplier_id, "supplier_name": s.name if s else None, "inventory_item_id": q.inventory_item_id,
            "item_name": item.name if item else None, "supplier_item_code": q.supplier_item_code or None, "description": q.description,
            "purchase_uom": q.purchase_uom, "unit_price": q.unit_price, "currency": q.currency, "minimum_order_quantity": q.minimum_order_quantity,
            "standard_lead_time_days": q.standard_lead_time_days,
            "price_updated_at": ensure_utc(q.price_updated_at).isoformat() if q.price_updated_at else None, "status": q.status}


# ------------------------------------------------------- §7 purchase orders
def create_order(db: Session, user: models.User, *, supplier_id: str, lines: list[dict], requisition_id: str | None = None,
                 expected_delivery_date: datetime | None = None, currency: str = "USD", exchange_rate: float | None = None,
                 payment_terms: str = "credit", notes: str | None = None) -> prm.PurchaseOrder:
    """A draft order to one supplier. Each line names a feed (or its
    inventory item), a quantity and unit, and the price — the supplier's
    quote when none is given. From a requisition, the lines must be the
    requisition's approved items; the requisition becomes ordered."""
    supplier = get_supplier(db, supplier_id, user.farm_id)
    if not lines:
        raise ProcurementError("An order needs at least one line.")
    if payment_terms not in ("paid", "credit"):
        raise ProcurementError("payment_terms must be paid (on each delivery) or credit; part payments are made on the bills.")
    currency = (currency or "USD").upper()
    if currency not in fin.CURRENCIES:
        raise ProcurementError(f"currency must be one of {list(fin.CURRENCIES)}")
    if exchange_rate is not None and exchange_rate <= 0:
        raise ProcurementError("The exchange rate must be positive.")
    req = procurement.get_requisition(db, requisition_id, user.farm_id) if requisition_id else None
    if req is not None and req.status != "approved":
        raise ProcurementError(f"Purchase request {req.requisition_no} is {req.status}; an order is placed from an approved request.", 409)
    po = prm.PurchaseOrder(id=new_id(), farm_id=user.farm_id, supplier_id=supplier.id, po_no=_next_no(db, prm.PurchaseOrder, prm.PurchaseOrder.po_no, user.farm_id, "PO"),
                           requisition_id=req.id if req else None, order_date=now(), expected_delivery_date=expected_delivery_date, currency=currency,
                           exchange_rate=exchange_rate, payment_terms=payment_terms, status="draft", notes=notes, created_by=user.id, created_at=now())
    db.add(po)
    subtotal = 0.0
    for n, raw in enumerate(lines, start=1):
        product = _product_for_item(db, user.farm_id, inventory_item_id=raw.get("inventory_item_id"), feed_product_id=raw.get("feed_product_id"))
        qty = float(raw.get("quantity") or 0)
        if qty <= 0:
            raise ProcurementError(f"Line {n}: the quantity ordered must be more than nothing.")
        unit = raw.get("unit") or product.unit
        try:
            uom.convert(1, unit, product.unit)
        except Exception as exc:  # noqa: BLE001 - an impossible unit pair
            raise ProcurementError(f"Line {n}: {unit} is not a unit {product.name} can be counted in ({product.unit}).") from exc
        price = raw.get("unit_price")
        if price is None:
            quote = db.scalar(select(prm.SupplierItem).where(prm.SupplierItem.supplier_id == supplier.id, prm.SupplierItem.inventory_item_id == product.inventory_item_id,
                                                             prm.SupplierItem.status == "active", prm.SupplierItem.unit_price.is_not(None)))
            if quote is None or quote.currency != currency:
                raise ProcurementError(f"Line {n}: no {currency} price from {supplier.name} for {product.name} — give the price, or record the supplier's quote first.")
            price = uom.convert(1, unit, quote.purchase_uom) * quote.unit_price  # the quote's price per the line's unit
        if price < 0:
            raise ProcurementError(f"Line {n}: a price cannot be negative.")
        req_line = None
        if req is not None:
            req_line = next((l for l in req.lines if l.inventory_item_id == product.inventory_item_id and l.status == "approved"), None)
            if req_line is None:
                raise ProcurementError(f"Purchase request {req.requisition_no} does not include {product.name}.")
        total = round(qty * float(price), 4)
        subtotal += total
        po.lines.append(prm.PurchaseOrderLine(id=new_id(), requisition_line_id=req_line.id if req_line else None, line_no=n,
                                              inventory_item_id=product.inventory_item_id, feed_product_id=product.id, ordered_quantity=qty,
                                              uom_code=unit, unit_price=round(float(price), 6), line_total=total, status="open"))
    po.subtotal = po.total_amount = round(subtotal, 4)
    if req is not None:
        req.status = "ordered"
        for l in req.lines:
            if l.status == "approved":
                l.status = "ordered"
    db.flush()
    write_audit_log(db, farm_id=user.farm_id, user_id=user.id, action="purchase_order_created", entity_type="purchase_order", entity_id=po.id,
                    module_code=MODULE, summary=f"{po.po_no} to {supplier.name}: {po.total_amount:g} {currency}"[:500],
                    metadata={"requisition_id": po.requisition_id, "lines": len(po.lines)})
    write_event(db, farm_id=user.farm_id, entity_type="purchase_order", entity_id=po.id, event_type="purchase_order_created",
                payload={"po_no": po.po_no, "supplier_id": supplier.id, "total_amount": po.total_amount, "currency": currency}, created_by=user.id)
    return po


def _order_authority(db: Session, user: models.User, po: prm.PurchaseOrder) -> dict:
    """Who may place an order: a manager or the owner, Inventory approve,
    or Feed & Nutrition approve (orders are for feed)."""
    from app.api.deps import user_can
    from app.core import permissions as perms

    basis = "role" if user.role in ("owner", "manager") else None
    if basis is None and user_can(db, user, perms.INVENTORY, perms.APPROVE):
        basis = "inventory.approve"
    if basis is None and user_can(db, user, perms.FEED_NUTRITION, perms.APPROVE):
        basis = "feed_nutrition.approve"
    return {"user_id": user.id, "role": user.role, "basis": basis, "decided_at": now().isoformat()}


def approve_order(db: Session, user: models.User, po: prm.PurchaseOrder, *, comments: str | None = None) -> prm.PurchaseOrder:
    if po.status != "draft":
        raise ProcurementError(f"{po.po_no} is {po.status}; only a draft order is approved.", 409)
    authority = _order_authority(db, user, po)
    if authority["basis"] is None:
        raise ProcurementError("Placing a purchase order needs the farm manager, the owner, or Inventory or Feed approval.", 403)
    db.add(prm.ProcurementApproval(id=new_id(), farm_id=po.farm_id, document_type="purchase_order", document_id=po.id, approval_stage="manager",
                                   decision="approved", decided_by=user.id, decided_at=now(), authority_snapshot=authority, comments=comments))
    po.status, po.approved_by, po.approved_at = "approved", user.id, now()
    write_audit_log(db, farm_id=po.farm_id, user_id=user.id, action="purchase_order_approved", entity_type="purchase_order", entity_id=po.id,
                    module_code=MODULE, summary=f"{po.po_no} approved", metadata={"authority": authority["basis"]})
    write_event(db, farm_id=po.farm_id, entity_type="purchase_order", entity_id=po.id, event_type="purchase_order_approved",
                payload={"po_no": po.po_no, "by": user.id, "authority": authority["basis"]}, created_by=user.id)
    return po


def _received(db: Session, line_ids: list[str]) -> dict[str, tuple[float, float, float]]:
    """(received, accepted, rejected) per order line, in the line's unit."""
    out: dict[str, tuple[float, float, float]] = {i: (0.0, 0.0, 0.0) for i in line_ids}
    if not line_ids:
        return out
    for lid, r, a, j in db.execute(select(prm.GoodsReceiptLine.purchase_order_line_id, func.sum(prm.GoodsReceiptLine.received_quantity),
                                          func.sum(prm.GoodsReceiptLine.accepted_quantity), func.sum(prm.GoodsReceiptLine.rejected_quantity))
                                   .where(prm.GoodsReceiptLine.purchase_order_line_id.in_(line_ids)).group_by(prm.GoodsReceiptLine.purchase_order_line_id)):
        out[lid] = (float(r or 0), float(a or 0), float(j or 0))
    return out


def cancel_order(db: Session, user: models.User, po: prm.PurchaseOrder, *, reason: str) -> prm.PurchaseOrder:
    if not (reason or "").strip():
        raise ProcurementError("Say why the order is cancelled.")
    if po.status in ("cancelled", "closed", "received"):
        raise ProcurementError(f"{po.po_no} is {po.status}.", 409)
    if any(r > EPS for r, _a, _j in _received(db, [l.id for l in po.lines]).values()):
        raise ProcurementError(f"Goods were received on {po.po_no}: close it instead — what came stays received.", 409)
    if _order_authority(db, user, po)["basis"] is None and po.created_by != user.id:
        raise ProcurementError("Cancelling a purchase order needs the farm manager or the person who drafted it.", 403)
    po.status, po.closed_reason = "cancelled", reason.strip()
    for l in po.lines:
        l.status = "cancelled"
    if po.requisition_id:
        req = db.get(prm.PurchaseRequisition, po.requisition_id)
        if req is not None and req.status == "ordered":
            req.status = "approved"
            for rl in req.lines:
                if rl.status == "ordered":
                    rl.status = "approved"
    write_audit_log(db, farm_id=po.farm_id, user_id=user.id, action="purchase_order_cancelled", entity_type="purchase_order", entity_id=po.id,
                    module_code=MODULE, summary=f"{po.po_no} cancelled: {reason.strip()}"[:500])
    write_event(db, farm_id=po.farm_id, entity_type="purchase_order", entity_id=po.id, event_type="purchase_order_cancelled",
                payload={"po_no": po.po_no, "reason": reason.strip()}, created_by=user.id)
    return po


def close_order(db: Session, user: models.User, po: prm.PurchaseOrder, *, reason: str) -> prm.PurchaseOrder:
    """The rest is not coming: the order is closed short; what was
    received stays received and billed."""
    if not (reason or "").strip():
        raise ProcurementError("Say why the rest is not coming.")
    if po.status not in prm.PO_OPEN:
        raise ProcurementError(f"{po.po_no} is {po.status}; an approved or partly received order is closed.", 409)
    if _order_authority(db, user, po)["basis"] is None:
        raise ProcurementError("Closing a purchase order needs the farm manager.", 403)
    po.status, po.closed_reason = "closed", reason.strip()
    received = _received(db, [l.id for l in po.lines])
    for l in po.lines:
        l.status = "received" if received[l.id][0] + EPS >= l.ordered_quantity else "closed"
    if po.requisition_id:
        req = db.get(prm.PurchaseRequisition, po.requisition_id)
        if req is not None:
            procurement.mark_received(db, req, user_id=user.id)
    write_audit_log(db, farm_id=po.farm_id, user_id=user.id, action="purchase_order_closed", entity_type="purchase_order", entity_id=po.id,
                    module_code=MODULE, summary=f"{po.po_no} closed: {reason.strip()}"[:500])
    write_event(db, farm_id=po.farm_id, entity_type="purchase_order", entity_id=po.id, event_type="purchase_order_closed",
                payload={"po_no": po.po_no, "reason": reason.strip()}, created_by=user.id)
    return po


# ----------------------------------------------------------- §8 receiving
def receive(db: Session, user: models.User, po: prm.PurchaseOrder, *, lines: list[dict], received_at: datetime | None = None,
            delivery_note_no: str | None = None, payment: str | None = None, invoice_reference: str | None = None) -> prm.GoodsReceipt:
    """A delivery against an approved order: per line what came, what was
    rejected and the quality seen. The accepted goods become a feed lot —
    the supplier, the price ordered, the day, the quality — through the
    inventory ledger, and the supplier's bill for them is posted (paid on
    delivery, or owed). Partial deliveries leave the order partly received."""
    if po.status not in prm.PO_OPEN:
        hint = "it is received once approved" if po.status == "draft" else "nothing more is received on it"
        raise ProcurementError(f"{po.po_no} is {po.status}: {hint}.", 409)
    if not lines:
        raise ProcurementError("Say what came on which line.")
    terms = payment or po.payment_terms
    if terms not in ("paid", "credit"):
        raise ProcurementError("payment must be paid (on delivery) or credit; part payments are made on the bill.")
    when = ensure_utc(received_at) if received_at else now()
    if when > now():
        raise ProcurementError("A delivery cannot be dated in the future.")
    supplier = get_supplier(db, po.supplier_id, po.farm_id)
    by_id = {l.id: l for l in po.lines}
    done = _received(db, list(by_id))
    receipt = prm.GoodsReceipt(id=new_id(), farm_id=po.farm_id, supplier_id=supplier.id, purchase_order_id=po.id,
                               receipt_no=_next_no(db, prm.GoodsReceipt, prm.GoodsReceipt.receipt_no, po.farm_id, "GR"), received_at=when,
                               received_by=user.id, delivery_note_no=(delivery_note_no or "").strip() or None, status="posted", created_at=now())
    db.add(receipt)
    seen: set[str] = set()
    n = 0
    rejected_total = 0.0
    for raw in lines:
        line = by_id.get(raw.get("purchase_order_line_id") or "")
        if line is None:
            raise ProcurementError("A line of the delivery is not on this order.")
        if line.id in seen:
            raise ProcurementError(f"Line {line.line_no} is given twice in one delivery.")
        seen.add(line.id)
        received = float(raw.get("received_quantity") or 0)
        rejected = float(raw.get("rejected_quantity") or 0)
        if received < 0 or rejected < 0:
            raise ProcurementError("Quantities cannot be negative.")
        if rejected > received + EPS:
            raise ProcurementError(f"Line {line.line_no}: more rejected ({rejected:g}) than came ({received:g}).")
        if received <= EPS:
            continue
        if rejected > EPS and not (raw.get("rejection_reason") or "").strip():
            raise ProcurementError(f"Line {line.line_no}: say why {rejected:g} {line.uom_code} were rejected.")
        if done[line.id][0] + received > line.ordered_quantity * (1 + OVER_DELIVERY) + EPS:
            raise ProcurementError(f"Line {line.line_no}: {done[line.id][0] + received:g} {line.uom_code} would be more than the "
                                   f"{line.ordered_quantity:g} {line.uom_code} ordered; record the extra on a new order.")
        product = inv.get_product(db, line.feed_product_id, po.farm_id)
        qty, rej = uom.convert(received, line.uom_code, product.unit), uom.convert(rejected, line.uom_code, product.unit)
        # The price ordered, per the feed's own unit, in the order's currency.
        per_unit = line.unit_price / uom.convert(1, line.uom_code, product.unit)
        lot = inv.receive(db, product, quantity=qty, rejected_quantity=rej, unit=product.unit,
                          unit_cost=purchases.unit_cost_in_usd(db, po.farm_id, per_unit, po.currency, po.exchange_rate, when),
                          supplier_id=supplier.id, supplier_label=supplier.name, lot_code=(raw.get("lot_code") or "").strip() or None,
                          ordered_quantity=uom.convert(line.ordered_quantity, line.uom_code, product.unit), reference=receipt.delivery_note_no or receipt.receipt_no,
                          notes=f"{po.po_no} line {line.line_no}, {receipt.receipt_no}", received_at=when, user_id=user.id,
                          quality_grade=raw.get("quality_grade"), quality_notes=raw.get("quality_notes"))
        bill = None
        if qty - rej > EPS:
            bill = purchases.bill_delivery(db, farm_id=po.farm_id, user_id=user.id, lot_type="feed_lot", lot=lot, category="feed", label=product.name,
                                           unit_price=per_unit, currency=po.currency, exchange_rate=po.exchange_rate, payment=terms,
                                           invoice_reference=invoice_reference or receipt.delivery_note_no or po.po_no, supplier_id=supplier.id,
                                           supplier_name=supplier.name)
        if raw.get("quality_grade") == "poor" and lot.status == "active":
            inv.set_lot_status(db, lot, "quarantined", reason="Graded poor at receipt; release after inspection.", user_id=user.id)
        n += 1
        receipt.lines.append(prm.GoodsReceiptLine(id=new_id(), purchase_order_line_id=line.id, line_no=n, inventory_item_id=line.inventory_item_id,
                                                  received_quantity=received, accepted_quantity=received - rejected, rejected_quantity=rejected,
                                                  uom_code=line.uom_code, feed_lot_id=lot.id, expense_id=bill.id if bill else None,
                                                  quality_grade=raw.get("quality_grade"),
                                                  rejection_reason=(raw.get("rejection_reason") or "").strip() or None))
        rejected_total += rejected
    if not receipt.lines:
        raise ProcurementError("Nothing came: give the quantity received on at least one line.")
    db.flush()
    now_received = _received(db, list(by_id))
    for l in po.lines:
        l.status = "received" if now_received[l.id][0] + EPS >= l.ordered_quantity else ("partially_received" if now_received[l.id][0] > EPS else "open")
    po.status = "received" if all(l.status == "received" for l in po.lines) else "partially_received"
    if po.status == "received" and po.requisition_id:
        req = db.get(prm.PurchaseRequisition, po.requisition_id)
        if req is not None:
            procurement.mark_received(db, req, user_id=user.id)
    write_audit_log(db, farm_id=po.farm_id, user_id=user.id, action="goods_received", entity_type="goods_receipt", entity_id=receipt.id,
                    module_code=MODULE, summary=f"{receipt.receipt_no} on {po.po_no} from {supplier.name}: {len(receipt.lines)} line(s)"[:500],
                    metadata={"purchase_order_id": po.id, "lots": [l.feed_lot_id for l in receipt.lines]})
    write_event(db, farm_id=po.farm_id, entity_type="purchase_order", entity_id=po.id, event_type="goods_received",
                payload={"po_no": po.po_no, "receipt_no": receipt.receipt_no, "status": po.status, "lots": [l.feed_lot_id for l in receipt.lines]},
                created_by=user.id)
    if rejected_total > EPS:
        write_event(db, farm_id=po.farm_id, entity_type="purchase_order", entity_id=po.id, event_type="goods_rejected",
                    payload={"po_no": po.po_no, "receipt_no": receipt.receipt_no,
                             "lines": [{"line_no": l.line_no, "rejected": l.rejected_quantity, "reason": l.rejection_reason} for l in receipt.lines if l.rejected_quantity > EPS]},
                    created_by=user.id)
    return receipt


# ------------------------------------------------------------- the match
def match(db: Session, po: prm.PurchaseOrder) -> dict:
    """Ordered against received, accepted, billed and paid — per line and
    for the order — read from the receipts, the lots' bills and their
    payments. The bills are in the order's currency at the price ordered;
    a difference is shown, never hidden."""
    lines = list(po.lines)
    done = _received(db, [l.id for l in lines])
    receipt_lines = list(db.scalars(select(prm.GoodsReceiptLine).join(prm.GoodsReceipt).where(prm.GoodsReceipt.purchase_order_id == po.id)))
    bills = [db.get(models.Expense, rl.expense_id) for rl in receipt_lines if rl.expense_id]
    st = finance.settlement(db, [b.id for b in bills if b is not None])
    billed_by_line: dict[str, float] = {}
    owed_by_line: dict[str, float] = {}
    paid_by_line: dict[str, float] = {}
    for rl in receipt_lines:
        b = db.get(models.Expense, rl.expense_id) if rl.expense_id else None
        if b is None or b.status != "recorded":
            continue
        total = finance.bill_total(b)
        rest, _usd = finance.bill_balance(b, st.get(b.id))
        billed_by_line[rl.purchase_order_line_id] = billed_by_line.get(rl.purchase_order_line_id, 0) + total
        owed_by_line[rl.purchase_order_line_id] = owed_by_line.get(rl.purchase_order_line_id, 0) + max(rest, 0)
        paid_by_line[rl.purchase_order_line_id] = paid_by_line.get(rl.purchase_order_line_id, 0) + (total - rest)
    out_lines = []
    problems: list[str] = []
    for l in lines:
        received, accepted, rejected = done[l.id]
        accepted_value = round(accepted * l.unit_price, 2)
        billed = round(billed_by_line.get(l.id, 0), 2)
        product = db.get(fm.FeedProduct, l.feed_product_id) if l.feed_product_id else None
        name = product.name if product else l.inventory_item_id
        outstanding = 0.0 if po.status in ("closed", "cancelled") else max(l.ordered_quantity - received, 0)
        if abs(billed - accepted_value) > 0.01:
            problems.append(f"Line {l.line_no} ({name}): billed {billed:g} {po.currency} for {accepted:g} {l.uom_code} accepted at "
                            f"{l.unit_price:g} = {accepted_value:g} {po.currency}.")
        if received > l.ordered_quantity + EPS:
            problems.append(f"Line {l.line_no} ({name}): {received:g} {l.uom_code} came on {l.ordered_quantity:g} ordered.")
        out_lines.append({"line_id": l.id, "line_no": l.line_no, "feed_product_id": l.feed_product_id, "name": name, "unit": l.uom_code,
                          "unit_price": l.unit_price, "ordered": l.ordered_quantity, "ordered_value": round(l.line_total, 2),
                          "received": round(received, 6), "accepted": round(accepted, 6), "rejected": round(rejected, 6),
                          "outstanding": round(outstanding, 6), "accepted_value": accepted_value, "billed": billed,
                          "paid": round(paid_by_line.get(l.id, 0), 2), "owed": round(owed_by_line.get(l.id, 0), 2), "status": l.status})
    totals = {k: round(sum(x[k] for x in out_lines), 2) for k in ("ordered_value", "accepted_value", "billed", "paid", "owed")}
    rejected_any = any(x["rejected"] > EPS for x in out_lines)
    if po.status == "draft":
        state = "awaiting_approval"
    elif po.status == "cancelled":
        state = "cancelled"
    elif po.status == "approved":
        state = "awaiting_delivery"
    elif po.status == "partially_received":
        state = "partly_delivered"
    elif po.status == "closed":
        state = "closed_short"  # what came is billed; the totals say what is still owed
    else:
        state = "delivered_awaiting_payment" if totals["owed"] > 0.004 else "complete"
    return {"purchase_order_id": po.id, "po_no": po.po_no, "currency": po.currency, "status": po.status, "state": state, "lines": out_lines,
            "totals": totals, "rejections": rejected_any, "problems": problems,
            "receipts": [receipt_dict(db, r) for r in db.scalars(select(prm.GoodsReceipt).where(prm.GoodsReceipt.purchase_order_id == po.id)
                                                                .order_by(prm.GoodsReceipt.received_at))]}


# ------------------------------------------------------------- views
def order_dict(db: Session, po: prm.PurchaseOrder) -> dict:
    s = db.get(models.Supplier, po.supplier_id)
    done = _received(db, [l.id for l in po.lines])
    req = db.get(prm.PurchaseRequisition, po.requisition_id) if po.requisition_id else None
    lines = []
    for l in po.lines:
        product = db.get(fm.FeedProduct, l.feed_product_id) if l.feed_product_id else None
        r, a, j = done[l.id]
        lines.append({"id": l.id, "line_no": l.line_no, "inventory_item_id": l.inventory_item_id, "feed_product_id": l.feed_product_id,
                      "name": product.name if product else None, "ordered_quantity": l.ordered_quantity, "unit": l.uom_code, "unit_price": l.unit_price,
                      "line_total": l.line_total, "received_quantity": r, "accepted_quantity": a, "rejected_quantity": j,
                      "remaining_quantity": max(l.ordered_quantity - r, 0), "status": l.status})
    return {"id": po.id, "po_no": po.po_no, "supplier_id": po.supplier_id, "supplier_name": s.name if s else None, "requisition_id": po.requisition_id,
            "requisition_no": req.requisition_no if req else None, "order_date": ensure_utc(po.order_date).isoformat(),
            "expected_delivery_date": ensure_utc(po.expected_delivery_date).isoformat() if po.expected_delivery_date else None,
            "currency": po.currency, "exchange_rate": po.exchange_rate, "payment_terms": po.payment_terms, "status": po.status,
            "subtotal": po.subtotal, "total_amount": po.total_amount, "notes": po.notes, "created_by": po.created_by, "approved_by": po.approved_by,
            "approved_at": ensure_utc(po.approved_at).isoformat() if po.approved_at else None, "closed_reason": po.closed_reason, "lines": lines}


def receipt_dict(db: Session, r: prm.GoodsReceipt) -> dict:
    lines = []
    for rl in r.lines:
        lot = db.get(fm.FeedLot, rl.feed_lot_id) if rl.feed_lot_id else None
        lines.append({"line_no": rl.line_no, "purchase_order_line_id": rl.purchase_order_line_id, "received_quantity": rl.received_quantity,
                      "accepted_quantity": rl.accepted_quantity, "rejected_quantity": rl.rejected_quantity, "unit": rl.uom_code,
                      "feed_lot_id": rl.feed_lot_id, "lot_code": lot.lot_code if lot else None, "lot_status": lot.status if lot else None,
                      "expense_id": rl.expense_id, "quality_grade": rl.quality_grade, "rejection_reason": rl.rejection_reason})
    return {"id": r.id, "receipt_no": r.receipt_no, "purchase_order_id": r.purchase_order_id, "supplier_id": r.supplier_id,
            "received_at": ensure_utc(r.received_at).isoformat(), "received_by": r.received_by, "delivery_note_no": r.delivery_note_no,
            "status": r.status, "lines": lines}


def origin_of_lot(db: Session, lot_id: str) -> dict | None:
    """The order and the delivery a lot came on, for its trace."""
    row = db.execute(select(prm.GoodsReceiptLine, prm.GoodsReceipt).join(prm.GoodsReceipt).where(prm.GoodsReceiptLine.feed_lot_id == lot_id)).first()
    if row is None:
        return None
    rl, receipt = row
    po = db.get(prm.PurchaseOrder, receipt.purchase_order_id) if receipt.purchase_order_id else None
    s = db.get(models.Supplier, receipt.supplier_id)
    return {"po_no": po.po_no if po else None, "purchase_order_id": po.id if po else None, "receipt_no": receipt.receipt_no,
            "goods_receipt_id": receipt.id, "supplier_id": receipt.supplier_id, "supplier_name": s.name if s else None,
            "delivery_note_no": receipt.delivery_note_no, "received_at": ensure_utc(receipt.received_at).isoformat()}
