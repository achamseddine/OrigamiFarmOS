"""Buying stock: what was accepted, what the supplier is owed, what was paid
(v0.8.9, audit 2026-11-25 I-9, I-14).

A delivery of feed or medicine is three facts, each recorded once:

* stock — the lot (feed_inventory_service / pharmacy_service): received,
  rejected and accepted quantities, its unit cost in USD; its value is what
  was accepted × the price (500 kg delivered, 20 kg rejected, at USD 0.50:
  USD 240);
* the supplier's bill — one `expenses` row linked to the lot
  (linked_entity_type "feed_lot" / "medicine_lot", unique): what the farm
  owes for what it accepted, in the currency of the invoice. It is an asset
  bought, never a cost in profit and loss: feed is a cost when it is fed,
  medicine when it is received (pharmacy policy, finance_service);
* cash — `supplier_payments`: each payment on its day (nothing for a
  delivery on credit), a supplier's refund, a credit note for goods
  returned (no cash). A row recorded by mistake is reversed by a negative
  row, never edited.

Deliveries recorded before this release have no bill; `reconcile` lists
them for the manager (link the expense that already paid for one, or say it
was paid on arrival or is still owed) and never pays on their behalf.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core import duplicates
from app.core import permissions as perms
from app.core.record_time import not_in_future
from app.domain import feed_models as fm
from app.domain import finance_models as fin
from app.domain import models
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event
from app.services import finance_service as finance
from app.services.finance_service import FinanceError

PAYMENT_TERMS = ("paid", "credit", "partial")
EPS = 0.005


def _pharmacy():
    from app.domain import pharmacy_models as pm
    return pm


def get_bill(db: Session, expense_id: str, farm_id: str, *, lock: bool = False) -> models.Expense:
    stmt = select(models.Expense).where(models.Expense.id == expense_id)
    if lock:
        # Locked and read afresh: a copy this session already holds is
        # refreshed, so no decision is taken on what another payment changed.
        stmt = stmt.with_for_update().execution_options(populate_existing=True)
    e = db.scalar(stmt)
    if e is None or e.farm_id != farm_id:
        raise FinanceError("Expense not found", 404)
    return e


def bill_of(db: Session, lot_type: str, lot_id: str) -> models.Expense | None:
    return db.scalar(select(models.Expense).where(models.Expense.linked_entity_type == lot_type, models.Expense.linked_entity_id == lot_id))


def _rate(db: Session, farm_id: str, currency: str, rate: float | None, at: datetime) -> float | None:
    """The rate of [currency] per USD on [at]: the one given, else the farm's for the day."""
    cur = (currency or fin.BASE_CURRENCY).upper()
    if cur == fin.BASE_CURRENCY:
        return None
    return finance.to_base(db, farm_id, 1.0, cur, rate, at)[3]


def unit_cost_in_usd(db: Session, farm_id: str, unit_cost: float | None, currency: str | None, rate: float | None, at: datetime) -> float | None:
    """A price per unit in USD, the stock's currency (an LBP price at the delivery's rate)."""
    if unit_cost is None:
        return None
    r = _rate(db, farm_id, currency or fin.BASE_CURRENCY, rate, at)
    return round(unit_cost / r, 4) if r else unit_cost


def check_terms(payment: str | None, paid_amount: float | None, unit_cost: float | None) -> str | None:
    """Refuse payment terms that cannot make a bill — before any stock moves."""
    if payment is None:
        return None
    if payment not in PAYMENT_TERMS:
        raise FinanceError(f"payment must be one of {list(PAYMENT_TERMS)}")
    if unit_cost is None:
        raise FinanceError("No price, no bill: give the price per unit, or record the delivery without payment terms.")
    if payment == "partial" and (paid_amount is None or paid_amount <= 0):
        raise FinanceError("Say how much was paid on delivery.")
    return payment


def bill_delivery(db: Session, *, farm_id: str, user_id: str, lot_type: str, lot, category: str, label: str, unit_price: float | None,
                  currency: str | None, exchange_rate: float | None, payment: str = "credit", paid_amount: float | None = None,
                  due_date: datetime | None = None, invoice_reference: str | None = None, supplier_id: str | None = None,
                  supplier_name: str | None = None, decided_by_reconciliation: bool = False) -> models.Expense | None:
    """The supplier's bill for what was accepted — one per delivery. Paid on
    delivery, on credit, or paid in part; nothing accepted, no bill."""
    accepted = lot.accepted_quantity or 0.0
    if accepted <= EPS or unit_price is None:
        return None
    existing = bill_of(db, lot_type, lot.id)
    if existing is not None:
        return existing
    at = ensure_utc(lot.received_at)
    total = round(accepted * unit_price, 2)
    usd, original, cur, rate = finance.to_base(db, farm_id, total, currency, exchange_rate, at)
    if payment == "partial" and (paid_amount or 0) >= total - EPS:
        raise FinanceError("That is the whole bill: record it as paid.")
    sup_id, sup_name = finance._supplier(db, farm_id, supplier_id, supplier_name)
    unit = getattr(lot, "unit", None) or ""
    bill = models.Expense(
        id=new_id(), farm_id=farm_id, supplier_id=sup_id, supplier_label=sup_name, category=category, amount=usd, currency=fin.BASE_CURRENCY,
        incurred_at=at, description=f"{label}: {accepted:g} {unit} accepted"[:300], payment_status="pending",
        due_date=ensure_utc(due_date) if due_date else None, reference=(invoice_reference or "").strip()[:120] or None,
        notes="Billed by the purchases reconciliation, as the manager decided" if decided_by_reconciliation else None, status="recorded",
        original_amount=original, original_currency=cur, exchange_rate=rate, linked_entity_type=lot_type, linked_entity_id=lot.id,
        activity=finance.ACTIVITY_OF_CATEGORY.get(category, "livestock"), recorded_by=user_id, created_at=now())
    db.add(bill)
    db.flush()
    money = f"{original:,.0f} {cur} ({usd:g} {fin.BASE_CURRENCY})" if cur else f"{usd:g} {fin.BASE_CURRENCY}"
    write_audit_log(db, farm_id=farm_id, user_id=user_id, action="purchase_billed", entity_type="expense", entity_id=bill.id,
                    module_code=perms.EXPENSES,
                    summary=f"{label}: {accepted:g} {unit} accepted, {money} owed to {sup_name or 'the supplier'} ({payment})"[:500],
                    changes={"status": {"from": None, "to": "recorded"}},
                    metadata={"lot_type": lot_type, "lot_id": lot.id, "accepted": accepted, "unit_price": unit_price,
                              "reconciliation": decided_by_reconciliation})
    write_event(db, farm_id=farm_id, entity_type="expense", entity_id=bill.id, event_type="purchase_billed",
                payload={"lot_type": lot_type, "lot_id": lot.id, "amount": usd, "original_amount": original, "original_currency": cur,
                         "exchange_rate": rate, "payment": payment, "supplier": sup_name}, created_by=user_id)
    pay_cur = cur or fin.BASE_CURRENCY
    if payment == "paid":
        _settle(db, bill, user_id=user_id, kind="payment", amount=original if cur else usd, currency=pay_cur, exchange_rate=rate, paid_at=at,
                reference=invoice_reference, notes="Paid on delivery")
    elif payment == "partial":
        _settle(db, bill, user_id=user_id, kind="payment", amount=paid_amount, currency=pay_cur, exchange_rate=rate, paid_at=at,
                reference=invoice_reference, notes="Paid on delivery")
    refresh_status(db, bill)
    return bill


def _settles(db: Session, bill: models.Expense, cash_usd: float, original: float | None, pay_cur: str | None, at: datetime) -> float:
    """What a payment takes off [bill], in the bill's own currency."""
    bill_cur = bill.original_currency
    if not bill_cur:
        return round(cash_usd, 2)
    if pay_cur == bill_cur and original is not None:
        return round(original, 2)
    # Dollars toward an LBP bill: at the farm's rate on the payment's day (else the bill's).
    r = finance.rate_on(db, bill.farm_id, bill_cur, finance._farm_day(db, bill.farm_id, at))
    return round(cash_usd * (r.rate_per_usd if r else (bill.exchange_rate or 1.0)), 2)


def _settle(db: Session, bill: models.Expense, *, user_id: str, kind: str, amount: float, currency: str | None, exchange_rate: float | None,
            paid_at: datetime, reference: str | None = None, notes: str | None = None) -> fin.SupplierPayment:
    usd, original, cur, rate = finance.to_base(db, bill.farm_id, amount, currency, exchange_rate, paid_at)
    settles = _settles(db, bill, usd, original, cur or fin.BASE_CURRENCY, paid_at)
    sign = -1 if kind == "refund" else 1
    row = fin.SupplierPayment(
        id=new_id(), farm_id=bill.farm_id, expense_id=bill.id, supplier_id=bill.supplier_id, kind=kind, paid_at=ensure_utc(paid_at),
        amount=sign * usd, settles=sign * settles, original_amount=sign * original if original is not None else None, original_currency=cur,
        exchange_rate=rate, status="recorded", reference=(reference or "").strip()[:120] or None, notes=(notes or "").strip() or None,
        recorded_by=user_id, created_at=now())
    db.add(row)
    db.flush()
    return row


def refresh_status(db: Session, bill: models.Expense) -> None:
    st = finance.settlement(db, [bill.id]).get(bill.id)
    if not st or not st["rows"]:
        return
    rest, _usd = finance.bill_balance(bill, st)
    last = db.scalar(select(fin.SupplierPayment.paid_at).where(fin.SupplierPayment.expense_id == bill.id, fin.SupplierPayment.kind != "credit")
                     .order_by(fin.SupplierPayment.paid_at.desc()).limit(1))
    if rest <= EPS:
        bill.payment_status, bill.paid_at = "paid", last or bill.paid_at or now()
    elif st["settled"] > EPS:
        bill.payment_status, bill.paid_at = "partial", None
    else:
        bill.payment_status, bill.paid_at = "pending", None


def pay_bill(db: Session, user: models.User, bill: models.Expense, *, amount: float, currency: str | None = None, exchange_rate: float | None = None,
             paid_at: datetime | None = None, reference: str | None = None, notes: str | None = None, kind: str = "payment",
             confirm_duplicate: bool = False) -> fin.SupplierPayment:
    """A payment toward a bill (in parts, in USD or LBP at the day's rate),
    or the supplier's refund of what was overpaid or returned."""
    if kind not in ("payment", "refund"):
        raise FinanceError("kind must be payment or refund")
    if bill.status != "recorded":
        raise FinanceError("A cancelled bill cannot be paid.", 409)
    if amount is None or amount <= 0:
        raise FinanceError("The amount must be more than zero.")
    when = not_in_future(paid_at, "A payment") or now()
    usd, original, cur, rate = finance.to_base(db, bill.farm_id, amount, currency, exchange_rate, when)
    settles = _settles(db, bill, usd, original, cur or fin.BASE_CURRENCY, when)
    st = finance.settlement(db, [bill.id]).get(bill.id)
    rest, rest_usd = finance.bill_balance(bill, st)
    shown = f"{rest:,.0f} {bill.original_currency}" if bill.original_currency else f"{rest:g} {fin.BASE_CURRENCY}"
    if kind == "payment" and settles > rest + EPS:
        raise FinanceError(f"That is more than is owed on this bill ({shown}).")
    if kind == "refund" and (rest >= -EPS or settles > -rest + EPS):
        raise FinanceError("There is nothing for the supplier to refund on this bill." if rest >= -EPS else
                           f"The supplier owes back {-rest:g} on this bill, not more.")
    lo, hi = duplicates.near(when)
    earlier = db.scalar(select(fin.SupplierPayment).where(
        fin.SupplierPayment.expense_id == bill.id, fin.SupplierPayment.kind == kind, fin.SupplierPayment.status == "recorded",
        fin.SupplierPayment.amount == (usd if kind == "payment" else -usd), fin.SupplierPayment.paid_at >= lo, fin.SupplierPayment.paid_at <= hi))
    match = duplicates.guard(earlier, f"A {kind} of {usd:g} {fin.BASE_CURRENCY} on this bill was already recorded within half an hour."
                             if earlier else "", confirm=confirm_duplicate)
    row = _settle(db, bill, user_id=user.id, kind=kind, amount=amount, currency=currency, exchange_rate=exchange_rate, paid_at=when,
                  reference=reference, notes=notes)
    before = bill.payment_status
    refresh_status(db, bill)
    duplicates.log_confirmed(db, farm_id=bill.farm_id, entity_type="supplier_payment", entity_id=row.id, match_id=match.id if match else None,
                             what=f"supplier_payment:{row.id}", user_id=user.id)
    money = f"{original:,.0f} {cur} ({usd:g} {fin.BASE_CURRENCY})" if cur else f"{usd:g} {fin.BASE_CURRENCY}"
    write_audit_log(db, farm_id=bill.farm_id, user_id=user.id, action=f"supplier_{kind}_recorded", entity_type="expense", entity_id=bill.id,
                    module_code=perms.EXPENSES,
                    summary=(f"{'Paid' if kind == 'payment' else 'Refund from'} {bill.supplier_label or 'the supplier'}: {money} "
                             f"({bill.description or bill.category})")[:500],
                    changes={"payment_status": {"from": before, "to": bill.payment_status}}, metadata={"supplier_payment_id": row.id})
    write_event(db, farm_id=bill.farm_id, entity_type="expense", entity_id=bill.id, event_type=f"supplier_{kind}_recorded",
                payload={"supplier_payment_id": row.id, "amount": row.amount, "settles": row.settles, "original_amount": row.original_amount,
                         "original_currency": cur, "exchange_rate": rate}, created_by=user.id)
    return row


def credit_return(db: Session, *, user_id: str, bill: models.Expense, value: float, reason: str, reference: str | None = None) -> fin.SupplierPayment:
    """A credit note for goods returned: [value] off the bill, in its own currency; no cash moves."""
    row = fin.SupplierPayment(
        id=new_id(), farm_id=bill.farm_id, expense_id=bill.id, supplier_id=bill.supplier_id, kind="credit", paid_at=now(), amount=0.0,
        settles=round(value, 2), status="recorded", reference=(reference or "").strip()[:120] or None, notes=reason.strip()[:500],
        recorded_by=user_id, created_at=now())
    db.add(row)
    db.flush()
    refresh_status(db, bill)
    write_audit_log(db, farm_id=bill.farm_id, user_id=user_id, action="supplier_credit_recorded", entity_type="expense", entity_id=bill.id,
                    module_code=perms.EXPENSES, summary=f"Credit {value:g} {bill.original_currency or fin.BASE_CURRENCY} for goods returned: {reason}"[:500],
                    metadata={"supplier_payment_id": row.id})
    write_event(db, farm_id=bill.farm_id, entity_type="expense", entity_id=bill.id, event_type="supplier_credit_recorded",
                payload={"supplier_payment_id": row.id, "settles": row.settles, "reason": reason}, created_by=user_id)
    return row


def reverse_payment(db: Session, user: models.User, row: fin.SupplierPayment, *, reason: str) -> fin.SupplierPayment:
    """A payment, refund or credit recorded by mistake: it stays on file and
    is undone by a negative row."""
    # Under the bill's lock, read the payment afresh: another reversal of it
    # may have been committed while this one waited for the lock.
    get_bill(db, row.expense_id, row.farm_id, lock=True)
    db.refresh(row)
    if row.status == "reversal":
        raise FinanceError("This row undoes another; it is not reversed itself.", 409)
    if row.status == "reversed":
        raise FinanceError("This payment is already reversed.", 409)
    if not reason or not reason.strip():
        raise FinanceError("Say why it is reversed.")
    undo = fin.SupplierPayment(
        id=new_id(), farm_id=row.farm_id, expense_id=row.expense_id, supplier_id=row.supplier_id, kind=row.kind, paid_at=now(),
        amount=-row.amount, settles=-row.settles, original_amount=-row.original_amount if row.original_amount is not None else None,
        original_currency=row.original_currency, exchange_rate=row.exchange_rate, status="reversal", reversal_of_id=row.id,
        notes=f"Reversed: {reason.strip()}"[:500], recorded_by=user.id, created_at=now())
    db.add(undo)
    row.status = "reversed"
    db.flush()
    bill = db.get(models.Expense, row.expense_id)
    refresh_status(db, bill)
    write_audit_log(db, farm_id=row.farm_id, user_id=user.id, action="supplier_payment_reversed", entity_type="supplier_payment", entity_id=row.id,
                    module_code=perms.EXPENSES, summary=f"{row.kind.capitalize()} of {row.amount:g} {fin.BASE_CURRENCY} reversed: {reason.strip()}"[:500],
                    changes={"status": {"from": "recorded", "to": "reversed"}}, metadata={"reversal_id": undo.id, "expense_id": row.expense_id})
    write_event(db, farm_id=row.farm_id, entity_type="expense", entity_id=row.expense_id, event_type="supplier_payment_reversed",
                payload={"supplier_payment_id": row.id, "reversal_id": undo.id, "reason": reason.strip()}, created_by=user.id)
    return undo


def payment_dict(p: fin.SupplierPayment) -> dict:
    return {"id": p.id, "expense_id": p.expense_id, "kind": p.kind, "paid_at": p.paid_at, "amount": p.amount, "settles": p.settles,
            "original_amount": p.original_amount, "original_currency": p.original_currency, "exchange_rate": p.exchange_rate,
            "status": p.status, "reversal_of_id": p.reversal_of_id, "reference": p.reference, "notes": p.notes, "recorded_by": p.recorded_by}


def payments_of(db: Session, bill: models.Expense) -> list[dict]:
    rows = db.scalars(select(fin.SupplierPayment).where(fin.SupplierPayment.expense_id == bill.id).order_by(fin.SupplierPayment.paid_at)).all()
    return [payment_dict(p) for p in rows]


def bill_summary(db: Session, bill: models.Expense | None) -> dict | None:
    if bill is None:
        return None
    return finance.expense_rows(db, [bill])[0]


# ----------------------------------------------- deliveries before v0.8.9
def _unbilled(db: Session, farm_id: str) -> list[tuple[str, object, str, str]]:
    """(lot type, lot, category, label) for each priced purchase with stock accepted and no bill."""
    pm = _pharmacy()
    billed = {(t, i) for t, i in db.execute(select(models.Expense.linked_entity_type, models.Expense.linked_entity_id).where(
        models.Expense.farm_id == farm_id, models.Expense.linked_entity_type.in_(finance.STOCK_BILLS)))}
    out = []
    for lot, name in db.execute(select(fm.FeedLot, fm.FeedProduct.name).join(fm.FeedProduct, fm.FeedProduct.id == fm.FeedLot.feed_product_id).where(
            fm.FeedLot.farm_id == farm_id, fm.FeedLot.source_type == "purchased", fm.FeedLot.unit_cost.is_not(None),
            fm.FeedLot.accepted_quantity > EPS)):
        if ("feed_lot", lot.id) not in billed:
            out.append(("feed_lot", lot, "feed", name))
    for lot in db.scalars(select(pm.InventoryLot).where(pm.InventoryLot.farm_id == farm_id, pm.InventoryLot.source_type == "purchased",
                                                        pm.InventoryLot.unit_cost.is_not(None), pm.InventoryLot.accepted_quantity > EPS)):
        if ("medicine_lot", lot.id) not in billed:
            item = db.get(models.InventoryItem, lot.inventory_item_id)
            out.append(("medicine_lot", lot, "medicine", item.name if item else "Medicine"))
    return out


def _candidates(db: Session, farm_id: str, lot, category: str, value: float, received_value: float) -> list[models.Expense]:
    """Expenses recorded on their own that may have paid for this delivery:
    the same kind, within a week, for its accepted (or full) value."""
    at = ensure_utc(lot.received_at)
    rows = db.scalars(select(models.Expense).where(
        models.Expense.farm_id == farm_id, models.Expense.status == "recorded", models.Expense.linked_entity_type.is_(None),
        models.Expense.category.in_((category, "veterinary") if category == "medicine" else (category,)),
        models.Expense.incurred_at >= at - timedelta(days=7), models.Expense.incurred_at <= at + timedelta(days=7))).all()
    supplier = (getattr(lot, "supplier_label", None) or "").strip().lower()
    out = []
    for e in rows:
        near = any(abs(e.amount - v) <= max(0.01, 0.01 * v) for v in (value, received_value) if v)
        same = not supplier or not e.supplier_label or e.supplier_label.strip().lower() == supplier
        if near and same:
            out.append(e)
    return out


def reconcile(db: Session, user: models.User, *, decisions: list[dict] | None = None) -> dict:
    """Priced deliveries with no bill (recorded before v0.8.9): the expense
    that may already have paid for each (a likely double count), or nothing
    to go on — then the manager decides. Applying [decisions] links the
    expense, or bills the delivery as paid on arrival or still owed; nothing
    already recorded is rewritten and nothing is paid on anyone's behalf."""
    farm_id = user.farm_id
    applied = []
    if decisions:
        lots = {lot.id: (t, lot, cat, label) for t, lot, cat, label in _unbilled(db, farm_id)}
        for d in decisions:
            found = lots.get(d.get("lot_id") or "")
            if found is None:
                continue  # billed already (a second run), or not this farm's
            lot_type, lot, category, label = found
            action = d.get("action")
            if action == "link":
                e = db.get(models.Expense, d.get("expense_id") or "")
                if e is None or e.farm_id != farm_id or e.linked_entity_type is not None or e.status != "recorded":
                    raise FinanceError("That expense cannot be linked: it is not this farm's, or already linked.", 409)
                e.linked_entity_type, e.linked_entity_id = lot_type, lot.id
                write_audit_log(db, farm_id=farm_id, user_id=user.id, action="purchase_bill_linked", entity_type="expense", entity_id=e.id,
                                module_code=perms.EXPENSES, summary=f"{e.description or e.category} is the bill of the {label} delivery of "
                                                                    f"{ensure_utc(lot.received_at):%d/%m/%Y}: stock, not a second cost"[:500],
                                changes={"linked_entity_id": {"from": None, "to": lot.id}}, metadata={"lot_type": lot_type, "reconciliation": True})
            elif action in ("paid_on_receipt", "on_credit"):
                bill_delivery(db, farm_id=farm_id, user_id=user.id, lot_type=lot_type, lot=lot, category=category, label=label,
                              unit_price=lot.unit_cost, currency=None, exchange_rate=None,
                              payment="paid" if action == "paid_on_receipt" else "credit", decided_by_reconciliation=True)
            else:
                raise FinanceError("action must be link, paid_on_receipt or on_credit")
            applied.append({"lot_id": lot.id, "action": action})
            del lots[lot.id]
        db.flush()
    items = []
    for lot_type, lot, category, label in _unbilled(db, farm_id):
        value = round((lot.accepted_quantity or 0) * lot.unit_cost, 2)
        received_value = round((lot.received_quantity or 0) * lot.unit_cost, 2)
        cands = _candidates(db, farm_id, lot, category, value, received_value)
        items.append({"lot_id": lot.id, "lot_type": lot_type, "product": label, "received_at": lot.received_at,
                      "supplier": getattr(lot, "supplier_label", None), "accepted_quantity": lot.accepted_quantity,
                      "rejected_quantity": getattr(lot, "rejected_quantity", 0), "unit_cost": lot.unit_cost, "accepted_value": value,
                      "received_value": received_value, "proposal": "link" if len(cands) == 1 else "decide",
                      "expense_id": cands[0].id if len(cands) == 1 else None,
                      "candidates": [{"expense_id": e.id, "amount": e.amount, "incurred_at": e.incurred_at, "supplier": e.supplier_label,
                                      "payment_status": e.payment_status} for e in cands]})
    if decisions:
        write_audit_log(db, farm_id=farm_id, user_id=user.id, action="purchases_reconciled", entity_type="farm", entity_id=farm_id,
                        module_code=perms.FINANCE, summary=f"Deliveries put in the books: {len(applied)} decided, {len(items)} still to decide"[:500],
                        metadata={"applied": applied})
    return {"dry_run": not decisions, "items": items, "applied": applied}


def bill_seeded_deliveries(db: Session, farm_id: str, user_id: str) -> int:
    """The demo farm's priced deliveries, billed as paid on arrival (seed data only)."""
    n = 0
    for lot_type, lot, category, label in _unbilled(db, farm_id):
        if bill_delivery(db, farm_id=farm_id, user_id=user_id, lot_type=lot_type, lot=lot, category=category, label=label,
                         unit_price=lot.unit_cost, currency=None, exchange_rate=None, payment="paid") is not None:
            n += 1
    return n
