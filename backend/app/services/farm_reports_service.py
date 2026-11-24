"""The farm's reports for a period (v0.7.9): milk, feed, herd, finance;
sales and stock (v0.8.0).

Every figure is read from the canonical records — milk records, milk
sales and the tank, feeding events and their components, delivered lots,
numbered mixes, animals, births, exits, health cases, sales and expenses
— never from a figure kept on the side. A period is whole farm days in
the farm's own time zone, from [start] to [end] inclusive.

The answers are data (codes, numbers, dates), not sentences: the tablet
and the web app label them in English or Arabic, draw them, print them and
export them.
"""
from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import feed_models as fm
from app.domain import health_models as hm
from app.domain import milk_models as mm
from app.domain import models
from app.domain import reproduction_models as rm
from app.repositories.base import ensure_utc
from app.services import feed_forecast_service as forecast
from app.services import milk_sales_service as milk_sales
from app.services.feed_inventory_service import FeedError

KINDS = ("milk", "feed", "herd", "finance", "sales", "stock")
MAX_DAYS = 366


class ReportError(FeedError):
    pass


def _tz(db: Session, farm_id: str) -> ZoneInfo:
    farm = db.get(models.Farm, farm_id)
    try:
        return ZoneInfo(farm.timezone if farm and farm.timezone else "UTC")
    except Exception:  # noqa: BLE001 - an unknown zone name falls back to UTC
        return ZoneInfo("UTC")


def period(db: Session, farm_id: str, start: date | None, end: date | None) -> tuple[date, date, datetime, datetime, ZoneInfo]:
    """The period's first and last farm day and its UTC bounds [lo, hi).
    Default: the last 30 days including today."""
    tz = _tz(db, farm_id)
    today = datetime.now(timezone.utc).astimezone(tz).date()
    end = end or today
    start = start or end - timedelta(days=29)
    if start > end:
        raise ReportError("The period starts after it ends.")
    if (end - start).days + 1 > MAX_DAYS:
        raise ReportError(f"A report covers at most {MAX_DAYS} days.")
    lo = datetime(start.year, start.month, start.day, tzinfo=tz).astimezone(timezone.utc)
    nxt = end + timedelta(days=1)
    hi = datetime(nxt.year, nxt.month, nxt.day, tzinfo=tz).astimezone(timezone.utc)
    return start, end, lo, hi, tz


def _day(at: datetime, tz: ZoneInfo) -> str:
    return ensure_utc(at).astimezone(tz).date().isoformat()


def _days(start: date, end: date) -> list[str]:
    return [(start + timedelta(days=i)).isoformat() for i in range((end - start).days + 1)]


def _r(v: float, n: int = 2) -> float:
    return round(float(v or 0), n)


def _base(db: Session, farm_id: str, kind: str, start: date, end: date) -> dict:
    farm = db.get(models.Farm, farm_id)
    return {"kind": kind, "start": start.isoformat(), "end": end.isoformat(), "days": (end - start).days + 1,
            "farm_name": farm.name if farm else "", "currency": farm.default_currency if farm else "USD",
            "generated_at": datetime.now(timezone.utc).isoformat()}


# ------------------------------------------------------------------ milk
# The day-by-day sheet of every cow (v0.8.2) is given for a period up to
# this long; a longer report keeps the per-cow totals only.
COW_SHEET_MAX_DAYS = 31


def queue_key(animal: models.Animal) -> tuple:
    """The order a milking is walked: the cows' numbers in the queue first,
    then the rest by tag in natural order (cow 9 before cow 10) — the same
    order the tablet's queue uses (quick_round.dart queueOrder)."""
    import re

    number = animal.milking_queue_number
    tag = (animal.tag or "").strip().upper()
    m = re.match(r"^([^0-9]*)([0-9]+)(.*)$", tag)
    if not tag:
        tag_key = ("\U0010ffff", 1, 0, "")
    elif m is None:
        tag_key = (tag, 1, 0, "")
    else:
        tag_key = (re.sub(r"[^A-Z]", "", m.group(1)), 0, int(m.group(2)), m.group(3))
    return (number is None, number or 0, *tag_key, (animal.name or "").lower())


def milk_report(db: Session, farm_id: str, start: date | None, end: date | None, *, with_sales: bool = True) -> dict:
    start, end, lo, hi, tz = period(db, farm_id, start, end)
    out = _base(db, farm_id, "milk", start, end)
    rows = db.execute(
        select(models.MilkRecord, models.Animal)
        .join(models.Animal, models.Animal.id == models.MilkRecord.animal_id)
        .where(models.Animal.farm_id == farm_id, models.MilkRecord.recorded_at >= lo, models.MilkRecord.recorded_at < hi)
    ).all()
    days = {d: {"date": d, "morning": 0.0, "midday": 0.0, "evening": 0.0, "total": 0.0, "withheld": 0.0, "calves": 0.0, "sold": 0.0}
            for d in _days(start, end)}
    by_dest: dict[str, float] = defaultdict(float)
    animals: dict[str, dict] = {}
    for rec, animal in rows:
        d = days.get(_day(rec.recorded_at, tz))
        if d is None:
            continue
        d[rec.session] = d.get(rec.session, 0.0) + rec.liters
        d["total"] += rec.liters
        if rec.destination == "withheld":
            d["withheld"] += rec.liters
        by_dest[rec.destination] += rec.liters
        a = animals.setdefault(animal.id, {"animal": animal, "milkings": 0, "total_l": 0.0, "days": set(),
                                           "_by_day": defaultdict(float), "_sessions": defaultdict(float),
                                           "_sheet": defaultdict(lambda: defaultdict(float))})
        a["milkings"] += 1
        a["total_l"] += rec.liters
        a["days"].add(d["date"])
        a["_by_day"][d["date"]] += rec.liters
        a["_sessions"][rec.session] += rec.liters
        a["_sheet"][d["date"]][rec.session] += rec.liters
    total = sum(d["total"] for d in days.values())
    animal_rows = []
    sheet = []
    for a in sorted(animals.values(), key=lambda a: queue_key(a["animal"])):
        animal = a["animal"]
        who = {"animal_id": animal.id, "tag": animal.tag, "name": animal.name, "species": animal.species,
               "queue_number": animal.milking_queue_number}
        # Each cow's milk by milking (v0.8.2): her mornings and her
        # afternoons (or evenings) over the period.
        animal_rows.append({**who, "milkings": a["milkings"],
                            "morning_l": _r(a["_sessions"].get("morning", 0), 1), "midday_l": _r(a["_sessions"].get("midday", 0), 1),
                            "evening_l": _r(a["_sessions"].get("evening", 0), 1),
                            "total_l": _r(a["total_l"], 1), "days_milked": len(a["days"]),
                            "avg_per_day_l": _r(a["total_l"] / len(a["days"]), 1) if a["days"] else 0.0,
                            "best_day_l": _r(max(a["_by_day"].values()) if a["_by_day"] else 0, 1)})
        for day, by_session in a["_sheet"].items():
            sheet.append({"date": day, **who, "morning_l": _r(by_session.get("morning", 0), 1), "midday_l": _r(by_session.get("midday", 0), 1),
                          "evening_l": _r(by_session.get("evening", 0), 1), "total_l": _r(sum(by_session.values()), 1)})
    # The ranking: most milk first (the queue order breaks a tie).
    animal_rows.sort(key=lambda r: -r["total_l"])
    # The sheet: the latest day first, each day's cows in queue order.
    sheet.sort(key=lambda r: r["date"], reverse=True)

    sales = db.scalars(select(mm.MilkSale).where(mm.MilkSale.farm_id == farm_id, mm.MilkSale.status == "recorded",
                                                  mm.MilkSale.sold_at >= lo, mm.MilkSale.sold_at < hi).order_by(mm.MilkSale.sold_at)).all()
    for s in sales:
        d = days.get(_day(s.sold_at, tz))
        if d is not None:
            d["sold"] += s.liters
    sold_l = sum(s.liters for s in sales)
    revenue = sum(s.amount for s in sales)
    # Milk fed to the calves (v0.8.1): tank adjustments with that reason.
    calves_l = 0.0
    for a in db.scalars(select(mm.MilkTankAdjustment).where(mm.MilkTankAdjustment.farm_id == farm_id, mm.MilkTankAdjustment.reason == "calves",
                                                            mm.MilkTankAdjustment.occurred_at >= lo, mm.MilkTankAdjustment.occurred_at < hi)):
        calves_l += -a.liters
        d = days.get(_day(a.occurred_at, tz))
        if d is not None:
            d["calves"] += -a.liters
    out["second_milking"] = (db.get(models.Farm, farm_id).second_milking or "evening") if db.get(models.Farm, farm_id) else "evening"
    out.update({
        "kpis": {
            "total_l": _r(total, 1),
            "avg_per_day_l": _r(total / out["days"], 1),
            "animals_milked": len(animals),
            "avg_per_animal_day_l": _r(sum(r["avg_per_day_l"] for r in animal_rows) / len(animal_rows), 1) if animal_rows else 0.0,
            "withheld_l": _r(by_dest.get("withheld", 0), 1),
            "calves_l": _r(calves_l, 1),
            "tank_now_l": _r(milk_sales.tank_balance(db, farm_id), 1),
            "tank_at_end_l": _r(milk_sales.tank_balance(db, farm_id, before=hi), 1),
        },
        "destinations": [{"destination": k, "liters": _r(v, 1)} for k, v in sorted(by_dest.items(), key=lambda kv: -kv[1])],
        "by_day": [{k: (_r(v, 1) if isinstance(v, float) else v) for k, v in d.items()} for d in days.values()],
        "by_animal": animal_rows,
        # Every cow, every day: her morning and afternoon litres. Only for a
        # period up to COW_SHEET_MAX_DAYS; null for a longer one.
        "by_animal_day": sheet if out["days"] <= COW_SHEET_MAX_DAYS else None,
    })
    if with_sales:
        buyers: dict[str, dict] = {}
        for s in sales:
            b = buyers.setdefault(s.buyer_name or "", {"buyer": s.buyer_name, "sales": 0, "liters": 0.0, "amount": 0.0, "pending": 0.0})
            b["sales"] += 1
            b["liters"] += s.liters
            b["amount"] += s.amount
            if s.payment_status == "pending":
                b["pending"] += s.amount
        out["kpis"].update({
            "sold_l": _r(sold_l, 1), "revenue": _r(revenue), "avg_price_per_liter": _r(revenue / sold_l, 3) if sold_l else None,
            "pending_amount": _r(sum(s.amount for s in sales if s.payment_status == "pending")),
        })
        out["sales"] = [{"date": _day(s.sold_at, tz), "buyer": s.buyer_name, "liters": _r(s.liters, 1), "price_per_liter": s.price_per_liter,
                         "amount": _r(s.amount), "payment_status": s.payment_status} for s in sales]
        out["by_buyer"] = [{**b, "liters": _r(b["liters"], 1), "amount": _r(b["amount"]), "pending": _r(b["pending"])}
                           for b in sorted(buyers.values(), key=lambda b: -b["amount"])]
    return out


# ------------------------------------------------------------------ feed
def feed_report(db: Session, farm_id: str, start: date | None, end: date | None) -> dict:
    start, end, lo, hi, tz = period(db, farm_id, start, end)
    out = _base(db, farm_id, "feed", start, end)
    products = {p.id: p for p in db.scalars(select(fm.FeedProduct).where(fm.FeedProduct.farm_id == farm_id))}
    events = db.scalars(select(fm.FeedingEvent).where(fm.FeedingEvent.farm_id == farm_id, fm.FeedingEvent.status == "recorded",
                                                       fm.FeedingEvent.occurred_at >= lo, fm.FeedingEvent.occurred_at < hi)).all()
    used: dict[tuple[str, str], dict] = {}
    subjects = set()
    for e in events:
        if e.event_type not in ("offered", "delivered"):
            continue
        subjects.add((e.subject_type, e.subject_id))
        for c in e.components:
            u = used.setdefault((c.feed_product_id, c.unit), {"feed_product_id": c.feed_product_id,
                                                               "name": products[c.feed_product_id].name if c.feed_product_id in products else c.feed_product_id,
                                                               "unit": c.unit, "quantity": 0.0, "cost": 0.0, "feedings": 0})
            u["quantity"] += c.quantity_offered
            u["cost"] += c.cost or 0.0
            u["feedings"] += 1
    used_rows = sorted(({**u, "quantity": _r(u["quantity"], 1), "cost": _r(u["cost"])} for u in used.values()), key=lambda u: -u["quantity"])

    lots = db.scalars(select(fm.FeedLot).where(fm.FeedLot.farm_id == farm_id, fm.FeedLot.source_type == "purchased",
                                                fm.FeedLot.received_at >= lo, fm.FeedLot.received_at < hi).order_by(fm.FeedLot.received_at)).all()
    deliveries = [{"date": _day(l.received_at, tz), "feed_product_id": l.feed_product_id,
                   "name": products[l.feed_product_id].name if l.feed_product_id in products else l.feed_product_id,
                   "quantity": _r(l.received_quantity, 1), "unit": l.unit, "supplier": l.supplier_label, "unit_cost": l.unit_cost,
                   "cost": _r((l.unit_cost or 0) * l.received_quantity) if l.unit_cost is not None else None, "lot_code": l.lot_code} for l in lots]
    batches = db.scalars(select(fm.FeedBatch).where(fm.FeedBatch.farm_id == farm_id, fm.FeedBatch.status == "completed",
                                                     fm.FeedBatch.produced_at >= lo, fm.FeedBatch.produced_at < hi).order_by(fm.FeedBatch.mix_number)).all()
    mixes = [{"mix_code": b.mix_code, "date": _day(b.produced_at, tz), "feed_product_id": b.feed_product_id,
              "name": products[b.feed_product_id].name if b.feed_product_id in products else b.feed_product_id,
              "quantity": _r(b.actual_quantity or 0, 1), "unit": b.unit, "cost": _r(b.actual_cost) if b.actual_cost is not None else None} for b in batches]
    stock = []
    for r in forecast.cover_for_products(db, farm_id):
        stock.append({"feed_product_id": r["feed_product_id"], "name": r["name"], "unit": r["unit"], "on_hand": _r(r["on_hand"], 1),
                      "available": _r(r["available"], 1), "daily_demand": _r(r["daily_demand"], 1) if r["daily_demand"] is not None else None,
                      "days_of_cover": r["days_of_cover"]})

    kg_used = sum(u["quantity"] for u in used.values() if u["unit"] == "kg")
    out.update({
        "kpis": {
            "feedings": sum(1 for e in events if e.event_type in ("offered", "delivered")),
            "subjects_fed": len(subjects),
            "feed_used_kg": _r(kg_used, 1),
            "feed_cost": _r(sum(u["cost"] for u in used.values())),
            "deliveries": len(deliveries),
            "delivered_kg": _r(sum(d["quantity"] for d in deliveries if d["unit"] == "kg"), 1),
            "delivered_cost": _r(sum(d["cost"] or 0 for d in deliveries)),
            "mixes": len(mixes),
            "mixed_kg": _r(sum(m["quantity"] for m in mixes if m["unit"] == "kg"), 1),
        },
        "used": used_rows,
        "deliveries": deliveries,
        "mixes": mixes,
        "stock": sorted(stock, key=lambda s: s["name"].lower()),
    })
    return out


# ------------------------------------------------------------------ herd
def herd_report(db: Session, farm_id: str, start: date | None, end: date | None) -> dict:
    start, end, lo, hi, tz = period(db, farm_id, start, end)
    out = _base(db, farm_id, "herd", start, end)
    animals = db.scalars(select(models.Animal).where(models.Animal.farm_id == farm_id)).all()
    species: dict[str, dict] = {}
    for a in animals:
        if not a.active:
            continue
        s = species.setdefault(a.species, {"species": a.species, "on_farm": 0, "females": 0, "males": 0, "in_milk": 0, "pregnant": 0})
        s["on_farm"] += 1
        s["females"] += 1 if (a.sex or "").upper() == "F" else 0
        s["males"] += 1 if (a.sex or "").upper() == "M" else 0
        s["in_milk"] += 1 if a.lactating else 0
        s["pregnant"] += 1 if a.pregnant else 0
    by_id = {a.id: a for a in animals}
    births = db.scalars(select(rm.BirthEvent).where(rm.BirthEvent.farm_id == farm_id, rm.BirthEvent.status == "recorded",
                                                     rm.BirthEvent.occurred_at >= lo, rm.BirthEvent.occurred_at < hi).order_by(rm.BirthEvent.occurred_at)).all()
    exits = [a for a in animals if a.exited_at is not None and lo <= ensure_utc(a.exited_at) < hi]
    added = [a for a in animals if a.created_at is not None and lo <= ensure_utc(a.created_at) < hi]
    cases = db.scalars(select(hm.HealthCase).where(hm.HealthCase.farm_id == farm_id, hm.HealthCase.opened_at >= lo, hm.HealthCase.opened_at < hi)).all()
    exit_counts: dict[str, int] = defaultdict(int)
    for a in exits:
        exit_counts[a.lifecycle_status] += 1
    out.update({
        "kpis": {
            "on_farm": sum(s["on_farm"] for s in species.values()),
            "in_milk": sum(s["in_milk"] for s in species.values()),
            "pregnant": sum(s["pregnant"] for s in species.values()),
            "births": len(births),
            "born_alive": sum(b.live_count for b in births),
            "added": len(added),
            "exits": len(exits),
            "health_cases": len(cases),
            "health_cases_open": sum(1 for c in cases if c.status != "closed"),
        },
        "by_species": sorted(species.values(), key=lambda s: -s["on_farm"]),
        "exit_counts": [{"status": k, "count": v} for k, v in sorted(exit_counts.items())],
        "births": [{"date": _day(b.occurred_at, tz), "dam": by_id[b.dam_animal_id].name if b.dam_animal_id in by_id else b.dam_animal_id,
                    "dam_tag": by_id[b.dam_animal_id].tag if b.dam_animal_id in by_id else None, "born": b.offspring_count,
                    "alive": b.live_count, "stillborn": b.stillborn_count} for b in births],
        "exits": [{"date": _day(a.exited_at, tz), "name": a.name, "tag": a.tag, "species": a.species, "status": a.lifecycle_status}
                  for a in sorted(exits, key=lambda a: ensure_utc(a.exited_at))],
    })
    return out


# --------------------------------------------------------------- finance
def finance_report(db: Session, farm_id: str, start: date | None, end: date | None) -> dict:
    start, end, lo, hi, tz = period(db, farm_id, start, end)
    out = _base(db, farm_id, "finance", start, end)
    sales = db.scalars(select(models.Sale).where(models.Sale.farm_id == farm_id, models.Sale.sold_at >= lo, models.Sale.sold_at < hi)
                       .order_by(models.Sale.sold_at)).all()
    expenses = db.scalars(select(models.Expense).where(models.Expense.farm_id == farm_id, models.Expense.incurred_at >= lo,
                                                       models.Expense.incurred_at < hi, models.Expense.status == "recorded")
                          .order_by(models.Expense.incurred_at)).all()
    by_type: dict[str, float] = defaultdict(float)
    by_label: dict[str, dict] = {}
    by_day = {d: {"date": d, "revenue": 0.0, "expenses": 0.0} for d in _days(start, end)}
    for s in sales:
        by_type[s.product_type] += s.amount
        lbl = by_label.setdefault(s.product_label or s.product_type, {"product": s.product_label or s.product_type, "product_type": s.product_type,
                                                                      "quantity": 0.0, "unit": s.unit, "amount": 0.0})
        lbl["quantity"] += s.quantity or 0.0
        lbl["amount"] += s.amount
        d = by_day.get(_day(s.sold_at, tz))
        if d is not None:
            d["revenue"] += s.amount
    by_cat: dict[str, float] = defaultdict(float)
    for e in expenses:
        by_cat[e.category] += e.amount
        d = by_day.get(_day(e.incurred_at, tz))
        if d is not None:
            d["expenses"] += e.amount
    revenue = sum(s.amount for s in sales)
    expense_total = sum(e.amount for e in expenses)
    paid = sum(s.amount for s in sales if s.payment_status == "paid")
    out.update({
        "kpis": {"revenue": _r(revenue), "expenses": _r(expense_total), "margin": _r(revenue - expense_total), "cash_collected": _r(paid),
                 "pending": _r(revenue - paid), "sales": len(sales)},
        "revenue_by_type": [{"product_type": k, "amount": _r(v)} for k, v in sorted(by_type.items(), key=lambda kv: -kv[1])],
        "revenue_by_product": [{**v, "quantity": _r(v["quantity"], 1), "amount": _r(v["amount"])} for v in sorted(by_label.values(), key=lambda v: -v["amount"])],
        "expenses_by_category": [{"category": k, "amount": _r(v)} for k, v in sorted(by_cat.items(), key=lambda kv: -kv[1])],
        "by_day": [{**d, "revenue": _r(d["revenue"]), "expenses": _r(d["expenses"]), "margin": _r(d["revenue"] - d["expenses"])} for d in by_day.values()],
        "sales": [{"date": _day(s.sold_at, tz), "product": s.product_label or s.product_type, "product_type": s.product_type,
                   "quantity": s.quantity, "unit": s.unit, "amount": _r(s.amount), "payment_status": s.payment_status} for s in sales],
    })
    return out


# ----------------------------------------------------------------- sales
_CANCELLED_SUFFIX = " (cancelled sale)"


def sales_report(db: Session, farm_id: str, start: date | None, end: date | None) -> dict:
    """Everything sold in the period — every product, every module: what,
    how much, for how much, to whom, paid or still owed. A sale cancelled
    in the period shows as cancelled and its reversal takes it out of the
    totals."""
    start, end, lo, hi, tz = period(db, farm_id, start, end)
    out = _base(db, farm_id, "sales", start, end)
    rows = db.scalars(select(models.Sale).where(models.Sale.farm_id == farm_id, models.Sale.sold_at >= lo, models.Sale.sold_at < hi)
                      .order_by(models.Sale.sold_at)).all()
    customers = {c.id: c.name for c in db.scalars(select(models.Customer).where(models.Customer.farm_id == farm_id))}
    today = datetime.now(timezone.utc).astimezone(tz).date()

    def buyer(s: models.Sale) -> str | None:
        return s.buyer_name or (customers.get(s.customer_id) if s.customer_id else None)

    def label(s: models.Sale) -> str:
        lbl = s.product_label or s.product_type
        return lbl[: -len(_CANCELLED_SUFFIX)] if lbl.endswith(_CANCELLED_SUFFIX) else lbl

    from app.services.finance_service import ACTIVITY_OF_PRODUCT

    by_product: dict[tuple[str, str, str | None], dict] = {}
    by_buyer: dict[str, dict] = {}
    by_activity: dict[str, float] = defaultdict(float)
    by_day = {d: {"date": d, "sales": 0, "amount": 0.0} for d in _days(start, end)}
    unpaid = []
    for s in rows:
        key = (s.product_type, label(s), s.unit)
        p = by_product.setdefault(key, {"product_type": s.product_type, "product": key[1], "unit": s.unit, "quantity": 0.0, "amount": 0.0, "sales": 0})
        p["quantity"] += s.quantity or 0.0
        p["amount"] += s.amount
        if s.status == "recorded":
            p["sales"] += 1
        name = buyer(s) or ""
        b = by_buyer.setdefault(name.strip().lower(), {"buyer": buyer(s), "sales": 0, "amount": 0.0, "unpaid": 0.0})
        b["amount"] += s.amount
        if s.status == "recorded":
            b["sales"] += 1
        by_activity[s.activity or ACTIVITY_OF_PRODUCT.get(s.product_type, "general")] += s.amount
        d = by_day.get(_day(s.sold_at, tz))
        if d is not None:
            d["amount"] += s.amount
            if s.status == "recorded":
                d["sales"] += 1
        if s.status == "recorded" and s.payment_status in ("pending", "partial") and s.amount > 0:
            b["unpaid"] += s.amount
            unpaid.append({"date": _day(s.sold_at, tz), "product": label(s), "buyer": buyer(s), "amount": _r(s.amount),
                           "days": (today - ensure_utc(s.sold_at).astimezone(tz).date()).days})
    revenue = sum(s.amount for s in rows)
    paid = sum(s.amount for s in rows if s.payment_status == "paid")
    count = sum(1 for s in rows if s.status == "recorded")
    out.update({
        "kpis": {"sales": count, "revenue": _r(revenue), "paid": _r(paid), "unpaid": _r(sum(u["amount"] for u in unpaid)),
                 "average_sale": _r(revenue / count) if count else 0.0, "cancelled": sum(1 for s in rows if s.status == "cancelled"),
                 "buyers": len([k for k in by_buyer if k])},
        "by_product": [{**p, "quantity": _r(p["quantity"], 2), "amount": _r(p["amount"]),
                        "average_price": _r(p["amount"] / p["quantity"], 3) if p["quantity"] else None}
                       for p in sorted(by_product.values(), key=lambda p: -p["amount"])],
        "by_activity": [{"activity": a, "amount": _r(v)} for a, v in sorted(by_activity.items(), key=lambda kv: -kv[1]) if _r(v)],
        "by_buyer": [{**b, "amount": _r(b["amount"]), "unpaid": _r(b["unpaid"])} for b in sorted(by_buyer.values(), key=lambda b: -b["amount"])],
        "by_day": [{**d, "amount": _r(d["amount"])} for d in by_day.values()],
        "unpaid": unpaid,
        "sales": [{"date": _day(s.sold_at, tz), "product_type": s.product_type, "product": label(s), "quantity": s.quantity, "unit": s.unit,
                   "unit_price": s.unit_price, "amount": _r(s.amount), "original_amount": s.original_amount, "original_currency": s.original_currency,
                   "buyer": buyer(s), "payment_status": s.payment_status, "status": s.status} for s in rows],
    })
    return out


# ----------------------------------------------------------------- stock
STOCK_SECTIONS = ("feed", "medicine", "mouneh_goods", "mouneh_materials", "milk", "other")


def stock_report(db: Session, farm_id: str, start: date | None, end: date | None, *, with_values: bool = True,
                 sections: set[str] | None = None) -> dict:
    """What the farm has in stock now: feed, medicine, Mouneh goods and
    materials, milk in the tank and every other stock item — on hand, what
    can be used, what runs low or expires, and (for those who see money)
    what it is worth at its cost. Read from the lots and the ledger."""
    start, end, lo, hi, tz = period(db, farm_id, start, end)
    out = _base(db, farm_id, "stock", start, end)
    today = datetime.now(timezone.utc).astimezone(tz).date()
    horizon = datetime.now(timezone.utc) + timedelta(days=30)
    from app.domain import mouneh_models as mo
    from app.domain import pharmacy_models as pm
    from app.services import pharmacy_service as pharmacy

    used_items: set[str] = set()
    # Feed: the stock ledger by lot.
    feed = []
    lots_by_product: dict[str, list[fm.FeedLot]] = defaultdict(list)
    for lot in db.scalars(select(fm.FeedLot).where(fm.FeedLot.farm_id == farm_id, fm.FeedLot.quantity_on_hand > 0.0005)):
        lots_by_product[lot.feed_product_id].append(lot)
    for p in db.scalars(select(fm.FeedProduct).where(fm.FeedProduct.farm_id == farm_id)):
        used_items.add(p.inventory_item_id)
    for r in forecast.cover_for_products(db, farm_id):
        value = sum((l.quantity_on_hand or 0) * (l.unit_cost or 0) for l in lots_by_product.get(r["feed_product_id"], []))
        low = r["status"] in ("below_minimum", "reorder", "stockout_risk") or (r["days_of_cover"] is not None and r["days_of_cover"] < 7)
        feed.append({"name": r["name"], "unit": r["unit"], "on_hand": _r(r["on_hand"], 1), "available": _r(r["available"], 1),
                     "reserved": _r(r["reserved"], 1), "unusable": _r(r["unusable"], 1), "days_of_cover": r["days_of_cover"],
                     "low": low, "value": _r(value) if with_values else None})
    # Medicine: lots on hand, usable, expiring.
    medicine = []
    for prod in db.scalars(select(pm.MedicineProduct).where(pm.MedicineProduct.farm_id == farm_id)):
        used_items.add(prod.inventory_item_id)
        item = db.get(models.InventoryItem, prod.inventory_item_id)
        b = pharmacy.stock_breakdown(db, prod)
        if b["on_hand"] <= 0.0005 and item is None:
            continue
        value = sum((l.quantity_on_hand or 0) * (l.unit_cost or 0) for l in prod.lots if (l.quantity_on_hand or 0) > 0)
        exp = b["earliest_expiry"]
        medicine.append({"name": item.name if item else (prod.brand_name or prod.generic_name or "?"), "unit": item.unit if item else None,
                         "on_hand": _r(b["on_hand"], 2), "usable": _r(b["eligible"], 2), "expired": _r(b["expired"], 2),
                         "expiring_soon": _r(b["expiring_quantity"], 2), "earliest_expiry": exp.astimezone(tz).date().isoformat() if exp else None,
                         "low": b["eligible"] <= 0.0005, "value": _r(value) if with_values else None})
    # Mouneh finished goods, by product.
    goods: dict[str, dict] = {}
    names = {p.id: p for p in db.scalars(select(mo.MounehProduct).where(mo.MounehProduct.farm_id == farm_id))}
    for g in db.scalars(select(mo.FinishedGoodsStock).where(mo.FinishedGoodsStock.farm_id == farm_id)):
        prod = names.get(g.product_id)
        row = goods.setdefault(g.product_id, {"name": prod.name if prod else g.product_id,
                                              "unit": (prod.custom_output_unit_label or prod.output_unit) if prod else None,
                                              "available": 0.0, "reserved": 0.0, "sold": 0.0, "value": 0.0, "earliest_expiry": None,
                                              "threshold": prod.low_stock_threshold if prod else None})
        row["available"] += g.quantity_available or 0
        row["reserved"] += g.quantity_reserved or 0
        row["sold"] += g.quantity_sold or 0
        row["value"] += (g.quantity_available or 0) * (g.unit_cost or 0)
        if g.expiry_date and (g.quantity_available or 0) > 0:
            e = ensure_utc(g.expiry_date).astimezone(tz).date().isoformat()
            row["earliest_expiry"] = e if row["earliest_expiry"] is None or e < row["earliest_expiry"] else row["earliest_expiry"]
    mouneh_goods = [{"name": g["name"], "unit": g["unit"], "available": _r(g["available"], 1), "reserved": _r(g["reserved"], 1),
                     "sold": _r(g["sold"], 1), "earliest_expiry": g["earliest_expiry"],
                     "low": g["threshold"] is not None and g["available"] <= g["threshold"], "value": _r(g["value"]) if with_values else None}
                    for g in sorted(goods.values(), key=lambda g: g["name"].lower())]
    # Mouneh materials and packaging.
    materials = []
    for m in db.scalars(select(mo.RawMaterial).where(mo.RawMaterial.farm_id == farm_id, mo.RawMaterial.active.is_(True))):
        if m.inventory_item_id:
            used_items.add(m.inventory_item_id)
        if not m.stock_tracking_enabled:
            continue
        materials.append({"name": m.name, "unit": m.unit, "category": m.category, "on_hand": _r(m.current_stock, 2),
                          "low": (m.current_stock or 0) <= 0, "value": _r((m.current_stock or 0) * (m.default_unit_cost or 0)) if with_values else None})
    # Every other stock item (tools, spare parts, supplies…).
    other = []
    for it in db.scalars(select(models.InventoryItem).where(models.InventoryItem.farm_id == farm_id).order_by(models.InventoryItem.name)):
        if it.id in used_items:
            continue
        other.append({"name": it.name, "category": it.category, "unit": it.unit, "on_hand": _r(it.current_qty, 2),
                      "reorder_level": it.reorder_level, "low": (it.reorder_level or 0) > 0 and (it.current_qty or 0) <= it.reorder_level,
                      "value": _r((it.current_qty or 0) * (it.unit_cost or 0)) if with_values else None})
    tank = milk_sales.tank(db, farm_id)
    milk_value = tank["balance_l"] * tank["last_price_per_liter"] if tank.get("last_price_per_liter") else None
    # Each section only for whoever works in that area (all with Reports).
    show = set(STOCK_SECTIONS) if sections is None else sections
    feed = feed if "feed" in show else []
    medicine = medicine if "medicine" in show else []
    mouneh_goods = mouneh_goods if "mouneh_goods" in show else []
    materials = materials if "mouneh_materials" in show else []
    other = other if "other" in show else []
    if "milk" not in show:
        milk_value = None
    sections_ = (feed, medicine, mouneh_goods, materials, other)
    lines = sum(1 for sec in sections_ for r in sec if (r.get("on_hand") or r.get("available") or 0) > 0)
    expiring = sum(1 for r in medicine if r["expiring_soon"] > 0) + sum(1 for r in mouneh_goods if r["earliest_expiry"] and r["earliest_expiry"] <= horizon.astimezone(tz).date().isoformat())
    value = sum((r.get("value") or 0) for sec in sections_ for r in sec) + (milk_value or 0)
    out.update({
        "as_of": today.isoformat(),
        "sections": [x for x in STOCK_SECTIONS if x in show],
        "kpis": {"lines": lines, "low": sum(1 for sec in sections_ for r in sec if r.get("low")), "expiring": expiring,
                 "milk_in_tank_l": _r(tank["balance_l"], 1) if "milk" in show else None, "value": _r(value) if with_values else None},
        "feed": feed, "medicine": medicine, "mouneh_goods": mouneh_goods, "mouneh_materials": materials, "other": other,
        "milk": None if "milk" not in show else {
            "in_tank_l": _r(tank["balance_l"], 1), "last_price_per_liter": tank.get("last_price_per_liter") if with_values else None,
            "value": _r(milk_value) if with_values and milk_value is not None else None},
    })
    return out


def build(db: Session, farm_id: str, kind: str, start: date | None, end: date | None, *, with_sales: bool = True,
          stock_sections: set[str] | None = None) -> dict:
    if kind == "milk":
        return milk_report(db, farm_id, start, end, with_sales=with_sales)
    if kind == "feed":
        return feed_report(db, farm_id, start, end)
    if kind == "herd":
        return herd_report(db, farm_id, start, end)
    if kind == "finance":
        return finance_report(db, farm_id, start, end)
    if kind == "sales":
        return sales_report(db, farm_id, start, end)
    if kind == "stock":
        return stock_report(db, farm_id, start, end, with_values=with_sales, sections=stock_sections)
    raise ReportError(f"kind must be one of {list(KINDS)}", 404)
