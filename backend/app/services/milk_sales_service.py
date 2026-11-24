"""Selling milk from the farm's tank (milk_models.py).

    tank = milk recorded as stored − milk sold + tank adjustments

A sale is refused when it is more than the tank holds, unless someone with
the approval says the records are behind (a stock override, as for feed);
a count of the tank puts the records right. Every sale writes the farm's
revenue record (`sales`, product_type "milk"), so Sales & Finance and the
reports see the money; marking it paid updates that record; cancelling it
adds a negative one and keeps both.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core import duplicates
from app.core import permissions as perms
from app.core.record_time import not_in_future
from app.domain import milk_models as mm
from app.domain import models
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event
from app.services.feed_inventory_service import FeedError

PRODUCT_LABEL = "Raw milk"


class MilkSaleError(FeedError):
    pass


def _stored(db: Session, farm_id: str, *, before: datetime | None = None) -> float:
    stmt = (select(func.coalesce(func.sum(models.MilkRecord.liters), 0.0))
            .join(models.Animal, models.Animal.id == models.MilkRecord.animal_id)
            .where(models.Animal.farm_id == farm_id, models.MilkRecord.destination == "stored"))
    if before is not None:
        stmt = stmt.where(models.MilkRecord.recorded_at < before)
    return float(db.scalar(stmt) or 0.0)


def _sold(db: Session, farm_id: str, *, before: datetime | None = None) -> float:
    stmt = select(func.coalesce(func.sum(mm.MilkSale.liters), 0.0)).where(mm.MilkSale.farm_id == farm_id, mm.MilkSale.status == "recorded")
    if before is not None:
        stmt = stmt.where(mm.MilkSale.sold_at < before)
    return float(db.scalar(stmt) or 0.0)


def _adjusted(db: Session, farm_id: str, *, before: datetime | None = None) -> float:
    stmt = select(func.coalesce(func.sum(mm.MilkTankAdjustment.liters), 0.0)).where(mm.MilkTankAdjustment.farm_id == farm_id)
    if before is not None:
        stmt = stmt.where(mm.MilkTankAdjustment.occurred_at < before)
    return float(db.scalar(stmt) or 0.0)


def tank_balance(db: Session, farm_id: str, *, before: datetime | None = None) -> float:
    return round(_stored(db, farm_id, before=before) - _sold(db, farm_id, before=before) + _adjusted(db, farm_id, before=before), 3)


def tank(db: Session, farm_id: str) -> dict:
    farm = db.get(models.Farm, farm_id)
    last = db.scalar(select(mm.MilkSale).where(mm.MilkSale.farm_id == farm_id, mm.MilkSale.status == "recorded")
                     .order_by(mm.MilkSale.sold_at.desc()).limit(1))
    stored, sold, adjusted = _stored(db, farm_id), _sold(db, farm_id), _adjusted(db, farm_id)
    return {
        "balance_l": round(stored - sold + adjusted, 3),
        "stored_l": round(stored, 3),
        "sold_l": round(sold, 3),
        "adjusted_l": round(adjusted, 3),
        "currency": farm.default_currency if farm else "USD",
        "last_price_per_liter": last.price_per_liter if last else None,
        "last_buyer_name": last.buyer_name if last else None,
    }


def get_sale(db: Session, sale_id: str, farm_id: str) -> mm.MilkSale:
    sale = db.get(mm.MilkSale, sale_id)
    if sale is None or sale.farm_id != farm_id:
        raise MilkSaleError("Milk sale not found", 404)
    return sale


def _customer(db: Session, farm_id: str, customer_id: str | None, buyer_name: str | None) -> tuple[str | None, str | None]:
    """The buyer: a customer named by id, or by name — found, or added to
    the farm's customers the first time."""
    if customer_id:
        c = db.get(models.Customer, customer_id)
        if c is None or c.farm_id != farm_id:
            raise MilkSaleError("Buyer not found", 404)
        return c.id, c.name
    name = (buyer_name or "").strip()
    if not name:
        return None, None
    c = db.scalar(select(models.Customer).where(models.Customer.farm_id == farm_id, func.lower(models.Customer.name) == name.lower()))
    if c is None:
        c = models.Customer(id=new_id(), farm_id=farm_id, name=name[:200])
        db.add(c)
        db.flush()
    return c.id, c.name


def sell(db: Session, user: models.User, *, liters: float, price_per_liter: float, sold_at: datetime | None, customer_id: str | None,
         buyer_name: str | None, payment_status: str, reference: str | None, notes: str | None, allow_negative: bool,
         can_override: bool, confirm_duplicate: bool) -> mm.MilkSale:
    if liters <= 0:
        raise MilkSaleError("Say how many litres were sold.")
    if price_per_liter < 0:
        raise MilkSaleError("The price cannot be negative.")
    if payment_status not in mm.MILK_PAYMENT_STATUSES:
        raise MilkSaleError(f"payment_status must be one of {list(mm.MILK_PAYMENT_STATUSES)}")
    at = not_in_future(sold_at, "A milk sale") or now()
    farm_id = user.farm_id
    in_tank = tank_balance(db, farm_id, before=at + timedelta(seconds=1))
    if liters > in_tank + 1e-6:
        if not allow_negative:
            raise MilkSaleError(
                f"The tank holds {max(in_tank, 0):g} L on record, less than the {liters:g} L sold. Record the milk first, "
                "or count the tank; a manager can record the sale anyway.", 422)
        if not can_override:
            raise MilkSaleError("Selling more milk than the tank holds on record needs Milk production approval — ask the farm manager.", 403)
    cust_id, name = _customer(db, farm_id, customer_id, buyer_name)

    # The same quantity to the same buyer within half an hour: two people
    # (or one person twice) recording one collection.
    lo, hi = duplicates.near(at)
    earlier = db.scalar(select(mm.MilkSale).where(
        mm.MilkSale.farm_id == farm_id, mm.MilkSale.status == "recorded", mm.MilkSale.liters == liters,
        (mm.MilkSale.customer_id == cust_id) if cust_id else mm.MilkSale.customer_id.is_(None),
        mm.MilkSale.sold_at >= lo, mm.MilkSale.sold_at <= hi))
    match = duplicates.guard(earlier, f"{liters:g} L of milk{(' to ' + name) if name else ''} was already recorded as sold within half an hour."
                             if earlier else "", confirm=confirm_duplicate)

    farm = db.get(models.Farm, farm_id)
    currency = farm.default_currency if farm else "USD"
    amount = round(liters * price_per_liter, 2)
    revenue = models.Sale(id=new_id(), farm_id=farm_id, customer_id=cust_id, product_type="milk", product_label=PRODUCT_LABEL,
                          quantity=liters, unit="L", amount=amount, currency=currency, payment_status=payment_status, sold_at=at,
                          unit_price=price_per_liter, buyer_name=name, reference=(reference or "").strip() or None,
                          paid_at=at if payment_status == "paid" else None, status="recorded", activity="dairy",
                          recorded_by=user.id, created_at=now())
    db.add(revenue)
    sale = mm.MilkSale(
        id=new_id(), farm_id=farm_id, sold_at=at, liters=liters, price_per_liter=price_per_liter, amount=amount, currency=currency,
        customer_id=cust_id, buyer_name=name, payment_status=payment_status, paid_at=at if payment_status == "paid" else None,
        reference=(reference or "").strip() or None, notes=(notes or "").strip() or None, status="recorded", sale_id=revenue.id,
        recorded_by=user.id, created_at=now(),
    )
    db.add(sale)
    db.flush()
    duplicates.log_confirmed(db, farm_id=farm_id, entity_type="milk_sale", entity_id=sale.id, match_id=match.id if match else None,
                             what=f"milk_sale:{sale.id}", user_id=user.id)
    write_audit_log(db, farm_id=farm_id, user_id=user.id, action="milk_sold", entity_type="milk_sale", entity_id=sale.id,
                    module_code=perms.MILK_PRODUCTION,
                    summary=f"Milk sold: {liters:g} L at {price_per_liter:g} {currency}/L to {name or 'no buyer named'} ({payment_status})"[:500],
                    changes={"status": {"from": None, "to": "recorded"}}, metadata={"sale_id": revenue.id, "over_tank": liters > in_tank + 1e-6})
    write_event(db, farm_id=farm_id, entity_type="milk_sale", entity_id=sale.id, event_type="milk_sold",
                payload={"liters": liters, "price_per_liter": price_per_liter, "amount": amount, "currency": currency, "buyer": name,
                         "payment_status": payment_status, "over_tank": liters > in_tank + 1e-6}, created_by=user.id)
    return sale


def mark_paid(db: Session, sale: mm.MilkSale, user: models.User) -> mm.MilkSale:
    if sale.status != "recorded":
        raise MilkSaleError("This sale was cancelled.", 409)
    if sale.payment_status == "paid":
        return sale
    sale.payment_status, sale.paid_at = "paid", now()
    revenue = db.get(models.Sale, sale.sale_id) if sale.sale_id else None
    if revenue is not None:
        revenue.payment_status, revenue.paid_at = "paid", sale.paid_at
    write_audit_log(db, farm_id=sale.farm_id, user_id=user.id, action="milk_sale_paid", entity_type="milk_sale", entity_id=sale.id,
                    module_code=perms.MILK_PRODUCTION, summary=f"Milk sale of {sale.liters:g} L marked paid"[:500],
                    changes={"payment_status": {"from": "pending", "to": "paid"}})
    write_event(db, farm_id=sale.farm_id, entity_type="milk_sale", entity_id=sale.id, event_type="milk_sale_paid",
                payload={"amount": sale.amount, "currency": sale.currency}, created_by=user.id)
    return sale


def cancel(db: Session, sale: mm.MilkSale, user: models.User, *, reason: str) -> mm.MilkSale:
    """A sale recorded by mistake. It stays on file, marked cancelled with
    the reason; the revenue is reversed by a negative record and the milk
    counts as in the tank again."""
    if sale.status == "cancelled":
        raise MilkSaleError("This sale is already cancelled.", 409)
    if not reason or not reason.strip():
        raise MilkSaleError("Say why the sale is cancelled.")
    reversal = models.Sale(id=new_id(), farm_id=sale.farm_id, customer_id=sale.customer_id, product_type="milk",
                           product_label=f"{PRODUCT_LABEL} (cancelled sale)", quantity=-sale.liters, unit="L", amount=-sale.amount,
                           currency=sale.currency, payment_status=sale.payment_status, sold_at=now(), status="reversal",
                           reversal_of_id=sale.sale_id, buyer_name=sale.buyer_name, activity="dairy",
                           paid_at=now() if sale.payment_status == "paid" else None, recorded_by=user.id, created_at=now())
    db.add(reversal)
    original = db.get(models.Sale, sale.sale_id) if sale.sale_id else None
    if original is not None:
        original.status, original.cancel_reason, original.cancelled_at = "cancelled", reason.strip(), now()
    sale.status, sale.cancel_reason, sale.cancelled_at, sale.reversal_sale_id = "cancelled", reason.strip(), now(), reversal.id
    db.flush()
    write_audit_log(db, farm_id=sale.farm_id, user_id=user.id, action="milk_sale_cancelled", entity_type="milk_sale", entity_id=sale.id,
                    module_code=perms.MILK_PRODUCTION, summary=f"Milk sale of {sale.liters:g} L cancelled: {reason.strip()}"[:500],
                    changes={"status": {"from": "recorded", "to": "cancelled"}}, metadata={"reason": reason.strip(), "reversal_sale_id": reversal.id})
    write_event(db, farm_id=sale.farm_id, entity_type="milk_sale", entity_id=sale.id, event_type="milk_sale_cancelled",
                payload={"liters": sale.liters, "amount": sale.amount, "reason": reason.strip()}, created_by=user.id)
    return sale


def adjust_tank(db: Session, user: models.User, *, reason: str, liters: float | None, counted_level: float | None,
                occurred_at: datetime | None, notes: str | None) -> mm.MilkTankAdjustment:
    """Milk out of the tank outside a sale (spoiled, fed to calves, home use:
    [liters] taken out) or a count of the tank ([counted_level]; the
    difference with the records is what is adjusted)."""
    if reason not in mm.TANK_ADJUSTMENT_REASONS:
        raise MilkSaleError(f"reason must be one of {list(mm.TANK_ADJUSTMENT_REASONS)}")
    at = not_in_future(occurred_at, "A tank adjustment") or now()
    if reason == "count":
        if counted_level is None or counted_level < 0:
            raise MilkSaleError("Give the litres counted in the tank.")
        delta = round(counted_level - tank_balance(db, user.farm_id, before=at + timedelta(seconds=1)), 3)
    else:
        if liters is None or liters <= 0:
            raise MilkSaleError("Say how many litres left the tank.")
        delta = -liters
    row = mm.MilkTankAdjustment(id=new_id(), farm_id=user.farm_id, occurred_at=at, liters=delta, reason=reason,
                                counted_level=counted_level if reason == "count" else None, notes=(notes or "").strip() or None,
                                recorded_by=user.id, created_at=now())
    db.add(row)
    db.flush()
    write_audit_log(db, farm_id=user.farm_id, user_id=user.id, action="milk_tank_adjusted", entity_type="milk_tank_adjustment", entity_id=row.id,
                    module_code=perms.MILK_PRODUCTION,
                    summary=(f"Milk tank counted at {counted_level:g} L ({delta:+g} L)" if reason == "count" else f"{-delta:g} L out of the milk tank: {reason}")[:500],
                    changes={"liters": {"from": None, "to": delta}}, metadata={"reason": reason, "counted_level": row.counted_level})
    write_event(db, farm_id=user.farm_id, entity_type="farm", entity_id=user.farm_id, event_type="milk_tank_adjusted",
                payload={"reason": reason, "liters": delta, "counted_level": row.counted_level}, created_by=user.id)
    return row


def sale_dict(s: mm.MilkSale) -> dict:
    return {
        "id": s.id, "sold_at": ensure_utc(s.sold_at).isoformat(), "liters": s.liters, "price_per_liter": s.price_per_liter, "amount": s.amount,
        "currency": s.currency, "customer_id": s.customer_id, "buyer_name": s.buyer_name, "payment_status": s.payment_status,
        "paid_at": ensure_utc(s.paid_at).isoformat() if s.paid_at else None, "reference": s.reference, "notes": s.notes, "status": s.status,
        "cancel_reason": s.cancel_reason, "recorded_by": s.recorded_by,
    }


def adjustment_dict(a: mm.MilkTankAdjustment) -> dict:
    return {"id": a.id, "occurred_at": ensure_utc(a.occurred_at).isoformat(), "liters": a.liters, "reason": a.reason,
            "counted_level": a.counted_level, "notes": a.notes, "recorded_by": a.recorded_by}
