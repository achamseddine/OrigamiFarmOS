"""The farm's reports for a period (v0.7.9): milk, feed, herd, finance.

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

KINDS = ("milk", "feed", "herd", "finance")
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
def milk_report(db: Session, farm_id: str, start: date | None, end: date | None, *, with_sales: bool = True) -> dict:
    start, end, lo, hi, tz = period(db, farm_id, start, end)
    out = _base(db, farm_id, "milk", start, end)
    rows = db.execute(
        select(models.MilkRecord, models.Animal)
        .join(models.Animal, models.Animal.id == models.MilkRecord.animal_id)
        .where(models.Animal.farm_id == farm_id, models.MilkRecord.recorded_at >= lo, models.MilkRecord.recorded_at < hi)
    ).all()
    days = {d: {"date": d, "morning": 0.0, "midday": 0.0, "evening": 0.0, "total": 0.0, "withheld": 0.0, "sold": 0.0} for d in _days(start, end)}
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
        a = animals.setdefault(animal.id, {"animal_id": animal.id, "tag": animal.tag, "name": animal.name, "species": animal.species,
                                           "milkings": 0, "total_l": 0.0, "days": set(), "best_day_l": 0.0, "_by_day": defaultdict(float)})
        a["milkings"] += 1
        a["total_l"] += rec.liters
        a["days"].add(d["date"])
        a["_by_day"][d["date"]] += rec.liters
    total = sum(d["total"] for d in days.values())
    animal_rows = []
    for a in animals.values():
        animal_rows.append({"animal_id": a["animal_id"], "tag": a["tag"], "name": a["name"], "species": a["species"], "milkings": a["milkings"],
                            "total_l": _r(a["total_l"], 1), "days_milked": len(a["days"]),
                            "avg_per_day_l": _r(a["total_l"] / len(a["days"]), 1) if a["days"] else 0.0,
                            "best_day_l": _r(max(a["_by_day"].values()) if a["_by_day"] else 0, 1)})
    animal_rows.sort(key=lambda r: -r["total_l"])

    sales = db.scalars(select(mm.MilkSale).where(mm.MilkSale.farm_id == farm_id, mm.MilkSale.status == "recorded",
                                                  mm.MilkSale.sold_at >= lo, mm.MilkSale.sold_at < hi).order_by(mm.MilkSale.sold_at)).all()
    for s in sales:
        d = days.get(_day(s.sold_at, tz))
        if d is not None:
            d["sold"] += s.liters
    sold_l = sum(s.liters for s in sales)
    revenue = sum(s.amount for s in sales)
    out.update({
        "kpis": {
            "total_l": _r(total, 1),
            "avg_per_day_l": _r(total / out["days"], 1),
            "animals_milked": len(animals),
            "avg_per_animal_day_l": _r(sum(r["avg_per_day_l"] for r in animal_rows) / len(animal_rows), 1) if animal_rows else 0.0,
            "withheld_l": _r(by_dest.get("withheld", 0), 1),
            "tank_now_l": _r(milk_sales.tank_balance(db, farm_id), 1),
            "tank_at_end_l": _r(milk_sales.tank_balance(db, farm_id, before=hi), 1),
        },
        "destinations": [{"destination": k, "liters": _r(v, 1)} for k, v in sorted(by_dest.items(), key=lambda kv: -kv[1])],
        "by_day": [{k: (_r(v, 1) if isinstance(v, float) else v) for k, v in d.items()} for d in days.values()],
        "by_animal": animal_rows,
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
                                                       models.Expense.incurred_at < hi).order_by(models.Expense.incurred_at)).all()
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


def build(db: Session, farm_id: str, kind: str, start: date | None, end: date | None, *, with_sales: bool = True) -> dict:
    if kind == "milk":
        return milk_report(db, farm_id, start, end, with_sales=with_sales)
    if kind == "feed":
        return feed_report(db, farm_id, start, end)
    if kind == "herd":
        return herd_report(db, farm_id, start, end)
    if kind == "finance":
        return finance_report(db, farm_id, start, end)
    raise ReportError(f"kind must be one of {list(KINDS)}", 404)
