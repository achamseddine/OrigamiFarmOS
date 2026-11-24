"""Origami's financials (v0.8.0): any sale, expenses and bills, who owes
what, profit and loss, in USD with LBP where money changed hands in LBP.

The books are the canonical records, never a figure kept on the side:

* revenue — `sales`: every product (milk from the tank, eggs, produce,
  animals, Mouneh, the farm shop…). A cancelled sale stays on file and is
  undone by a negative `reversal` row.
* costs — `expenses` (bills and expenses recorded here), plus what other
  modules already record with a cost: feed fed to the animals (feeding
  events), feed delivered (feed lots), medicine received (pharmacy lots)
  and farm-visit session costs. Those are read from their own records and
  never typed in twice.
* an amount in LBP is converted at the rate the farm manager set for its
  day (finance_models.ExchangeRate) unless the person entering it gives
  the rate they actually used; the LBP amount and the rate stay on the
  record.

Profit and loss counts feed when it is fed (what it cost), and medicine
when it is received; cash out counts feed when it is delivered. A sale is
revenue when it is made and cash when it is paid.
"""
from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core import duplicates
from app.core import permissions as perms
from app.core.record_time import not_in_future
from app.domain import feed_models as fm
from app.domain import finance_models as fin
from app.domain import milk_models as mm
from app.domain import models
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event
from app.services import milk_sales_service as milk_sales
from app.services.feed_inventory_service import FeedError

# What can be sold here. Milk is sold from the tank (Sell milk) and Mouneh
# from its own shop, so their stock moves with the sale.
SALE_PRODUCT_TYPES = ("eggs", "produce", "animals", "farm_products", "other")
PAYMENT_STATUSES = ("paid", "pending")
EXPENSE_CATEGORIES = ("feed", "medicine", "veterinary", "labor", "fuel", "utilities", "equipment", "repairs", "transport",
                      "rent", "taxes", "packaging", "seeds", "fertilizer", "other")
ACTIVITIES = ("dairy", "poultry", "livestock", "crops", "mouneh", "visits", "general")

# The activity a sale belongs to, from what was sold.
ACTIVITY_OF_PRODUCT = {"milk": "dairy", "eggs": "poultry", "produce": "crops", "animals": "livestock", "mouneh": "mouneh",
                       "visitor_retail": "visits", "visits": "visits", "farm_products": "general", "other": "general"}
# The activity an expense belongs to when none is given.
ACTIVITY_OF_CATEGORY = {"feed": "livestock", "medicine": "livestock", "veterinary": "livestock", "seeds": "crops",
                        "fertilizer": "crops", "packaging": "mouneh"}
# Feed fed to an animal or group counts against what the species is kept for.
ACTIVITY_OF_SPECIES = {"cow": "dairy", "goat": "dairy", "sheep": "dairy", "layer_hen": "poultry", "duck": "poultry",
                       "turkey": "poultry"}
MAX_PL_DAYS = 731


class FinanceError(FeedError):
    pass


# ---------------------------------------------------------------- the rate
def _farm_tz(db: Session, farm_id: str) -> ZoneInfo:
    farm = db.get(models.Farm, farm_id)
    try:
        return ZoneInfo(farm.timezone if farm and farm.timezone else "UTC")
    except Exception:  # noqa: BLE001 - an unknown zone falls back to UTC
        return ZoneInfo("UTC")


def _farm_day(db: Session, farm_id: str, at: datetime) -> date:
    return ensure_utc(at).astimezone(_farm_tz(db, farm_id)).date()


def rate_on(db: Session, farm_id: str, currency: str, on: date) -> fin.ExchangeRate | None:
    """The rate in force on [on]: the latest set from that day or before
    (the latest entry wins when two were set from the same day)."""
    return db.scalar(select(fin.ExchangeRate).where(
        fin.ExchangeRate.farm_id == farm_id, fin.ExchangeRate.currency == currency, fin.ExchangeRate.effective_date <= on)
        .order_by(fin.ExchangeRate.effective_date.desc(), fin.ExchangeRate.created_at.desc()).limit(1))


def rate_dict(r: fin.ExchangeRate) -> dict:
    return {"id": r.id, "currency": r.currency, "rate_per_usd": r.rate_per_usd, "effective_date": r.effective_date.isoformat(),
            "notes": r.notes, "set_by": r.set_by, "created_at": r.created_at}


def rates(db: Session, farm_id: str) -> dict:
    today = _farm_day(db, farm_id, now())
    history = db.scalars(select(fin.ExchangeRate).where(fin.ExchangeRate.farm_id == farm_id)
                         .order_by(fin.ExchangeRate.effective_date.desc(), fin.ExchangeRate.created_at.desc()).limit(60)).all()
    current = {}
    for c in fin.CURRENCIES:
        if c == fin.BASE_CURRENCY:
            continue
        r = rate_on(db, farm_id, c, today)
        current[c] = rate_dict(r) if r else None
    return {"base": fin.BASE_CURRENCY, "currencies": list(fin.CURRENCIES), "current": current, "history": [rate_dict(r) for r in history]}


def set_rate(db: Session, user: models.User, *, currency: str, rate_per_usd: float, effective_date: date | None, notes: str | None) -> fin.ExchangeRate:
    if currency not in fin.CURRENCIES or currency == fin.BASE_CURRENCY:
        raise FinanceError(f"The rate is set for {[c for c in fin.CURRENCIES if c != fin.BASE_CURRENCY]}.")
    if rate_per_usd is None or rate_per_usd <= 0:
        raise FinanceError("The rate must be more than zero.")
    today = _farm_day(db, user.farm_id, now())
    day = effective_date or today
    if day > today:
        raise FinanceError("A rate cannot start in the future.", 422)
    previous = rate_on(db, user.farm_id, currency, day)
    row = fin.ExchangeRate(id=new_id(), farm_id=user.farm_id, currency=currency, rate_per_usd=rate_per_usd, effective_date=day,
                           notes=(notes or "").strip() or None, set_by=user.id, created_at=now())
    db.add(row)
    db.flush()
    write_audit_log(db, farm_id=user.farm_id, user_id=user.id, action="exchange_rate_set", entity_type="exchange_rate", entity_id=row.id,
                    module_code=perms.FINANCE, summary=f"1 USD = {rate_per_usd:,.0f} {currency} from {day.isoformat()}"[:500],
                    changes={"rate_per_usd": {"from": previous.rate_per_usd if previous else None, "to": rate_per_usd}})
    write_event(db, farm_id=user.farm_id, entity_type="exchange_rate", entity_id=row.id, event_type="exchange_rate_set",
                payload={"currency": currency, "rate_per_usd": rate_per_usd, "effective_date": day.isoformat()}, created_by=user.id)
    return row


def to_base(db: Session, farm_id: str, amount: float, currency: str | None, rate: float | None, at: datetime) -> tuple[float, float | None, str | None, float | None]:
    """(amount in USD, original amount, original currency, rate used). An
    amount in USD is kept as it is; one in LBP is converted at [rate] when
    given, else at the farm's rate for its day — none set is refused."""
    cur = (currency or fin.BASE_CURRENCY).upper()
    if cur not in fin.CURRENCIES:
        raise FinanceError(f"currency must be one of {list(fin.CURRENCIES)}")
    if cur == fin.BASE_CURRENCY:
        return round(amount, 2), None, None, None
    if rate is None:
        r = rate_on(db, farm_id, cur, _farm_day(db, farm_id, at))
        if r is None:
            raise FinanceError(f"No {cur} exchange rate is set for that day. Set the rate in Sales & Finance, or give the rate used.", 422)
        rate = r.rate_per_usd
    if rate <= 0:
        raise FinanceError("The exchange rate must be more than zero.")
    return round(amount / rate, 2), round(amount, 2), cur, rate


# --------------------------------------------------------------- parties
def _customer(db: Session, farm_id: str, customer_id: str | None, name: str | None) -> tuple[str | None, str | None]:
    return milk_sales._customer(db, farm_id, customer_id, name)


def _supplier(db: Session, farm_id: str, supplier_id: str | None, name: str | None) -> tuple[str | None, str | None]:
    if supplier_id:
        s = db.get(models.Supplier, supplier_id)
        if s is None or s.farm_id != farm_id:
            raise FinanceError("Supplier not found", 404)
        return s.id, s.name
    label = (name or "").strip()
    if not label:
        return None, None
    s = db.scalar(select(models.Supplier).where(models.Supplier.farm_id == farm_id, func.lower(models.Supplier.name) == label.lower()))
    if s is None:
        s = models.Supplier(id=new_id(), farm_id=farm_id, name=label[:200])
        db.add(s)
        db.flush()
    return s.id, s.name


# ----------------------------------------------------------------- sales
def get_sale(db: Session, sale_id: str, farm_id: str) -> models.Sale:
    s = db.get(models.Sale, sale_id)
    if s is None or s.farm_id != farm_id:
        raise FinanceError("Sale not found", 404)
    return s


def _linked(db: Session, sale: models.Sale) -> tuple[str, object | None]:
    """Which module recorded this sale: milk (a tank sale), mouneh, visits,
    or a sale recorded here."""
    milk = db.scalar(select(mm.MilkSale).where(mm.MilkSale.sale_id == sale.id))
    if milk is not None:
        return "milk", milk
    from app.domain import mouneh_models as mo
    from app.domain import visits_models as vm
    if db.scalar(select(mo.MounehSaleLine.id).where(mo.MounehSaleLine.sale_id == sale.id).limit(1)):
        return "mouneh", None
    if db.scalar(select(vm.VisitRetailSale.id).where(vm.VisitRetailSale.sale_id == sale.id).limit(1)):
        return "visits", None
    return "finance", None


def record_sale(db: Session, user: models.User, *, product_type: str, product_label: str | None, quantity: float | None, unit: str | None,
                unit_price: float | None, total: float | None, currency: str | None, exchange_rate: float | None, sold_at: datetime | None,
                customer_id: str | None, buyer_name: str | None, payment_status: str, reference: str | None, notes: str | None,
                activity: str | None, confirm_duplicate: bool) -> models.Sale:
    if product_type == "milk":
        raise FinanceError("Milk is sold from the tank: use Sell milk, so the tank and the sale stay together.", 422)
    if product_type == "mouneh":
        raise FinanceError("Mouneh is sold from its own stock in the Mouneh shop.", 422)
    if product_type not in SALE_PRODUCT_TYPES:
        raise FinanceError(f"product_type must be one of {list(SALE_PRODUCT_TYPES)}")
    if payment_status not in PAYMENT_STATUSES:
        raise FinanceError(f"payment_status must be one of {list(PAYMENT_STATUSES)}")
    if activity is not None and activity not in ACTIVITIES:
        raise FinanceError(f"activity must be one of {list(ACTIVITIES)}")
    if quantity is not None and quantity <= 0:
        raise FinanceError("The quantity must be more than zero.")
    if unit_price is not None and unit_price < 0:
        raise FinanceError("The price cannot be negative.")
    if total is None:
        if quantity is None or unit_price is None:
            raise FinanceError("Give the quantity and the price, or the total.")
        total = quantity * unit_price
    if total < 0:
        raise FinanceError("The total cannot be negative.")
    if total == 0:
        raise FinanceError("A sale of nothing: give the price.")
    label = (product_label or "").strip() or product_type.replace("_", " ").capitalize()
    at = not_in_future(sold_at, "A sale") or now()
    farm_id = user.farm_id
    amount, original, original_cur, rate = to_base(db, farm_id, total, currency, exchange_rate, at)
    cust_id, name = _customer(db, farm_id, customer_id, buyer_name)

    lo, hi = duplicates.near(at)
    earlier = db.scalar(select(models.Sale).where(
        models.Sale.farm_id == farm_id, models.Sale.status == "recorded", models.Sale.product_type == product_type,
        func.lower(models.Sale.product_label) == label.lower(), models.Sale.amount == amount,
        (models.Sale.customer_id == cust_id) if cust_id else models.Sale.customer_id.is_(None),
        models.Sale.sold_at >= lo, models.Sale.sold_at <= hi))
    match = duplicates.guard(earlier, f"A sale of {label} for {amount:g} {fin.BASE_CURRENCY}{(' to ' + name) if name else ''} was already "
                             "recorded within half an hour." if earlier else "", confirm=confirm_duplicate)
    unit_price_base = round(amount / quantity, 4) if quantity else None
    sale = models.Sale(
        id=new_id(), farm_id=farm_id, customer_id=cust_id, product_type=product_type, product_label=label[:100], quantity=quantity,
        unit=(unit or "").strip()[:20] or None, amount=amount, currency=fin.BASE_CURRENCY, payment_status=payment_status, sold_at=at,
        unit_price=unit_price_base, buyer_name=name, reference=(reference or "").strip()[:120] or None, notes=(notes or "").strip() or None,
        status="recorded", paid_at=at if payment_status == "paid" else None, original_amount=original, original_currency=original_cur,
        exchange_rate=rate, activity=activity or ACTIVITY_OF_PRODUCT.get(product_type, "general"), recorded_by=user.id, created_at=now())
    db.add(sale)
    db.flush()
    duplicates.log_confirmed(db, farm_id=farm_id, entity_type="sale", entity_id=sale.id, match_id=match.id if match else None,
                             what=f"sale:{sale.id}", user_id=user.id)
    money = f"{original:,.0f} {original_cur} ({amount:g} {fin.BASE_CURRENCY})" if original_cur else f"{amount:g} {fin.BASE_CURRENCY}"
    write_audit_log(db, farm_id=farm_id, user_id=user.id, action="sale_recorded", entity_type="sale", entity_id=sale.id, module_code=perms.SALES,
                    summary=(f"Sold {label}" + (f" × {quantity:g} {unit or ''}".rstrip() if quantity else "") + f" for {money}"
                             + (f" to {name}" if name else "") + f" ({payment_status})")[:500],
                    changes={"status": {"from": None, "to": "recorded"}})
    write_event(db, farm_id=farm_id, entity_type="sale", entity_id=sale.id, event_type="sale_recorded",
                payload={"product_type": product_type, "label": label, "quantity": quantity, "unit": unit, "amount": amount,
                         "original_amount": original, "original_currency": original_cur, "exchange_rate": rate, "buyer": name,
                         "payment_status": payment_status}, created_by=user.id)
    return sale


def mark_sale_paid(db: Session, sale: models.Sale, user: models.User, *, paid_at: datetime | None = None) -> models.Sale:
    if sale.status != "recorded":
        raise FinanceError("Only a sale on record (not cancelled) can be marked paid.", 409)
    if sale.payment_status == "paid":
        return sale
    module, milk = _linked(db, sale)
    if module == "milk":
        milk_sales.mark_paid(db, milk, user)
        return sale
    when = not_in_future(paid_at, "A payment") or now()
    before = sale.payment_status
    sale.payment_status, sale.paid_at = "paid", when
    write_audit_log(db, farm_id=sale.farm_id, user_id=user.id, action="sale_paid", entity_type="sale", entity_id=sale.id, module_code=perms.SALES,
                    summary=f"{sale.product_label or sale.product_type} ({sale.amount:g} {sale.currency}) marked paid"[:500],
                    changes={"payment_status": {"from": before, "to": "paid"}})
    write_event(db, farm_id=sale.farm_id, entity_type="sale", entity_id=sale.id, event_type="sale_paid",
                payload={"amount": sale.amount, "paid_at": when.isoformat()}, created_by=user.id)
    return sale


def cancel_sale(db: Session, sale: models.Sale, user: models.User, *, reason: str) -> models.Sale:
    """A sale recorded by mistake: kept on file, marked cancelled with the
    reason, and undone by a negative row. A milk sale goes back to the tank;
    Mouneh and farm-shop sales are cancelled where their stock is."""
    if sale.status == "reversal":
        raise FinanceError("This row undoes a cancelled sale; it is not cancelled itself.", 409)
    if sale.status == "cancelled":
        raise FinanceError("This sale is already cancelled.", 409)
    if not reason or not reason.strip():
        raise FinanceError("Say why the sale is cancelled.")
    module, milk = _linked(db, sale)
    if module == "milk":
        milk_sales.cancel(db, milk, user, reason=reason)
        return sale
    if module == "mouneh":
        raise FinanceError("This is a Mouneh sale: cancel it in Mouneh, so its jars go back on the shelf.", 409)
    if module == "visits":
        raise FinanceError("This is a farm-shop sale from a visit: cancel it in Farm visits.", 409)
    reversal = models.Sale(
        id=new_id(), farm_id=sale.farm_id, customer_id=sale.customer_id, product_type=sale.product_type,
        product_label=f"{sale.product_label or sale.product_type} (cancelled sale)"[:100], quantity=-sale.quantity if sale.quantity else None,
        unit=sale.unit, amount=-sale.amount, currency=sale.currency, payment_status=sale.payment_status, sold_at=now(),
        unit_price=sale.unit_price, buyer_name=sale.buyer_name, status="reversal", reversal_of_id=sale.id,
        paid_at=now() if sale.payment_status == "paid" else None,
        original_amount=-sale.original_amount if sale.original_amount is not None else None, original_currency=sale.original_currency,
        exchange_rate=sale.exchange_rate, activity=sale.activity, recorded_by=user.id, created_at=now())
    db.add(reversal)
    sale.status, sale.cancel_reason, sale.cancelled_at = "cancelled", reason.strip(), now()
    db.flush()
    write_audit_log(db, farm_id=sale.farm_id, user_id=user.id, action="sale_cancelled", entity_type="sale", entity_id=sale.id, module_code=perms.SALES,
                    summary=f"Sale of {sale.product_label or sale.product_type} ({sale.amount:g} {sale.currency}) cancelled: {reason.strip()}"[:500],
                    changes={"status": {"from": "recorded", "to": "cancelled"}}, metadata={"reason": reason.strip(), "reversal_sale_id": reversal.id})
    write_event(db, farm_id=sale.farm_id, entity_type="sale", entity_id=sale.id, event_type="sale_cancelled",
                payload={"amount": sale.amount, "reason": reason.strip(), "reversal_sale_id": reversal.id}, created_by=user.id)
    return sale


def sale_dict(db: Session, s: models.Sale, *, customers: dict[str, str] | None = None) -> dict:
    buyer = s.buyer_name
    if not buyer and s.customer_id:
        buyer = (customers or {}).get(s.customer_id)
        if buyer is None:
            c = db.get(models.Customer, s.customer_id)
            buyer = c.name if c else None
    return {"id": s.id, "product_type": s.product_type, "product_label": s.product_label, "quantity": s.quantity, "unit": s.unit,
            "unit_price": s.unit_price, "amount": s.amount, "currency": s.currency, "original_amount": s.original_amount,
            "original_currency": s.original_currency, "exchange_rate": s.exchange_rate, "payment_status": s.payment_status,
            "paid_at": s.paid_at, "sold_at": s.sold_at, "customer_id": s.customer_id, "buyer_name": buyer, "reference": s.reference,
            "notes": s.notes, "status": s.status, "cancel_reason": s.cancel_reason, "cancelled_at": s.cancelled_at,
            "reversal_of_id": s.reversal_of_id, "activity": s.activity or ACTIVITY_OF_PRODUCT.get(s.product_type, "general"),
            "recorded_by": s.recorded_by, "payment_id": s.payment_id}


def list_sales(db: Session, farm_id: str, *, days: int = 90) -> list[dict]:
    since = now() - timedelta(days=max(1, min(days, 731)))
    rows = db.scalars(select(models.Sale).where(models.Sale.farm_id == farm_id, models.Sale.sold_at >= since)
                      .order_by(models.Sale.sold_at.desc()).limit(1000)).all()
    customers = {c.id: c.name for c in db.scalars(select(models.Customer).where(models.Customer.farm_id == farm_id))}
    return [sale_dict(db, s, customers=customers) for s in rows]


# -------------------------------------------------------------- expenses
def get_expense(db: Session, expense_id: str, farm_id: str) -> models.Expense:
    e = db.get(models.Expense, expense_id)
    if e is None or e.farm_id != farm_id:
        raise FinanceError("Expense not found", 404)
    return e


def record_expense(db: Session, user: models.User, *, category: str, description: str | None, amount: float, currency: str | None,
                   exchange_rate: float | None, incurred_at: datetime | None, supplier_id: str | None, supplier_name: str | None,
                   payment_status: str, due_date: datetime | None, reference: str | None, notes: str | None, activity: str | None,
                   confirm_duplicate: bool) -> models.Expense:
    if category not in EXPENSE_CATEGORIES:
        raise FinanceError(f"category must be one of {list(EXPENSE_CATEGORIES)}")
    if payment_status not in PAYMENT_STATUSES:
        raise FinanceError(f"payment_status must be one of {list(PAYMENT_STATUSES)}")
    if activity is not None and activity not in ACTIVITIES:
        raise FinanceError(f"activity must be one of {list(ACTIVITIES)}")
    if amount is None or amount <= 0:
        raise FinanceError("The amount must be more than zero.")
    at = not_in_future(incurred_at, "An expense") or now()
    farm_id = user.farm_id
    usd, original, original_cur, rate = to_base(db, farm_id, amount, currency, exchange_rate, at)
    sup_id, sup_name = _supplier(db, farm_id, supplier_id, supplier_name)
    desc = (description or "").strip()[:300] or None

    lo, hi = duplicates.near(at)
    earlier = db.scalar(select(models.Expense).where(
        models.Expense.farm_id == farm_id, models.Expense.status == "recorded", models.Expense.category == category,
        models.Expense.amount == usd, (models.Expense.supplier_id == sup_id) if sup_id else models.Expense.supplier_id.is_(None),
        models.Expense.incurred_at >= lo, models.Expense.incurred_at <= hi))
    match = duplicates.guard(earlier, f"A {category} expense of {usd:g} {fin.BASE_CURRENCY}{(' to ' + sup_name) if sup_name else ''} was "
                             "already recorded within half an hour." if earlier else "", confirm=confirm_duplicate)
    due = ensure_utc(due_date) if due_date else None
    row = models.Expense(
        id=new_id(), farm_id=farm_id, supplier_id=sup_id, supplier_label=sup_name, category=category, amount=usd, currency=fin.BASE_CURRENCY,
        incurred_at=at, description=desc, payment_status=payment_status, due_date=due if payment_status == "pending" else None,
        paid_at=at if payment_status == "paid" else None, reference=(reference or "").strip()[:120] or None,
        notes=(notes or "").strip() or None, status="recorded", original_amount=original, original_currency=original_cur,
        exchange_rate=rate, activity=activity or ACTIVITY_OF_CATEGORY.get(category, "general"), recorded_by=user.id, created_at=now())
    db.add(row)
    db.flush()
    duplicates.log_confirmed(db, farm_id=farm_id, entity_type="expense", entity_id=row.id, match_id=match.id if match else None,
                             what=f"expense:{row.id}", user_id=user.id)
    money = f"{original:,.0f} {original_cur} ({usd:g} {fin.BASE_CURRENCY})" if original_cur else f"{usd:g} {fin.BASE_CURRENCY}"
    write_audit_log(db, farm_id=farm_id, user_id=user.id, action="expense_recorded", entity_type="expense", entity_id=row.id,
                    module_code=perms.EXPENSES, summary=f"{category.capitalize()}: {desc or ''} {money}{(' to ' + sup_name) if sup_name else ''}"
                                                       f" ({'paid' if payment_status == 'paid' else 'to pay'})"[:500],
                    changes={"status": {"from": None, "to": "recorded"}})
    write_event(db, farm_id=farm_id, entity_type="expense", entity_id=row.id, event_type="expense_recorded",
                payload={"category": category, "amount": usd, "original_amount": original, "original_currency": original_cur,
                         "exchange_rate": rate, "supplier": sup_name, "payment_status": payment_status}, created_by=user.id)
    return row


def mark_expense_paid(db: Session, e: models.Expense, user: models.User, *, paid_at: datetime | None = None) -> models.Expense:
    if e.status != "recorded":
        raise FinanceError("A cancelled expense cannot be paid.", 409)
    if e.payment_status == "paid":
        return e
    when = not_in_future(paid_at, "A payment") or now()
    e.payment_status, e.paid_at = "paid", when
    write_audit_log(db, farm_id=e.farm_id, user_id=user.id, action="expense_paid", entity_type="expense", entity_id=e.id, module_code=perms.EXPENSES,
                    summary=f"{e.category.capitalize()} {e.amount:g} {e.currency}{(' to ' + e.supplier_label) if e.supplier_label else ''} paid"[:500],
                    changes={"payment_status": {"from": "pending", "to": "paid"}})
    write_event(db, farm_id=e.farm_id, entity_type="expense", entity_id=e.id, event_type="expense_paid",
                payload={"amount": e.amount, "paid_at": when.isoformat()}, created_by=user.id)
    return e


def cancel_expense(db: Session, e: models.Expense, user: models.User, *, reason: str) -> models.Expense:
    if e.status == "cancelled":
        raise FinanceError("This expense is already cancelled.", 409)
    if not reason or not reason.strip():
        raise FinanceError("Say why the expense is cancelled.")
    e.status, e.cancel_reason, e.cancelled_at = "cancelled", reason.strip(), now()
    write_audit_log(db, farm_id=e.farm_id, user_id=user.id, action="expense_cancelled", entity_type="expense", entity_id=e.id,
                    module_code=perms.EXPENSES, summary=f"{e.category.capitalize()} {e.amount:g} {e.currency} cancelled: {reason.strip()}"[:500],
                    changes={"status": {"from": "recorded", "to": "cancelled"}}, metadata={"reason": reason.strip()})
    write_event(db, farm_id=e.farm_id, entity_type="expense", entity_id=e.id, event_type="expense_cancelled",
                payload={"amount": e.amount, "reason": reason.strip()}, created_by=user.id)
    return e


def expense_dict(e: models.Expense, suppliers: dict[str, str] | None = None) -> dict:
    supplier = e.supplier_label or ((suppliers or {}).get(e.supplier_id) if e.supplier_id else None)
    return {"id": e.id, "category": e.category, "description": e.description, "amount": e.amount, "currency": e.currency,
            "original_amount": e.original_amount, "original_currency": e.original_currency, "exchange_rate": e.exchange_rate,
            "incurred_at": e.incurred_at, "supplier_id": e.supplier_id, "supplier_name": supplier, "payment_status": e.payment_status,
            "due_date": e.due_date, "paid_at": e.paid_at, "reference": e.reference, "notes": e.notes, "status": e.status,
            "cancel_reason": e.cancel_reason, "cancelled_at": e.cancelled_at,
            "activity": e.activity or ACTIVITY_OF_CATEGORY.get(e.category, "general"), "recorded_by": e.recorded_by}


def list_expenses(db: Session, farm_id: str, *, days: int = 90) -> list[dict]:
    since = now() - timedelta(days=max(1, min(days, 731)))
    rows = db.scalars(select(models.Expense).where(models.Expense.farm_id == farm_id, models.Expense.incurred_at >= since)
                      .order_by(models.Expense.incurred_at.desc()).limit(1000)).all()
    suppliers = {s.id: s.name for s in db.scalars(select(models.Supplier).where(models.Supplier.farm_id == farm_id))}
    return [expense_dict(e, suppliers) for e in rows]


# ------------------------------------------------- payments for many sales
def receive_payment(db: Session, user: models.User, *, sale_ids: list[str], amount_received: float, currency: str | None,
                    exchange_rate: float | None, paid_at: datetime | None, reference: str | None, notes: str | None,
                    confirm_duplicate: bool) -> fin.CustomerPayment:
    """One payment for several sales of one buyer — the milk collector paying
    for the week. Every sale is marked paid on the payment's day; when the
    money received differs from what they came to, the difference is kept as
    its own revenue row (a deduction or a bonus), so revenue is what came in."""
    ids = list(dict.fromkeys(sale_ids or []))
    if not ids:
        raise FinanceError("Choose the sales this payment is for.")
    if amount_received is None or amount_received < 0:
        raise FinanceError("The amount received cannot be negative.")
    sales = [get_sale(db, i, user.farm_id) for i in ids]
    for s in sales:
        if s.status != "recorded" or s.amount <= 0:
            raise FinanceError(f"{s.product_label or s.product_type} of {s.sold_at:%d/%m/%Y} is cancelled and cannot be paid.", 409)
        if s.payment_status == "paid":
            raise FinanceError(f"{s.product_label or s.product_type} of {s.sold_at:%d/%m/%Y} is already paid.", 409)
    customers = {c.id: c.name for c in db.scalars(select(models.Customer).where(models.Customer.farm_id == user.farm_id))}

    def buyer_of(s: models.Sale) -> str:
        return (s.buyer_name or customers.get(s.customer_id or "", "") or "").strip().lower()

    buyers = {buyer_of(s) for s in sales}
    if len(buyers) != 1:
        raise FinanceError("One payment is from one buyer: choose sales of the same buyer.")
    when = not_in_future(paid_at, "A payment") or now()
    received, original, original_cur, rate = to_base(db, user.farm_id, amount_received, currency, exchange_rate, when)
    due = round(sum(s.amount for s in sales), 2)
    first = sales[0]
    name = first.buyer_name or customers.get(first.customer_id or "")

    # The same buyer paying the same amount within half an hour.
    lo, hi = duplicates.near(when)
    earlier = db.scalar(select(fin.CustomerPayment).where(
        fin.CustomerPayment.farm_id == user.farm_id, fin.CustomerPayment.amount_received == received,
        fin.CustomerPayment.buyer_name == name, fin.CustomerPayment.paid_at >= lo, fin.CustomerPayment.paid_at <= hi))
    match = duplicates.guard(earlier, f"A payment of {received:g} {fin.BASE_CURRENCY} from {name or 'this buyer'} was already recorded "
                             "within half an hour." if earlier else "", confirm=confirm_duplicate)

    payment = fin.CustomerPayment(
        id=new_id(), farm_id=user.farm_id, customer_id=first.customer_id, buyer_name=name, paid_at=when, sales_count=len(sales),
        amount_due=due, amount_received=received, original_amount=original, original_currency=original_cur, exchange_rate=rate,
        reference=(reference or "").strip()[:120] or None, notes=(notes or "").strip() or None, recorded_by=user.id, created_at=now())
    db.add(payment)
    db.flush()
    for s in sales:
        module, milk = _linked(db, s)
        if module == "milk":
            milk_sales.mark_paid(db, milk, user)
            milk.paid_at = when
        s.payment_status, s.paid_at, s.payment_id = "paid", when, payment.id
    difference = round(received - due, 2)
    if abs(difference) >= 0.01:
        types = {s.product_type for s in sales}
        product_type = types.pop() if len(types) == 1 else "other"
        diff = models.Sale(
            id=new_id(), farm_id=user.farm_id, customer_id=first.customer_id, product_type=product_type,
            product_label="Payment difference"[:100], quantity=None, unit=None, amount=difference, currency=fin.BASE_CURRENCY,
            payment_status="paid", sold_at=when, buyer_name=name, status="recorded", paid_at=when, payment_id=payment.id,
            notes=(notes or "").strip() or None, activity=first.activity or ACTIVITY_OF_PRODUCT.get(product_type, "general"),
            recorded_by=user.id, created_at=now())
        db.add(diff)
        db.flush()
        payment.difference_sale_id = diff.id
    duplicates.log_confirmed(db, farm_id=user.farm_id, entity_type="customer_payment", entity_id=payment.id,
                             match_id=match.id if match else None, what=f"customer_payment:{payment.id}", user_id=user.id)
    money = f"{original:,.0f} {original_cur} ({received:g} {fin.BASE_CURRENCY})" if original_cur else f"{received:g} {fin.BASE_CURRENCY}"
    write_audit_log(db, farm_id=user.farm_id, user_id=user.id, action="payment_received", entity_type="customer_payment", entity_id=payment.id,
                    module_code=perms.SALES, summary=(f"{name or 'A buyer'} paid {money} for {len(sales)} sale(s) of {due:g} {fin.BASE_CURRENCY}"
                                                      + (f"; difference {difference:+g}" if abs(difference) >= 0.01 else ""))[:500],
                    changes={"payment_status": {"from": "pending", "to": "paid"}}, metadata={"sale_ids": ids, "difference": difference})
    write_event(db, farm_id=user.farm_id, entity_type="customer_payment", entity_id=payment.id, event_type="payment_received",
                payload={"buyer": name, "sales": ids, "due": due, "received": received, "difference": difference,
                         "original_amount": original, "original_currency": original_cur, "exchange_rate": rate}, created_by=user.id)
    return payment


def payment_dict(p: fin.CustomerPayment) -> dict:
    return {"id": p.id, "buyer_name": p.buyer_name, "customer_id": p.customer_id, "paid_at": p.paid_at, "sales_count": p.sales_count,
            "amount_due": p.amount_due, "amount_received": p.amount_received, "difference": round(p.amount_received - p.amount_due, 2),
            "original_amount": p.original_amount, "original_currency": p.original_currency, "exchange_rate": p.exchange_rate,
            "reference": p.reference, "notes": p.notes, "recorded_by": p.recorded_by}


def list_payments(db: Session, farm_id: str, *, days: int = 365) -> list[dict]:
    since = now() - timedelta(days=max(1, min(days, 731)))
    rows = db.scalars(select(fin.CustomerPayment).where(fin.CustomerPayment.farm_id == farm_id, fin.CustomerPayment.paid_at >= since)
                      .order_by(fin.CustomerPayment.paid_at.desc()).limit(500)).all()
    return [payment_dict(p) for p in rows]


# ---------------------------------------------------------- who owes what
def owed(db: Session, farm_id: str, *, receivables: bool = True, payables: bool = True) -> dict:
    """Money customers still owe the farm (sales to be paid) and money the
    farm still owes (bills to pay), oldest first, with each one's age."""
    today = _farm_day(db, farm_id, now())
    out: dict = {"currency": fin.BASE_CURRENCY}
    if receivables:
        customers = {c.id: c.name for c in db.scalars(select(models.Customer).where(models.Customer.farm_id == farm_id))}
        rows = db.scalars(select(models.Sale).where(models.Sale.farm_id == farm_id, models.Sale.status == "recorded",
                                                    models.Sale.payment_status.in_(("pending", "partial")), models.Sale.amount > 0)
                          .order_by(models.Sale.sold_at)).all()
        items = []
        by_buyer: dict[str, dict] = {}
        for s in rows:
            d = sale_dict(db, s, customers=customers)
            d["days_outstanding"] = (today - _farm_day(db, farm_id, s.sold_at)).days
            items.append(d)
            key = (d["buyer_name"] or "").strip().lower()
            b = by_buyer.setdefault(key, {"buyer_name": d["buyer_name"], "amount": 0.0, "sales": 0, "oldest_days": 0})
            b["amount"] += s.amount
            b["sales"] += 1
            b["oldest_days"] = max(b["oldest_days"], d["days_outstanding"])
        out["receivables"] = {"total": round(sum(s.amount for s in rows), 2), "items": items,
                              "by_buyer": sorted(({**b, "amount": round(b["amount"], 2)} for b in by_buyer.values()), key=lambda b: -b["amount"])}
    if payables:
        suppliers = {s.id: s.name for s in db.scalars(select(models.Supplier).where(models.Supplier.farm_id == farm_id))}
        rows = db.scalars(select(models.Expense).where(models.Expense.farm_id == farm_id, models.Expense.status == "recorded",
                                                       models.Expense.payment_status == "pending").order_by(models.Expense.incurred_at)).all()
        items = []
        by_supplier: dict[str, dict] = {}
        overdue = 0.0
        for e in rows:
            d = expense_dict(e, suppliers)
            due = _farm_day(db, farm_id, e.due_date) if e.due_date else None
            d["days_outstanding"] = (today - _farm_day(db, farm_id, e.incurred_at)).days
            d["overdue_days"] = (today - due).days if due and due < today else 0
            if d["overdue_days"]:
                overdue += e.amount
            items.append(d)
            key = (d["supplier_name"] or "").strip().lower()
            b = by_supplier.setdefault(key, {"supplier_name": d["supplier_name"], "amount": 0.0, "bills": 0, "overdue": 0.0})
            b["amount"] += e.amount
            b["bills"] += 1
            if d["overdue_days"]:
                b["overdue"] += e.amount
        out["payables"] = {"total": round(sum(e.amount for e in rows), 2), "overdue": round(overdue, 2), "items": items,
                           "by_supplier": sorted(({**b, "amount": round(b["amount"], 2), "overdue": round(b["overdue"], 2)}
                                                  for b in by_supplier.values()), key=lambda b: -b["amount"])}
    return out


# ---------------------------------------------------------- profit & loss
def _month(d: date) -> str:
    return f"{d.year:04d}-{d.month:02d}"


def _months(start: date, end: date) -> list[str]:
    out, y, m = [], start.year, start.month
    while (y, m) <= (end.year, end.month):
        out.append(f"{y:04d}-{m:02d}")
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    return out


def profit_loss(db: Session, farm_id: str, start: date | None, end: date | None) -> dict:
    """Month by month: revenue by activity, costs by line (feed fed,
    medicine received, farm-visit costs, every expense category), profit;
    and the cash that came in and went out. Default: the last 12 months."""
    tz = _farm_tz(db, farm_id)
    today = datetime.now(timezone.utc).astimezone(tz).date()
    end = end or today
    if start is None:
        y, m = end.year, end.month - 11
        while m < 1:
            y, m = y - 1, m + 12
        start = date(y, m, 1)
    if start > end:
        raise FinanceError("The period starts after it ends.")
    if (end - start).days + 1 > MAX_PL_DAYS:
        raise FinanceError("Profit and loss covers at most two years.")
    lo = datetime(start.year, start.month, start.day, tzinfo=tz).astimezone(timezone.utc)
    nxt = end + timedelta(days=1)
    hi = datetime(nxt.year, nxt.month, nxt.day, tzinfo=tz).astimezone(timezone.utc)

    def month_of(at: datetime) -> str:
        return _month(ensure_utc(at).astimezone(tz).date())

    months = {k: {"month": k, "revenue": 0.0, "revenue_by_activity": defaultdict(float), "costs": 0.0, "cost_lines": defaultdict(float),
                  "costs_by_activity": defaultdict(float), "cash_in": 0.0, "cash_out": 0.0} for k in _months(start, end)}

    def add_cost(at: datetime, line: str, activity: str, amount: float) -> None:
        mo = months.get(month_of(at))
        if mo is None or not amount:
            return
        mo["costs"] += amount
        mo["cost_lines"][line] += amount
        mo["costs_by_activity"][activity] += amount

    def add_cash(at: datetime | None, key: str, amount: float) -> None:
        if at is None:
            return
        at = ensure_utc(at)
        if not (lo <= at < hi):
            return
        mo = months.get(month_of(at))
        if mo is not None:
            mo[key] += amount

    # Revenue: every sale row — a cancelled sale and its reversal cancel out.
    for s in db.scalars(select(models.Sale).where(models.Sale.farm_id == farm_id, models.Sale.sold_at >= lo, models.Sale.sold_at < hi)):
        mo = months.get(month_of(s.sold_at))
        if mo is None:
            continue
        act = s.activity or ACTIVITY_OF_PRODUCT.get(s.product_type, "general")
        mo["revenue"] += s.amount
        mo["revenue_by_activity"][act] += s.amount
    # Cash in: sales paid in the period (a refund of a paid sale is negative).
    for s in db.scalars(select(models.Sale).where(models.Sale.farm_id == farm_id, models.Sale.payment_status == "paid")):
        add_cash(s.paid_at or s.sold_at, "cash_in", s.amount)

    # Expenses and bills recorded here.
    for e in db.scalars(select(models.Expense).where(models.Expense.farm_id == farm_id, models.Expense.status == "recorded",
                                                     models.Expense.incurred_at >= lo, models.Expense.incurred_at < hi)):
        add_cost(e.incurred_at, f"expense:{e.category}", e.activity or ACTIVITY_OF_CATEGORY.get(e.category, "general"), e.amount)
    for e in db.scalars(select(models.Expense).where(models.Expense.farm_id == farm_id, models.Expense.status == "recorded",
                                                     models.Expense.payment_status == "paid")):
        add_cash(e.paid_at or e.incurred_at, "cash_out", e.amount)

    # Feed fed: what the feed given cost, against the species it was fed to.
    species_of: dict[tuple[str, str], str] = {}
    for a in db.execute(select(models.Animal.id, models.Animal.species).where(models.Animal.farm_id == farm_id)):
        species_of[("animal", a.id)] = a.species
    for g in db.execute(select(models.Flock.id, models.Flock.species).where(models.Flock.farm_id == farm_id)):
        species_of[("group", g.id)] = g.species
    events = db.scalars(select(fm.FeedingEvent).where(fm.FeedingEvent.farm_id == farm_id, fm.FeedingEvent.status == "recorded",
                                                       fm.FeedingEvent.occurred_at >= lo, fm.FeedingEvent.occurred_at < hi)).all()
    for ev in events:
        if ev.event_type not in ("offered", "delivered"):
            continue
        cost = sum(c.cost or 0.0 for c in ev.components)
        species = species_of.get((ev.subject_type, ev.subject_id))
        add_cost(ev.occurred_at, "feed_fed", ACTIVITY_OF_SPECIES.get(species or "", "livestock"), cost)
    # Feed delivered: cash out when it arrives (it is a cost when fed).
    for lot in db.scalars(select(fm.FeedLot).where(fm.FeedLot.farm_id == farm_id, fm.FeedLot.source_type == "purchased",
                                                    fm.FeedLot.unit_cost.is_not(None))):
        add_cash(lot.received_at, "cash_out", round((lot.unit_cost or 0) * (lot.received_quantity or 0), 2))
    # Medicine received: a cost, and cash out, when it arrives.
    from app.domain import pharmacy_models as pm
    for lot in db.scalars(select(pm.InventoryLot).where(pm.InventoryLot.farm_id == farm_id, pm.InventoryLot.source_type == "purchased",
                                                         pm.InventoryLot.unit_cost.is_not(None))):
        cost = round((lot.unit_cost or 0) * (lot.received_quantity or 0), 2)
        received = ensure_utc(lot.received_at)
        if lo <= received < hi:
            add_cost(received, "medicine_received", "livestock", cost)
        add_cash(received, "cash_out", cost)
    # Farm-visit session costs.
    from app.domain import visits_models as vm
    for c, day in db.execute(select(vm.VisitCost, vm.VisitSession.date).join(vm.VisitSession, vm.VisitSession.id == vm.VisitCost.session_id)
                             .where(vm.VisitCost.farm_id == farm_id, vm.VisitCost.deleted_at.is_(None))):
        # The session's day (noon on the farm), not when the cost was typed in.
        at = datetime(day.year, day.month, day.day, 12, tzinfo=tz).astimezone(timezone.utc) if day else ensure_utc(c.created_at)
        if lo <= at < hi:
            add_cost(at, "visit_costs", "visits", c.amount or 0.0)
        add_cash(at, "cash_out", c.amount or 0.0)

    rows = []
    totals = {"revenue": 0.0, "costs": 0.0, "profit": 0.0, "cash_in": 0.0, "cash_out": 0.0, "net_cash": 0.0}
    by_activity: dict[str, dict] = {}
    lines: dict[str, float] = defaultdict(float)
    for k in sorted(months):
        mo = months[k]
        profit = mo["revenue"] - mo["costs"]
        row = {"month": k, "revenue": round(mo["revenue"], 2), "costs": round(mo["costs"], 2), "profit": round(profit, 2),
               "cash_in": round(mo["cash_in"], 2), "cash_out": round(mo["cash_out"], 2), "net_cash": round(mo["cash_in"] - mo["cash_out"], 2),
               "revenue_by_activity": {a: round(v, 2) for a, v in mo["revenue_by_activity"].items() if round(v, 2)},
               "cost_lines": {line: round(v, 2) for line, v in mo["cost_lines"].items() if round(v, 2)}}
        rows.append(row)
        for key in ("revenue", "costs", "cash_in", "cash_out"):
            totals[key] += mo[key]
        for a, v in mo["revenue_by_activity"].items():
            by_activity.setdefault(a, {"activity": a, "revenue": 0.0, "costs": 0.0})["revenue"] += v
        for a, v in mo["costs_by_activity"].items():
            by_activity.setdefault(a, {"activity": a, "revenue": 0.0, "costs": 0.0})["costs"] += v
        for line, v in mo["cost_lines"].items():
            lines[line] += v
    totals["profit"] = totals["revenue"] - totals["costs"]
    totals["net_cash"] = totals["cash_in"] - totals["cash_out"]
    order = {a: i for i, a in enumerate(ACTIVITIES)}
    return {
        "currency": fin.BASE_CURRENCY, "start": start.isoformat(), "end": end.isoformat(),
        "totals": {k: round(v, 2) for k, v in totals.items()},
        "months": rows,
        "by_activity": sorted(({"activity": a["activity"], "revenue": round(a["revenue"], 2), "costs": round(a["costs"], 2),
                                "profit": round(a["revenue"] - a["costs"], 2)} for a in by_activity.values()
                               if round(a["revenue"], 2) or round(a["costs"], 2)), key=lambda a: order.get(a["activity"], 99)),
        "cost_lines": sorted(({"line": line, "amount": round(v, 2)} for line, v in lines.items() if round(v, 2)), key=lambda x: -x["amount"]),
    }
