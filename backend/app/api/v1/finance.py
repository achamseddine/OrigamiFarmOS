"""Origami's financials (v0.8.0): any sale, expenses and bills, who owes
what, profit and loss, and the USD / LBP exchange rate.

Who may do what (owners and managers hold everything):
- record a sale, mark one paid: Sales or Finance *create*;
- cancel a sale: Sales or Finance *approve*;
- record an expense or bill, mark it paid: Expenses or Finance *create*;
- cancel an expense: Expenses or Finance *approve*;
- set the exchange rate: Finance *approve* or Settings *configure*;
- read: sales with Sales / Finance, expenses with Expenses / Finance,
  profit and loss with Finance / Reports.
"""
from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.api.deps import require_any_permission, user_can
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.schemas.finance import (CancelWithReason, ExchangeRateCreate, ExpenseCreate, MarkPaid, PaymentCreate, PurchaseReconcile, SaleCreate,
                                 SupplierPaymentCreate)
from app.schemas.mouneh import MounehReconcile
from app.services import finance_service as finance
from app.services import mouneh_sales_service as mouneh_sales
from app.services import purchases_service as purchases

router = APIRouter(prefix="/finance", tags=["finance"])

_ANY_MONEY = require_any_permission(perms.SALES, perms.EXPENSES, perms.FINANCE, perms.REPORTS)
_SALES_VIEW = require_any_permission(perms.SALES, perms.FINANCE)
_EXPENSES_VIEW = require_any_permission(perms.EXPENSES, perms.FINANCE)
_PL_VIEW = require_any_permission(perms.FINANCE, perms.REPORTS)


def _need(*grants: tuple[str, str], message: str):
    """A dependency: the user holds one of [grants] ((module, action)), else 403 [message]."""

    def dep(db: Session = Depends(get_db), user: models.User = Depends(_ANY_MONEY)) -> models.User:
        if not any(user_can(db, user, m, a) for m, a in grants):
            raise HTTPException(status.HTTP_403_FORBIDDEN, message)
        return user

    return dep


_SELL = _need((perms.SALES, perms.CREATE), (perms.FINANCE, perms.CREATE),
              message="Recording a sale needs Sales or Finance — ask the farm manager.")
_CANCEL_SALE = _need((perms.SALES, perms.APPROVE), (perms.FINANCE, perms.APPROVE),
                     message="Cancelling a sale is the farm manager's (Sales or Finance approval).")
_SPEND = _need((perms.EXPENSES, perms.CREATE), (perms.FINANCE, perms.CREATE),
               message="Recording an expense needs Expenses or Finance — ask the farm manager.")
_CANCEL_EXPENSE = _need((perms.EXPENSES, perms.APPROVE), (perms.FINANCE, perms.APPROVE),
                        message="Cancelling an expense is the farm manager's (Expenses or Finance approval).")
# A buyer's payment for several sales: Sales or Finance, or Milk approval
# (the collector's weekly payment on the Milk page).
_RECEIVE = _need((perms.SALES, perms.CREATE), (perms.FINANCE, perms.CREATE), (perms.MILK_PRODUCTION, perms.APPROVE),
                 message="Recording a payment needs Sales or Finance — ask the farm manager.")
_SET_RATE = _need((perms.FINANCE, perms.APPROVE), (perms.SETTINGS, perms.CONFIGURE),
                  message="The exchange rate is set by the farm manager (Finance approval).")
_RECONCILE = _need((perms.FINANCE, perms.APPROVE),
                   message="Putting past sales and deliveries in the books is the farm manager's (Finance approval).")


# ------------------------------------------------------------ the rate
@router.get("/exchange-rates")
def exchange_rates(db: Session = Depends(get_db), user: models.User = Depends(_ANY_MONEY)) -> dict:
    """The rate in force today (LBP per USD) and the rates set before it."""
    return finance.rates(db, user.farm_id)


@router.post("/exchange-rates", status_code=status.HTTP_201_CREATED)
def set_exchange_rate(payload: ExchangeRateCreate, db: Session = Depends(get_db), user: models.User = Depends(_SET_RATE)) -> dict:
    """1 USD = [rate_per_usd] LBP from [effective_date] (today when left out).
    A new rate is a new row; the earlier ones stay for the days they covered."""
    row = finance.set_rate(db, user, currency=payload.currency.upper(), rate_per_usd=payload.rate_per_usd,
                           effective_date=payload.effective_date, notes=payload.notes)
    db.commit()
    return finance.rate_dict(row)


# -------------------------------------------------------------- sales
@router.get("/sales")
def list_sales(days: int = Query(90, ge=1, le=731), db: Session = Depends(get_db), user: models.User = Depends(_SALES_VIEW)) -> list[dict]:
    """Every sale of the last [days] days — milk, eggs, produce, animals,
    Mouneh, the farm shop — newest first, cancelled ones and their
    reversals included."""
    return finance.list_sales(db, user.farm_id, days=days)


@router.post("/sales", status_code=status.HTTP_201_CREATED)
def record_sale(payload: SaleCreate, db: Session = Depends(get_db), user: models.User = Depends(_SELL)) -> dict:
    sale = finance.record_sale(
        db, user, product_type=payload.product_type, product_label=payload.product_label, quantity=payload.quantity, unit=payload.unit,
        unit_price=payload.unit_price, total=payload.total, currency=payload.currency, exchange_rate=payload.exchange_rate,
        sold_at=payload.sold_at, customer_id=payload.customer_id, buyer_name=payload.buyer_name, payment_status=payload.payment_status,
        reference=payload.reference, notes=payload.notes, activity=payload.activity, confirm_duplicate=payload.confirm_duplicate)
    db.commit()
    return finance.sale_dict(db, sale)


@router.post("/sales/{sale_id}/paid")
def mark_sale_paid(sale_id: str, payload: MarkPaid | None = None, db: Session = Depends(get_db), user: models.User = Depends(_SELL)) -> dict:
    sale = finance.mark_sale_paid(db, finance.get_sale(db, sale_id, user.farm_id), user, paid_at=payload.paid_at if payload else None)
    db.commit()
    return finance.sale_dict(db, sale)


@router.post("/sales/{sale_id}/cancel")
def cancel_sale(sale_id: str, payload: CancelWithReason, db: Session = Depends(get_db), user: models.User = Depends(_CANCEL_SALE)) -> dict:
    sale = finance.cancel_sale(db, finance.get_sale(db, sale_id, user.farm_id), user, reason=payload.reason)
    db.commit()
    db.refresh(sale)
    return finance.sale_dict(db, sale)


@router.get("/payments")
def list_payments(days: int = Query(365, ge=1, le=731), db: Session = Depends(get_db), user: models.User = Depends(_SALES_VIEW)) -> list[dict]:
    """Payments received for several sales at once, newest first."""
    return finance.list_payments(db, user.farm_id, days=days)


@router.post("/payments", status_code=status.HTTP_201_CREATED)
def receive_payment(payload: PaymentCreate, db: Session = Depends(get_db), user: models.User = Depends(_RECEIVE)) -> dict:
    """One payment for several sales of one buyer — the milk collector's week.
    Every sale is marked paid; a difference with what they came to is kept."""
    payment = finance.receive_payment(db, user, sale_ids=payload.sale_ids, amount_received=payload.amount_received, currency=payload.currency,
                                      exchange_rate=payload.exchange_rate, paid_at=payload.paid_at, reference=payload.reference,
                                      notes=payload.notes, confirm_duplicate=payload.confirm_duplicate, part_payment=payload.part_payment)
    db.commit()
    return finance.payment_dict(payment)


# ----------------------------------------------------------- expenses
@router.get("/expenses")
def list_expenses(days: int = Query(90, ge=1, le=731), db: Session = Depends(get_db), user: models.User = Depends(_EXPENSES_VIEW)) -> list[dict]:
    return finance.list_expenses(db, user.farm_id, days=days)


@router.post("/expenses", status_code=status.HTTP_201_CREATED)
def record_expense(payload: ExpenseCreate, db: Session = Depends(get_db), user: models.User = Depends(_SPEND)) -> dict:
    row = finance.record_expense(
        db, user, category=payload.category, description=payload.description, amount=payload.amount, currency=payload.currency,
        exchange_rate=payload.exchange_rate, incurred_at=payload.incurred_at, supplier_id=payload.supplier_id,
        supplier_name=payload.supplier_name, payment_status=payload.payment_status, due_date=payload.due_date,
        reference=payload.reference, notes=payload.notes, activity=payload.activity, confirm_duplicate=payload.confirm_duplicate)
    db.commit()
    return finance.expense_rows(db, [row])[0]


@router.post("/expenses/{expense_id}/paid")
def mark_expense_paid(expense_id: str, payload: MarkPaid | None = None, db: Session = Depends(get_db), user: models.User = Depends(_SPEND)) -> dict:
    row = finance.mark_expense_paid(db, finance.get_expense(db, expense_id, user.farm_id), user, paid_at=payload.paid_at if payload else None)
    db.commit()
    return finance.expense_rows(db, [row])[0]


@router.post("/expenses/{expense_id}/cancel")
def cancel_expense(expense_id: str, payload: CancelWithReason, db: Session = Depends(get_db), user: models.User = Depends(_CANCEL_EXPENSE)) -> dict:
    row = finance.cancel_expense(db, finance.get_expense(db, expense_id, user.farm_id), user, reason=payload.reason)
    db.commit()
    return finance.expense_rows(db, [row])[0]


# ------------------------------------------------ who owes what, P&L
@router.get("/owed")
def owed(db: Session = Depends(get_db), user: models.User = Depends(_ANY_MONEY)) -> dict:
    """What customers still owe the farm (with Sales / Finance) and what the
    farm still owes its suppliers (with Expenses / Finance)."""
    receivables = user_can(db, user, perms.SALES, perms.VIEW) or user_can(db, user, perms.FINANCE, perms.VIEW)
    payables = user_can(db, user, perms.EXPENSES, perms.VIEW) or user_can(db, user, perms.FINANCE, perms.VIEW)
    if not (receivables or payables):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "This needs Sales, Expenses or Finance — ask the farm manager.")
    return finance.owed(db, user.farm_id, receivables=receivables, payables=payables)


@router.get("/profit-loss")
def profit_loss(start: date | None = Query(None), end: date | None = Query(None), db: Session = Depends(get_db),
                user: models.User = Depends(_PL_VIEW)) -> dict:
    """Month by month from [start] to [end] (default the last 12 months):
    revenue by activity, costs by line, profit, cash in and out."""
    return finance.profit_loss(db, user.farm_id, start, end)


# ------------------------------------------------- past Mouneh sales (I-8)
@router.get("/reconciliation/mouneh-sales")
def mouneh_sales_reconciliation(db: Session = Depends(get_db), user: models.User = Depends(_RECONCILE)) -> dict:
    """A dry run: Mouneh sales on record that are not in the books yet —
    what posting them would add, the farm-shop jars already in a visit's
    purchase, and anything that needs a look. Nothing is written."""
    return mouneh_sales.reconcile(db, user, apply=False)


@router.post("/reconciliation/mouneh-sales")
def apply_mouneh_sales_reconciliation(payload: MounehReconcile | None = None, db: Session = Depends(get_db),
                                      user: models.User = Depends(_RECONCILE)) -> dict:
    """Post each of them once, on the day it was sold (paid then, or still
    owed); link the farm-shop jars to their purchase. Safe to run again."""
    out = mouneh_sales.reconcile(db, user, apply=True, payment_status=(payload or MounehReconcile()).payment_status)
    db.commit()
    return out



# --------------------------------------------- supplier bills (I-9, I-14)
def _bill_out(db: Session, bill: models.Expense) -> dict:
    return {**purchases.bill_summary(db, bill), "payments": purchases.payments_of(db, bill)}


@router.post("/expenses/{expense_id}/payments", status_code=status.HTTP_201_CREATED)
def pay_bill(expense_id: str, payload: SupplierPaymentCreate, db: Session = Depends(get_db), user: models.User = Depends(_SPEND)) -> dict:
    """A payment toward a supplier's bill — cash out on its day, the rest
    still owed — or the supplier's refund (kind "refund")."""
    bill = purchases.get_bill(db, expense_id, user.farm_id, lock=True)
    row = purchases.pay_bill(db, user, bill, amount=payload.amount, currency=payload.currency, exchange_rate=payload.exchange_rate,
                             paid_at=payload.paid_at, reference=payload.reference, notes=payload.notes, kind=payload.kind,
                             confirm_duplicate=payload.confirm_duplicate)
    db.commit()
    return {**purchases.payment_dict(row), "bill": purchases.bill_summary(db, bill)}


@router.get("/expenses/{expense_id}/payments")
def bill_payments(expense_id: str, db: Session = Depends(get_db), user: models.User = Depends(_EXPENSES_VIEW)) -> dict:
    return _bill_out(db, purchases.get_bill(db, expense_id, user.farm_id))


@router.post("/supplier-payments/{payment_id}/reverse")
def reverse_supplier_payment(payment_id: str, payload: CancelWithReason, db: Session = Depends(get_db),
                             user: models.User = Depends(_CANCEL_EXPENSE)) -> dict:
    """A payment, refund or credit recorded by mistake: undone by a negative row; it stays on file."""
    from app.domain import finance_models as fin

    row = db.get(fin.SupplierPayment, payment_id)
    if row is None or row.farm_id != user.farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Payment not found")
    undo = purchases.reverse_payment(db, user, row, reason=payload.reason)
    db.commit()
    return {**purchases.payment_dict(undo), "bill": purchases.bill_summary(db, db.get(models.Expense, row.expense_id))}


@router.get("/reconciliation/purchases")
def purchases_reconciliation(db: Session = Depends(get_db), user: models.User = Depends(_RECONCILE)) -> dict:
    """A dry run: priced deliveries recorded before v0.8.9 with no bill — the
    expense that may already have paid for each, or nothing to go on."""
    return purchases.reconcile(db, user)


@router.post("/reconciliation/purchases")
def apply_purchases_reconciliation(payload: PurchaseReconcile, db: Session = Depends(get_db), user: models.User = Depends(_RECONCILE)) -> dict:
    """The manager's decisions, applied once: link, paid on arrival, or still owed."""
    out = purchases.reconcile(db, user, decisions=[d.model_dump() for d in payload.decisions])
    db.commit()
    return out
