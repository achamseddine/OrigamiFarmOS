"""The farm's milking routine (v0.8.1): after each milking the calves get
their milk and the milk collector takes the rest; he pays once a week.

* The farm's settings (farms): what the second milking is called
  (afternoon or evening — the records keep the session code "evening"), the
  collector's name and the price per litre agreed with him (USD or LBP).
  Set by the farm manager.
* A handover, after a milking: litres to the calves (a tank adjustment,
  reason "calves") and litres the collector took (a milk sale to him at the
  agreed price, to be paid). Recorded by whoever milked (Milk production
  *create*): they give litres only — the buyer and the price are the
  manager's settings.
* The weekly payment settles all of the week's collections at once
  (finance_service.receive_payment).

The tank stays worked out from the records (milk stored − sold + adjustments).
"""
from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core import duplicates
from app.core import permissions as perms
from app.domain import finance_models as fin
from app.domain import milk_models as mm
from app.domain import models
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event
from app.services import finance_service as finance
from app.services import milk_safety_service as milk_safety
from app.services import milk_sales_service as milk_sales

SESSIONS = ("morning", "midday", "evening")
SECOND_MILKING = ("evening", "afternoon")
# When the milk is handed over: an hour after the milking's usual time.
_HOUR = {"morning": 8, "midday": 13, "evening": 19}
_AFTERNOON_HOUR = 16


class HandoverError(milk_sales.MilkSaleError):
    pass


def _tz(farm: models.Farm | None) -> ZoneInfo:
    try:
        return ZoneInfo(farm.timezone if farm and farm.timezone else "UTC")
    except Exception:  # noqa: BLE001 - an unknown zone falls back to UTC
        return ZoneInfo("UTC")


def _bounds(day: date, tz: ZoneInfo) -> tuple[datetime, datetime]:
    lo = datetime(day.year, day.month, day.day, tzinfo=tz).astimezone(timezone.utc)
    nxt = day + timedelta(days=1)
    return lo, datetime(nxt.year, nxt.month, nxt.day, tzinfo=tz).astimezone(timezone.utc)


# --------------------------------------------------------------- settings
def settings(db: Session, farm_id: str) -> dict:
    farm = db.get(models.Farm, farm_id)
    return {
        "second_milking": (farm.second_milking if farm else None) or "evening",
        "collector_name": farm.milk_collector_name if farm else None,
        "collector_price": farm.milk_collector_price if farm else None,
        "collector_currency": (farm.milk_collector_currency if farm else None) or fin.BASE_CURRENCY,
    }


def set_settings(db: Session, user: models.User, *, collector_name: str | None, collector_price: float | None,
                 collector_currency: str | None, second_milking: str | None) -> dict:
    farm = db.get(models.Farm, user.farm_id)
    before = settings(db, user.farm_id)
    if second_milking is not None:
        if second_milking not in SECOND_MILKING:
            raise HandoverError(f"second_milking must be one of {list(SECOND_MILKING)}")
        farm.second_milking = second_milking
    if collector_currency is not None:
        cur = collector_currency.upper()
        if cur not in fin.CURRENCIES:
            raise HandoverError(f"currency must be one of {list(fin.CURRENCIES)}")
        farm.milk_collector_currency = cur
    if collector_price is not None:
        if collector_price <= 0:
            raise HandoverError("The collector's price must be more than zero.")
        farm.milk_collector_price = collector_price
    if collector_name is not None:
        farm.milk_collector_name = collector_name.strip()[:200] or None
    after = settings(db, user.farm_id)
    changes = {k: {"from": before[k], "to": after[k]} for k in after if before[k] != after[k]}
    if changes:
        write_audit_log(db, farm_id=user.farm_id, user_id=user.id, action="milk_routine_set", entity_type="farm", entity_id=user.farm_id,
                        module_code=perms.MILK_PRODUCTION,
                        summary=f"Milk collector {after['collector_name'] or '—'} at {after['collector_price'] or '—'} {after['collector_currency']}/L; "
                                f"second milking: {after['second_milking']}"[:500],
                        changes=changes)
        write_event(db, farm_id=user.farm_id, entity_type="farm", entity_id=user.farm_id, event_type="milk_routine_set", payload=after,
                    created_by=user.id)
    return after


# -------------------------------------------------------------- handovers
def handovers(db: Session, farm_id: str, *, days: int = 14) -> dict:
    """The last [days] farm days, each milking: milk stored, to the calves,
    to the collector, what is left, and the collection's payment."""
    farm = db.get(models.Farm, farm_id)
    tz = _tz(farm)
    today = datetime.now(timezone.utc).astimezone(tz).date()
    first = today - timedelta(days=max(1, min(days, 92)) - 1)
    lo, _ = _bounds(first, tz)
    _, hi = _bounds(today, tz)
    milked: dict[tuple[str, str], float] = defaultdict(float)
    rows = db.execute(select(models.MilkRecord.session, models.MilkRecord.liters, models.MilkRecord.recorded_at)
                      .join(models.Animal, models.Animal.id == models.MilkRecord.animal_id)
                      .where(models.Animal.farm_id == farm_id, models.MilkRecord.destination == "stored",
                             models.MilkRecord.release_status.in_(milk_safety.TANK_STATUSES),
                             models.MilkRecord.recorded_at >= lo, models.MilkRecord.recorded_at < hi))
    for session, liters, at in rows:
        milked[(ensure_utc(at).astimezone(tz).date().isoformat(), session)] += liters or 0
    calves: dict[tuple[str, str], float] = defaultdict(float)
    for a in db.scalars(select(mm.MilkTankAdjustment).where(mm.MilkTankAdjustment.farm_id == farm_id, mm.MilkTankAdjustment.reason == "calves",
                                                            mm.MilkTankAdjustment.collection_day >= first)):
        if a.session:
            calves[(a.collection_day.isoformat(), a.session)] += -a.liters
    sold: dict[tuple[str, str], list[mm.MilkSale]] = defaultdict(list)
    for s in db.scalars(select(mm.MilkSale).where(mm.MilkSale.farm_id == farm_id, mm.MilkSale.status == "recorded",
                                                  mm.MilkSale.collection_day >= first)):
        if s.session:
            sold[(s.collection_day.isoformat(), s.session)].append(s)
    out = []
    for i in range((today - first).days + 1):
        d = (today - timedelta(days=i)).isoformat()
        for session in SESSIONS:
            key = (d, session)
            m, c, sales = milked.get(key, 0.0), calves.get(key, 0.0), sold.get(key, [])
            if session == "midday" and not (m or c or sales):
                continue
            collected = sum(s.liters for s in sales)
            out.append({"day": d, "session": session, "milked_l": round(m, 1), "calves_l": round(c, 1), "collected_l": round(collected, 1),
                        "left_l": round(m - c - collected, 1), "handed_over": bool(c or sales),
                        "amount": round(sum(s.amount for s in sales), 2),
                        "paid": bool(sales) and all(s.payment_status == "paid" for s in sales),
                        "sale_ids": [s.id for s in sales]})
    return {**settings(db, farm_id), "today": today.isoformat(), "tank_l": round(milk_sales.tank_balance(db, farm_id), 1), "milkings": out}


def _handover_at(farm: models.Farm | None, day: date, session: str) -> datetime:
    tz = _tz(farm)
    hour = _AFTERNOON_HOUR if session == "evening" and farm and farm.second_milking == "afternoon" else _HOUR[session]
    at = datetime(day.year, day.month, day.day, hour, tzinfo=tz).astimezone(timezone.utc)
    return min(at, now())


def hand_over(db: Session, user: models.User, *, day: date | None, session: str, calves_l: float, collected_l: float, notes: str | None,
              allow_negative: bool, can_override: bool, confirm_duplicate: bool) -> dict:
    """After a milking: [calves_l] to the calves, [collected_l] to the
    collector at the agreed price, to be paid with the week."""
    if session not in SESSIONS:
        raise HandoverError(f"session must be one of {list(SESSIONS)}")
    calves_l, collected_l = float(calves_l or 0), float(collected_l or 0)
    if calves_l < 0 or collected_l < 0:
        raise HandoverError("Litres cannot be negative.")
    if calves_l + collected_l <= 0:
        raise HandoverError("Give the litres fed to the calves or taken by the collector.")
    farm = db.get(models.Farm, user.farm_id)
    tz = _tz(farm)
    today = datetime.now(timezone.utc).astimezone(tz).date()
    day = day or today
    if day > today:
        raise HandoverError("A milking cannot be handed over before its day.", 422)
    if day < today - timedelta(days=60):
        raise HandoverError("A handover can be recorded for the last 60 days.", 422)
    cfg = settings(db, user.farm_id)
    if collected_l > 0 and (not cfg["collector_name"] or not cfg["collector_price"]):
        raise HandoverError("Set the milk collector and his price per litre first (Milk page → Collector) — ask the farm manager.", 422)
    at = _handover_at(farm, day, session)

    in_tank = milk_sales.tank_balance(db, user.farm_id, before=at + timedelta(seconds=1))
    out = calves_l + collected_l
    if out > in_tank + 1e-6:
        if not allow_negative:
            raise HandoverError(
                f"The tank holds {max(in_tank, 0):g} L on record, less than the {out:g} L handed over. Record the milking first; "
                "a manager can record it anyway.", 422)
        if not can_override:
            raise HandoverError("Handing over more milk than the tank holds on record needs Milk production approval — ask the farm manager.", 403)

    # The same milking handed over twice: two people (or one twice).
    earlier_sale = db.scalar(select(mm.MilkSale).where(mm.MilkSale.farm_id == user.farm_id, mm.MilkSale.status == "recorded",
                                                       mm.MilkSale.collection_day == day, mm.MilkSale.session == session))
    earlier_calves = db.scalar(select(mm.MilkTankAdjustment).where(mm.MilkTankAdjustment.farm_id == user.farm_id,
                                                                   mm.MilkTankAdjustment.reason == "calves",
                                                                   mm.MilkTankAdjustment.collection_day == day,
                                                                   mm.MilkTankAdjustment.session == session))
    earlier = earlier_sale or earlier_calves
    label = "afternoon" if session == "evening" and cfg["second_milking"] == "afternoon" else session
    match = duplicates.guard(earlier, f"The {label} milking of {day.isoformat()} was already handed over." if earlier else "",
                             confirm=confirm_duplicate)

    if calves_l > 0:
        adj = mm.MilkTankAdjustment(id=new_id(), farm_id=user.farm_id, occurred_at=at, liters=-calves_l, reason="calves",
                                    notes=(notes or "").strip() or None, recorded_by=user.id, created_at=now(), session=session, collection_day=day)
        db.add(adj)
        db.flush()
        write_audit_log(db, farm_id=user.farm_id, user_id=user.id, action="milk_to_calves", entity_type="milk_tank_adjustment", entity_id=adj.id,
                        module_code=perms.MILK_PRODUCTION, summary=f"{calves_l:g} L to the calves after the {label} milking of {day.isoformat()}"[:500],
                        changes={"liters": {"from": None, "to": -calves_l}})
        write_event(db, farm_id=user.farm_id, entity_type="farm", entity_id=user.farm_id, event_type="milk_tank_adjusted",
                    payload={"reason": "calves", "liters": -calves_l, "session": session, "day": day.isoformat()}, created_by=user.id)
    sale = None
    if collected_l > 0:
        price = cfg["collector_price"]
        cur = cfg["collector_currency"]
        rate = None
        if cur != fin.BASE_CURRENCY:
            r = finance.rate_on(db, user.farm_id, cur, day)
            if r is None:
                raise HandoverError(f"The collector's price is in {cur} and no {cur} exchange rate is set — set it in Sales & Finance.", 422)
            rate = r.rate_per_usd
        price_usd = round(price / rate, 4) if rate else price
        sale = milk_sales.sell(db, user, liters=collected_l, price_per_liter=price_usd, sold_at=at, customer_id=None,
                               buyer_name=cfg["collector_name"], payment_status="pending", reference=None, notes=(notes or "").strip() or None,
                               allow_negative=True, can_override=True, confirm_duplicate=True)
        sale.session, sale.collection_day = session, day
        revenue = db.get(models.Sale, sale.sale_id) if sale.sale_id else None
        if revenue is not None and rate:
            revenue.original_amount, revenue.original_currency, revenue.exchange_rate = round(collected_l * price, 2), cur, rate
        db.flush()
    if match is not None:
        duplicates.log_confirmed(db, farm_id=user.farm_id, entity_type="milk_handover", entity_id=(sale.id if sale else user.farm_id),
                                 match_id=match.id, what=f"milk_handover:{day.isoformat()}:{session}", user_id=user.id)
    return {"day": day.isoformat(), "session": session, "calves_l": calves_l, "collected_l": collected_l,
            "sale": milk_sales.sale_dict(sale) if sale else None}
