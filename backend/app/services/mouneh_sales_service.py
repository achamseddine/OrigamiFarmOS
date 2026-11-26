"""Selling Mouneh: the jars, the revenue and the cash, each recorded once
(v0.8.8, audit 2026-11-25 I-8).

A sale in the Mouneh shop is three accounting events:

* inventory movement — the finished-goods stock it came from and the Mouneh
  sale line (quantity, price, discount, what a jar cost to make);
* revenue — one canonical `sales` row (product_type "mouneh", activity
  "mouneh") linked from the line (`mouneh_sale_lines.sale_id`). Sales &
  Finance, the owed list, the reports and profit and loss read it; nothing
  is kept on the side;
* cash — paid at the till (the sale is paid), owed (pending, the buyer
  named), or paid in part (a receipt toward the sale,
  `customer_payments.sale_id`); the rest is received in Sales & Finance.

Cancelling puts the jars back on the shelf and undoes the revenue with a
negative row; what was received is refunded (finance_service.reverse_sale).
A jar sold in the farm shop during a visit is in that purchase's sale
(product_type "visitor_retail"): its line points to that sale and is never
posted again.

Sales recorded before v0.8.8 have no sale in the books. `reconcile` lists
them (a dry run) and posts each once, on the day it was sold (apply),
linking farm-shop jars to their purchase instead. It never changes a line's
figures and never posts a line twice: the link is taken with a conditional
update, so two runs at once cannot both post the same line.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.core import duplicates
from app.core import permissions as perms
from app.core.record_time import not_in_future
from app.domain import finance_models as fin
from app.domain import models
from app.domain import mouneh_models as mo
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event
from app.services import finance_service as finance
from app.services.finance_service import FinanceError

PAYMENT_STATUSES = ("paid", "pending", "partial")
# A repeated sale is looked for over this window around the sale's time.
SALE_WINDOW = timedelta(minutes=5)
# The farm shop writes a purchase and its jars in one request.
FARM_SHOP_WINDOW = timedelta(seconds=5)


def _mouneh_event(db: Session, line: mo.MounehSaleLine, event_type: str, payload: dict, user_id: str) -> None:
    db.add(mo.MounehEvent(id=new_id(), farm_id=line.farm_id, entity_type="mouneh_sale_line", entity_id=line.id, event_type=event_type,
                          payload_json=payload, created_by=user_id, created_at=now()))


def _book(db: Session, line: mo.MounehSaleLine, user_id: str, *, payment_status: str, buyer_name: str | None,
          original: tuple[float | None, str | None, float | None] = (None, None, None), reference: str | None = None,
          notes: str | None = None) -> models.Sale:
    """The canonical sale carrying [line]'s revenue, on the day it was sold."""
    product = db.get(mo.MounehProduct, line.product_id)
    at = ensure_utc(line.sold_at)
    amount = round(line.revenue, 2)
    sale = models.Sale(
        id=new_id(), farm_id=line.farm_id, customer_id=line.customer_id, product_type="mouneh",
        product_label=(product.name if product else "Mouneh")[:100], quantity=line.quantity, unit=product.output_unit if product else None,
        amount=amount, currency=fin.BASE_CURRENCY, payment_status=payment_status, sold_at=at, unit_price=round(amount / line.quantity, 4),
        buyer_name=buyer_name, reference=(reference or "").strip()[:120] or None, notes=(notes or "").strip() or None, status="recorded",
        paid_at=at if payment_status == "paid" else None, original_amount=original[0], original_currency=original[1],
        exchange_rate=original[2], activity="mouneh", recorded_by=user_id, created_at=now())
    db.add(sale)
    db.flush()
    return sale


def _log_sale(db: Session, line: mo.MounehSaleLine, sale: models.Sale, user_id: str, *, action: str, summary: str, metadata: dict) -> None:
    write_audit_log(db, farm_id=line.farm_id, user_id=user_id, action=action, entity_type="sale", entity_id=sale.id,
                    module_code=perms.MOUNEH_INVENTORY, summary=summary[:500], changes={"status": {"from": None, "to": "recorded"}},
                    metadata={"mouneh_sale_id": line.id, "cost_of_goods": round(line.quantity * line.cost_per_unit, 4), **metadata})
    write_event(db, farm_id=line.farm_id, entity_type="sale", entity_id=sale.id, event_type="sale_recorded",
                payload={"product_type": "mouneh", "label": sale.product_label, "quantity": sale.quantity, "unit": sale.unit,
                         "amount": sale.amount, "original_amount": sale.original_amount, "original_currency": sale.original_currency,
                         "exchange_rate": sale.exchange_rate, "buyer": sale.buyer_name, "payment_status": sale.payment_status,
                         "mouneh_sale_id": line.id, **metadata}, created_by=user_id)


# ------------------------------------------------------------------ selling
def sell(db: Session, user: models.User, *, product_id: str, finished_goods_stock_id: str | None, quantity: float, unit_price: float,
         discount: float, customer_id: str | None, buyer_name: str | None, channel: str, sold_at: datetime | None, payment_status: str,
         amount_paid: float | None, currency: str | None, exchange_rate: float | None, reference: str | None, notes: str | None,
         confirm_duplicate: bool) -> mo.MounehSaleLine:
    """Jars out of the shop, their revenue in the books, and what was paid."""
    farm_id = user.farm_id
    product = db.get(mo.MounehProduct, product_id)
    if product is None or product.farm_id != farm_id:
        raise FinanceError("Mouneh product not found", 404)
    if payment_status not in PAYMENT_STATUSES:
        raise FinanceError(f"payment_status must be one of {list(PAYMENT_STATUSES)}")
    at = not_in_future(sold_at, "A sale") or now()
    if finished_goods_stock_id:
        stock = db.get(mo.FinishedGoodsStock, finished_goods_stock_id)
        if stock is None or stock.farm_id != farm_id or stock.product_id != product.id:
            raise FinanceError("Finished goods stock not found for this product", 404)
    else:
        # The oldest expiry first (sell through the oldest jars).
        stock = db.scalars(select(mo.FinishedGoodsStock).where(
            mo.FinishedGoodsStock.farm_id == farm_id, mo.FinishedGoodsStock.product_id == product.id, mo.FinishedGoodsStock.quantity_available > 0)
            .order_by(mo.FinishedGoodsStock.expiry_date.asc().nulls_last())).first()
        if stock is None:
            raise FinanceError(f"No available stock for {product.name}")
    if quantity > stock.quantity_available:
        raise FinanceError(f"Only {stock.quantity_available:g} units available, cannot sell {quantity:g}")
    total = quantity * unit_price - discount
    if total <= 0:
        raise FinanceError("The discount is the whole sale: a sale for nothing is not a sale.")
    amount, original, original_cur, rate = finance.to_base(db, farm_id, total, currency, exchange_rate, at)
    to_usd = (lambda v: round(v / rate, 4)) if original_cur else (lambda v: v)
    cust_id, name = finance._customer(db, farm_id, customer_id, buyer_name)
    if payment_status != "paid" and not cust_id:
        raise FinanceError("Say who owes it: name the buyer.")
    paid_now = 0.0
    if payment_status == "partial":
        if amount_paid is None or amount_paid <= 0:
            raise FinanceError("Say how much was paid now.")
        paid_now = round(to_usd(amount_paid), 2)
        if paid_now >= amount - 0.005:
            raise FinanceError("That is the whole sale: record it as paid.")

    # The same sale typed in twice (a second tablet, a repeated tap after the
    # first went through). Two customers buying the same jar minutes apart is
    # real, so it is asked, not refused outright.
    lo, hi = duplicates.near(at, SALE_WINDOW)
    customer = mo.MounehSaleLine.customer_id
    twin = db.scalars(select(mo.MounehSaleLine).where(
        mo.MounehSaleLine.farm_id == farm_id, mo.MounehSaleLine.product_id == product.id, mo.MounehSaleLine.quantity == quantity,
        mo.MounehSaleLine.unit_price == to_usd(unit_price), mo.MounehSaleLine.status == "recorded",
        customer.is_(None) if cust_id is None else customer == cust_id, mo.MounehSaleLine.sold_at.between(lo, hi))).first()
    duplicates.guard(twin, f"{quantity:g} × {product.name} at {unit_price:g} was sold a few minutes ago.", confirm=confirm_duplicate)

    line = mo.MounehSaleLine(
        id=new_id(), farm_id=farm_id, product_id=product.id, batch_id=stock.batch_id, finished_goods_stock_id=stock.id, quantity=quantity,
        unit_price=to_usd(unit_price), discount=to_usd(discount), customer_id=cust_id, channel=channel, cost_per_unit=stock.unit_cost,
        revenue=amount, margin=round(amount - quantity * stock.unit_cost, 4), sold_at=at, sold_by=user.id, status="recorded")
    sale = _book(db, line, user.id, payment_status="partial" if paid_now else payment_status, buyer_name=name,
                 original=(original, original_cur, rate), reference=reference, notes=notes)
    line.sale_id = sale.id
    db.add(line)
    stock.quantity_available -= quantity
    stock.quantity_sold += quantity
    db.flush()
    if paid_now:
        db.add(fin.CustomerPayment(
            id=new_id(), farm_id=farm_id, customer_id=cust_id, buyer_name=name, paid_at=at, sales_count=1, amount_due=amount,
            amount_received=paid_now, original_amount=round(amount_paid, 2) if original_cur else None, original_currency=original_cur,
            exchange_rate=rate, sale_id=sale.id, notes="Paid at the Mouneh shop", recorded_by=user.id, created_at=now()))
    money = f"{original:,.0f} {original_cur} ({amount:g} {fin.BASE_CURRENCY})" if original_cur else f"{amount:g} {fin.BASE_CURRENCY}"
    _log_sale(db, line, sale, user.id, action="sale_recorded",
              summary=(f"Sold {quantity:g} × {product.name} for {money}" + (f" to {name}" if name else "")
                       + (f" ({paid_now:g} paid, {amount - paid_now:g} owed)" if paid_now else f" ({payment_status})")),
              metadata={"paid_now": paid_now})
    _mouneh_event(db, line, "sale_recorded", {"product_id": product.id, "quantity": quantity, "revenue": amount, "sale_id": sale.id,
                                              "payment_status": sale.payment_status}, user.id)
    if twin is not None:
        _mouneh_event(db, line, "duplicate_confirmed", {"record": "sale", "resembles": twin.id}, user.id)
    return line


def post_line(db: Session, line: mo.MounehSaleLine, user_id: str, *, payment_status: str = "paid",
              reconciliation: bool = False) -> models.Sale | None:
    """Post [line]'s revenue to the books as its own sale, on the day it was
    sold — or None when the line is in the books already (posted meanwhile:
    the link is taken only if it is still free)."""
    if line.sale_id is not None:
        return None
    customer = db.get(models.Customer, line.customer_id) if line.customer_id else None
    day = f"{ensure_utc(line.sold_at):%d/%m/%Y}"
    sale = _book(db, line, user_id, payment_status=payment_status, buyer_name=customer.name if customer else None,
                 notes=f"Mouneh sale of {day} posted to the books by the reconciliation" if reconciliation else None)
    taken = db.execute(update(mo.MounehSaleLine).where(mo.MounehSaleLine.id == line.id, mo.MounehSaleLine.sale_id.is_(None))
                       .values(sale_id=sale.id).execution_options(synchronize_session=False))
    db.expire(line, ["sale_id"])
    if taken.rowcount != 1:
        db.delete(sale)
        db.flush()
        return None
    _log_sale(db, line, sale, user_id, action="mouneh_sale_posted",
              summary=f"Mouneh sale of {day} posted to the books: {line.quantity:g} × {sale.product_label} for {sale.amount:g} {fin.BASE_CURRENCY}"
                      f" ({payment_status})", metadata={"reconciliation": reconciliation})
    return sale


# --------------------------------------------------------------- cancelling
def cancel(db: Session, line: mo.MounehSaleLine, user: models.User, *, reason: str) -> mo.MounehSaleLine:
    """A sale recorded by mistake, or brought back: it stays on file, marked
    cancelled with the reason; its jars are back on the shelf, its revenue is
    undone and what was received is refunded."""
    if line.status == "cancelled":
        raise FinanceError("This sale is already cancelled.", 409)
    if not reason or not reason.strip():
        raise FinanceError("Say why the sale is cancelled.")
    sale = db.get(models.Sale, line.sale_id) if line.sale_id else None
    if sale is not None and sale.product_type != "mouneh":
        raise FinanceError("These jars were sold in the farm shop during a visit: cancel the purchase in Farm visits.", 409)
    stock = db.get(mo.FinishedGoodsStock, line.finished_goods_stock_id)
    if stock is not None:
        stock.quantity_available += line.quantity
        stock.quantity_sold -= line.quantity
    line.status, line.cancel_reason, line.cancelled_at, line.cancelled_by = "cancelled", reason.strip(), now(), user.id
    reversal, refund = (None, 0.0)
    if sale is not None and sale.status == "recorded":
        reversal, refund = finance.reverse_sale(db, sale, user, reason=reason)
    db.flush()
    meta = {"reason": reason.strip(), "sale_id": line.sale_id, "reversal_sale_id": reversal.id if reversal else None, "refunded": refund,
            "back_on_shelf": line.quantity}
    write_audit_log(db, farm_id=line.farm_id, user_id=user.id, action="mouneh_sale_cancelled", entity_type="mouneh_sale_line", entity_id=line.id,
                    module_code=perms.MOUNEH_INVENTORY,
                    summary=(f"Mouneh sale of {line.quantity:g} ({line.revenue:g} {fin.BASE_CURRENCY}) cancelled: {reason.strip()}"
                             + (f"; {refund:g} {fin.BASE_CURRENCY} refunded" if refund else ""))[:500],
                    changes={"status": {"from": "recorded", "to": "cancelled"}}, metadata=meta)
    if sale is not None:
        write_event(db, farm_id=line.farm_id, entity_type="sale", entity_id=sale.id, event_type="sale_cancelled",
                    payload={"amount": sale.amount, **meta}, created_by=user.id)
    _mouneh_event(db, line, "sale_cancelled", meta, user.id)
    return line


# --------------------------------------------------------------- reading
def line_rows(db: Session, lines) -> list[dict]:
    """Mouneh sale lines with what the books say about each: its sale, what
    was paid, what is owed."""
    lines = list(lines)
    sale_ids = [line.sale_id for line in lines if line.sale_id]
    sales = {s.id: s for s in db.scalars(select(models.Sale).where(models.Sale.id.in_(sale_ids)))} if sale_ids else {}
    got = finance.received(db, [s.id for s in sales.values() if s.payment_status == "partial"])
    customer_ids = {line.customer_id for line in lines if line.customer_id}
    names = {c.id: c.name for c in db.scalars(select(models.Customer).where(models.Customer.id.in_(customer_ids)))} if customer_ids else {}
    return [_line_dict(line, sales.get(line.sale_id or ""), got, names) for line in lines]


def _line_dict(line: mo.MounehSaleLine, sale: models.Sale | None, got: dict[str, float], names: dict[str, str]) -> dict:
    farm_shop = sale is not None and sale.product_type != "mouneh"
    own = sale if sale is not None and not farm_shop else None
    if line.status == "cancelled":
        paid, due = 0.0, 0.0
    elif farm_shop:
        paid = round(line.revenue, 2) if sale.payment_status == "paid" else 0.0
        due = round(line.revenue, 2) - paid
    else:
        paid = finance.paid_so_far(own, got) if own else 0.0
        due = finance.balance_due(own, got) if own else 0.0
    return {
        "id": line.id, "farm_id": line.farm_id, "product_id": line.product_id, "batch_id": line.batch_id,
        "finished_goods_stock_id": line.finished_goods_stock_id, "quantity": line.quantity, "unit_price": line.unit_price,
        "discount": line.discount, "customer_id": line.customer_id,
        "buyer_name": (own.buyer_name if own else None) or names.get(line.customer_id or ""), "channel": line.channel,
        "cost_per_unit": line.cost_per_unit, "revenue": line.revenue, "margin": line.margin,
        "cost_of_goods": round(line.quantity * line.cost_per_unit, 4), "sold_at": line.sold_at, "sold_by": line.sold_by,
        "status": line.status, "cancel_reason": line.cancel_reason, "cancelled_at": line.cancelled_at,
        "sale_id": line.sale_id, "farm_shop": farm_shop, "payment_status": sale.payment_status if sale else None,
        "amount_paid": paid, "balance_due": due, "currency": fin.BASE_CURRENCY,
        "original_amount": own.original_amount if own else None, "original_currency": own.original_currency if own else None,
        "exchange_rate": own.exchange_rate if own else None,
    }


# ------------------------------------------------------ past sales (I-8)
def reconcile(db: Session, user: models.User, *, apply: bool, payment_status: str = "paid") -> dict:
    """Mouneh sales on record that are not in the books: what posting them
    would add (dry run), or post them (apply). A jar of a farm-shop purchase
    — written in the same moment as the purchase, retail, no discount, no
    customer, within what the purchase came to — is linked to it instead.
    A line that fits more than one purchase, or more than a purchase came to,
    is left for a look. Running it again finds nothing more to do."""
    if payment_status not in ("paid", "pending"):
        raise FinanceError("Past sales are posted as paid, or as still owed (pending).")
    farm_id = user.farm_id
    from app.domain import visits_models as vm

    lines = db.scalars(select(mo.MounehSaleLine).where(mo.MounehSaleLine.farm_id == farm_id, mo.MounehSaleLine.sale_id.is_(None),
                                                       mo.MounehSaleLine.status == "recorded").order_by(mo.MounehSaleLine.sold_at)).all()
    in_books = db.scalars(select(mo.MounehSaleLine).where(mo.MounehSaleLine.farm_id == farm_id, mo.MounehSaleLine.sale_id.is_not(None))).all()
    names = {p.id: p.name for p in db.scalars(select(mo.MounehProduct).where(mo.MounehProduct.farm_id == farm_id))}
    shop_sales = {s.id: s for s in db.scalars(select(models.Sale).join(vm.VisitRetailSale, vm.VisitRetailSale.sale_id == models.Sale.id)
                                              .where(models.Sale.farm_id == farm_id, models.Sale.status == "recorded"))}
    used = {sid: sum(line.revenue for line in in_books if line.sale_id == sid) for sid in shop_sales}

    def item(line: mo.MounehSaleLine) -> dict:
        return {"mouneh_sale_id": line.id, "sold_at": line.sold_at, "product_id": line.product_id, "product_name": names.get(line.product_id),
                "quantity": line.quantity, "amount": round(line.revenue, 2), "cost_of_goods": round(line.quantity * line.cost_per_unit, 4)}

    to_post, review, candidates = [], [], {}
    for line in lines:
        shop_like = line.customer_id is None and not line.discount and line.channel == "retail"
        near = [s for s in shop_sales.values() if abs(ensure_utc(s.sold_at) - ensure_utc(line.sold_at)) <= FARM_SHOP_WINDOW] if shop_like else []
        if len(near) > 1:
            review.append((line, "written with more than one farm-shop purchase"))
        elif near:
            candidates.setdefault(near[0].id, []).append(line)
        else:
            to_post.append(line)
    farm_shop = []
    for sid, group in candidates.items():
        if used[sid] + sum(line.revenue for line in group) <= shop_sales[sid].amount + 0.01:
            farm_shop += [(line, sid) for line in group]
        else:
            review += [(line, "more than its farm-shop purchase came to") for line in group]

    out = {"dry_run": not apply, "payment_status": payment_status,
           "to_post": {"count": len(to_post), "amount": round(sum(round(line.revenue, 2) for line in to_post), 2),
                       "items": [item(line) for line in to_post]},
           "farm_shop": {"count": len(farm_shop), "items": [{**item(line), "sale_id": sid} for line, sid in farm_shop]},
           "already_in_books": len(in_books), "needs_review": [{**item(line), "problem": why} for line, why in review], "posted": []}
    if not apply:
        return out
    for line in to_post:
        sale = post_line(db, line, user.id, payment_status=payment_status, reconciliation=True)
        if sale is not None:
            out["posted"].append(sale.id)
    linked = 0
    for line, sid in farm_shop:
        taken = db.execute(update(mo.MounehSaleLine).where(mo.MounehSaleLine.id == line.id, mo.MounehSaleLine.sale_id.is_(None))
                           .values(sale_id=sid).execution_options(synchronize_session=False))
        db.expire(line, ["sale_id"])
        if taken.rowcount == 1:
            linked += 1
            write_audit_log(db, farm_id=farm_id, user_id=user.id, action="mouneh_sale_linked", entity_type="mouneh_sale_line", entity_id=line.id,
                            module_code=perms.MOUNEH_INVENTORY,
                            summary=f"Mouneh sale of {ensure_utc(line.sold_at):%d/%m/%Y} is in its farm-shop purchase already: linked, not posted"[:500],
                            changes={"sale_id": {"from": None, "to": sid}}, metadata={"reconciliation": True, "sale_id": sid})
    write_audit_log(db, farm_id=farm_id, user_id=user.id, action="mouneh_sales_reconciled", entity_type="farm", entity_id=farm_id,
                    module_code=perms.FINANCE,
                    summary=(f"Past Mouneh sales put in the books: {len(out['posted'])} posted ({out['to_post']['amount']:g} {fin.BASE_CURRENCY}, "
                             f"{payment_status}), {linked} farm-shop jar(s) linked, {len(review)} left for a look")[:500],
                    metadata={"posted": out["posted"], "linked": linked, "needs_review": [line.id for line, _ in review],
                              "payment_status": payment_status})
    return out
