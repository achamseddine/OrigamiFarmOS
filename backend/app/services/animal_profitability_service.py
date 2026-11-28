"""What each dairy animal gives and costs over a period (master prompt
Package 3): by animal, by group, for a chosen period.

Read every time from the canonical records — milk records, milk sales,
feeding events and the cost each component was fed at, the medicine doses
and the lots they came from, the expenses — never from a figure kept on
the side. For each animal:

    milk           morning (AM) and afternoon/evening (PM) litres, total,
                   saleable (not withheld, not held for review)
    milk value     saleable litres × the farm's average milk price in the
                   period (its milk sales); unavailable when nothing was sold
                   and no earlier sale gives a price — never zero
    sales revenue  the period's milk sales revenue shared by saleable litres
    feed           her own feedings at the cost they were fed at, and her
                   share of her group's feedings: a group feeding's cost ÷
                   the heads it fed, for each head that was in the group then
    vet & medicine her doses (quantity × the lot's cost), her share of a
                   group's doses (÷ heads), expenses linked to her
    labour, power  expenses linked to her or her group; the farm's dairy
                   labour and electricity shared by days in milk
    margin         milk value − the known costs; unavailable when the milk
                   value is

A cost with no price (feed fed without a lot cost or price, a dose from a
lot without a cost) is counted apart as *unpriced*, and the costs no rule
attributes (labour and electricity not for dairy) are *unallocated*:
shown, never silently zero. The animals' figures add up to the canonical
totals, and the report says so (`reconciliation`).
"""
from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime, timedelta

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.domain import feed_models as fm
from app.domain import livestock_models as lm
from app.domain import milk_models as mm
from app.domain import models
from app.domain import pharmacy_models as pm
from app.repositories.base import ensure_utc
from app.services import farm_reports_service as reports
from app.services import milk_safety_service as safety

EPS = 1e-9
PM_SESSIONS = ("evening", "midday", "afternoon")
FED = ("offered", "delivered")
LABOUR = ("labor",)
POWER = ("utilities",)
VET = ("veterinary", "medicine")
RULES = {
    "milk_value": "Saleable litres × the farm's average milk sale price in the period (revenue ÷ litres sold); "
                  "without sales in the period, the last price sold at before it; otherwise unavailable.",
    "sales_revenue": "The period's milk sales revenue, shared by each animal's saleable litres.",
    "group_feed": "A group feeding's cost ÷ the heads it fed (its head count, or the members then), to each member at the time.",
    "group_medicine": "A group dose's cost ÷ its head count, to each member at the time.",
    "dairy_overheads": "Dairy labour and electricity (expenses of the dairy activity not linked to an animal or group) "
                       "shared by days in milk; other labour and electricity is unallocated.",
}


def _r(v: float | None, n: int = 2) -> float | None:
    return None if v is None else round(v + 0.0, n)


def _members_at(db: Session, group_id: str, at: datetime) -> list[str]:
    rows = db.scalars(select(lm.AnimalGroupMembership.animal_id).where(
        lm.AnimalGroupMembership.animal_group_id == group_id, lm.AnimalGroupMembership.valid_from <= at,
        or_(lm.AnimalGroupMembership.valid_to.is_(None), lm.AnimalGroupMembership.valid_to > at)))
    return list(rows)


def _milk_price(db: Session, farm_id: str, lo: datetime, hi: datetime) -> tuple[float | None, str, float, float]:
    """(price per litre, basis, litres sold, revenue) for the period."""
    sales = list(db.scalars(select(mm.MilkSale).where(mm.MilkSale.farm_id == farm_id, mm.MilkSale.status == "recorded",
                                                      mm.MilkSale.sold_at >= lo, mm.MilkSale.sold_at < hi)))
    liters = sum(s.liters for s in sales)
    revenue = sum(s.amount for s in sales)
    if liters > EPS:
        return revenue / liters, "period_average", liters, revenue
    last = db.scalar(select(mm.MilkSale).where(mm.MilkSale.farm_id == farm_id, mm.MilkSale.status == "recorded", mm.MilkSale.sold_at < lo)
                     .order_by(mm.MilkSale.sold_at.desc()).limit(1))
    if last is not None and last.price_per_liter:
        return last.price_per_liter, "last_sale_before", 0.0, 0.0
    return None, "unavailable", 0.0, 0.0


def report(db: Session, farm_id: str, start: date | None, end: date | None, *, animal_id: str | None = None,
           group_id: str | None = None) -> dict:
    start, end, lo, hi, tz = reports.period(db, farm_id, start, end)
    days = (end - start).days + 1

    # Who: the animals milked in the period (one, or a group's members then).
    milk_rows = db.execute(select(models.MilkRecord, models.Animal).join(models.Animal, models.Animal.id == models.MilkRecord.animal_id)
                           .where(models.Animal.farm_id == farm_id, models.MilkRecord.recorded_at >= lo, models.MilkRecord.recorded_at < hi)).all()
    wanted: set[str] | None = None
    if animal_id:
        a = db.get(models.Animal, animal_id)
        if a is None or a.farm_id != farm_id:
            raise reports.ReportError("Animal not found", 404)
        wanted = {animal_id}
    elif group_id:
        g = db.get(models.Flock, group_id)
        if g is None or g.farm_id != farm_id:
            raise reports.ReportError("Group not found", 404)
        wanted = set(db.scalars(select(lm.AnimalGroupMembership.animal_id).where(
            lm.AnimalGroupMembership.animal_group_id == group_id, lm.AnimalGroupMembership.valid_from < hi,
            or_(lm.AnimalGroupMembership.valid_to.is_(None), lm.AnimalGroupMembership.valid_to > lo))))
    rows: dict[str, dict] = {}

    def row(animal: models.Animal) -> dict:
        return rows.setdefault(animal.id, {
            "animal": animal, "am_l": 0.0, "pm_l": 0.0, "total_l": 0.0, "saleable_l": 0.0, "days_in_milk": set(),
            "feed_own": 0.0, "feed_group": 0.0, "feed_kg": 0.0, "feed_unpriced_kg": 0.0,
            "medicine": 0.0, "medicine_unpriced": 0, "vet_expenses": 0.0, "labour": 0.0, "power": 0.0,
            "_weeks": defaultdict(lambda: {"liters": 0.0, "saleable_l": 0.0, "feed": 0.0, "medicine": 0.0}),
        })

    def week(at: datetime) -> str:
        d = ensure_utc(at).astimezone(tz).date()
        return (d - timedelta(days=d.weekday())).isoformat()

    for rec, animal in milk_rows:
        if wanted is not None and animal.id not in wanted:
            continue
        r = row(animal)
        if rec.session in PM_SESSIONS:
            r["pm_l"] += rec.liters
        else:
            r["am_l"] += rec.liters
        r["total_l"] += rec.liters
        saleable = rec.destination != "withheld" and rec.release_status in safety.TANK_STATUSES
        if saleable:
            r["saleable_l"] += rec.liters
        r["days_in_milk"].add(ensure_utc(rec.recorded_at).astimezone(tz).date())
        w = r["_weeks"][week(rec.recorded_at)]
        w["liters"] += rec.liters
        if saleable:
            w["saleable_l"] += rec.liters
    animals = {a_id: r["animal"] for a_id, r in rows.items()}

    # Feed: her own feedings, and her share of her groups' feedings.
    events = list(db.scalars(select(fm.FeedingEvent).where(fm.FeedingEvent.farm_id == farm_id, fm.FeedingEvent.status == "recorded",
                                                          fm.FeedingEvent.event_type.in_(FED), fm.FeedingEvent.occurred_at >= lo,
                                                          fm.FeedingEvent.occurred_at < hi)))
    group_feed_total = group_feed_attributed = own_feed_total = 0.0
    for e in events:
        cost = sum(c.cost for c in e.components if c.cost is not None)
        kg = sum(c.quantity_offered for c in e.components if c.unit == "kg")
        unpriced = sum(c.quantity_offered for c in e.components if c.cost is None and c.unit == "kg")
        if e.subject_type == "animal":
            if e.subject_id in rows:
                r = rows[e.subject_id]
                r["feed_own"] += cost
                r["feed_kg"] += kg
                r["feed_unpriced_kg"] += unpriced
                r["_weeks"][week(e.occurred_at)]["feed"] += cost
                own_feed_total += cost
            continue
        members = _members_at(db, e.subject_id, ensure_utc(e.occurred_at))
        heads = e.head_count or len(members)
        if not heads:
            continue
        group_feed_total += cost
        for m in members:
            if m in rows:
                r = rows[m]
                r["feed_group"] += cost / heads
                r["feed_kg"] += kg / heads
                r["feed_unpriced_kg"] += unpriced / heads
                r["_weeks"][week(e.occurred_at)]["feed"] += cost / heads
                group_feed_attributed += cost / heads

    # Veterinary and medicine: doses at the lot's cost, and linked expenses.
    doses = list(db.scalars(select(pm.MedicationAdministration).where(pm.MedicationAdministration.farm_id == farm_id,
                                                                      pm.MedicationAdministration.status == "recorded",
                                                                      pm.MedicationAdministration.administered_at >= lo,
                                                                      pm.MedicationAdministration.administered_at < hi)))
    for d in doses:
        lot = db.get(pm.InventoryLot, d.inventory_lot_id)
        cost = None if lot is None or lot.unit_cost is None else d.quantity_consumed * lot.unit_cost
        targets: list[tuple[str, float]] = []
        if d.subject_type == "animal":
            targets = [(d.subject_id, 1.0)]
        else:
            members = _members_at(db, d.subject_id, ensure_utc(d.administered_at))
            heads = d.head_count or len(members)
            targets = [(m, 1.0 / heads) for m in members] if heads else []
        for a_id, share in targets:
            if a_id not in rows:
                continue
            if cost is None:
                rows[a_id]["medicine_unpriced"] += 1
            else:
                rows[a_id]["medicine"] += cost * share
                rows[a_id]["_weeks"][week(d.administered_at)]["medicine"] += cost * share

    expenses = list(db.scalars(select(models.Expense).where(models.Expense.farm_id == farm_id, models.Expense.status == "recorded",
                                                            models.Expense.incurred_at >= lo, models.Expense.incurred_at < hi)))
    dairy_overheads = {"labour": 0.0, "power": 0.0}
    unallocated = {"labour": 0.0, "power": 0.0}
    for e in expenses:
        kind = "labour" if e.category in LABOUR else ("power" if e.category in POWER else ("vet" if e.category in VET else None))
        if kind is None:
            continue
        if e.linked_entity_type in ("feed_lot", "medicine_lot"):
            continue  # stock bought: a cost when used (the doses above), never twice
        targets = []
        if e.linked_entity_type == "animal" and e.linked_entity_id:
            targets = [(e.linked_entity_id, 1.0)]
        elif e.linked_entity_type in ("group", "flock", "animal_group") and e.linked_entity_id:
            members = _members_at(db, e.linked_entity_id, ensure_utc(e.incurred_at))
            targets = [(m, 1.0 / len(members)) for m in members] if members else []
        if targets:
            for a_id, share in targets:
                if a_id in rows:
                    key = {"labour": "labour", "power": "power", "vet": "vet_expenses"}[kind]
                    rows[a_id][key] += e.amount * share
            continue
        if kind == "vet":
            continue  # a veterinary bill for the whole farm is not any one animal's
        if e.activity == "dairy":
            dairy_overheads[kind] += e.amount
        else:
            unallocated[kind] += e.amount
    cow_days = sum(len(r["days_in_milk"]) for r in rows.values())
    for r in rows.values():
        share = len(r["days_in_milk"]) / cow_days if cow_days else 0.0
        r["labour"] += dairy_overheads["labour"] * share
        r["power"] += dairy_overheads["power"] * share

    price, basis, sold_l, revenue = _milk_price(db, farm_id, lo, hi)
    farm_saleable = sum(rec.liters for rec, _a in milk_rows if rec.destination != "withheld" and rec.release_status in safety.TANK_STATUSES)

    out_rows = []
    for a_id, r in rows.items():
        animal = r["animal"]
        feed = r["feed_own"] + r["feed_group"]
        costs = feed + r["medicine"] + r["vet_expenses"] + r["labour"] + r["power"]
        value = r["saleable_l"] * price if price is not None else None
        attributed = revenue * r["saleable_l"] / farm_saleable if farm_saleable > EPS and revenue else (0.0 if price is not None else None)
        trend = []
        for wk in sorted(r["_weeks"]):
            w = r["_weeks"][wk]
            wv = w["saleable_l"] * price if price is not None else None
            trend.append({"week": wk, "liters": _r(w["liters"], 1), "feed_cost": _r(w["feed"]), "medicine_cost": _r(w["medicine"]),
                          "margin": _r(wv - w["feed"] - w["medicine"]) if wv is not None else None})
        unknown = []
        if price is None:
            unknown.append("milk_price")
        if r["feed_unpriced_kg"] > EPS:
            unknown.append("feed_without_price")
        if r["medicine_unpriced"]:
            unknown.append("medicine_without_cost")
        out_rows.append({
            "animal_id": animal.id, "tag": animal.tag, "name": animal.name, "species": animal.species,
            "am_l": _r(r["am_l"], 1), "pm_l": _r(r["pm_l"], 1), "total_l": _r(r["total_l"], 1), "saleable_l": _r(r["saleable_l"], 1),
            "days_in_milk": len(r["days_in_milk"]),
            "milk_value": _r(value), "sales_revenue": _r(attributed),
            "feed_kg": _r(r["feed_kg"], 1), "feed_cost": _r(feed), "feed_cost_own": _r(r["feed_own"]), "feed_cost_group": _r(r["feed_group"]),
            "feed_unpriced_kg": _r(r["feed_unpriced_kg"], 1),
            "feed_cost_per_liter": _r(feed / r["total_l"], 3) if r["total_l"] > EPS else None,
            "medicine_cost": _r(r["medicine"]), "vet_expenses": _r(r["vet_expenses"]), "medicine_unpriced_doses": r["medicine_unpriced"],
            "labour_cost": _r(r["labour"]), "power_cost": _r(r["power"]),
            "known_costs": _r(costs), "margin": _r(value - costs) if value is not None else None,
            "margin_per_liter": _r((value - costs) / r["total_l"], 3) if value is not None and r["total_l"] > EPS else None,
            "unknown": unknown, "trend": trend,
        })
    out_rows.sort(key=lambda x: (x["margin"] is None, -(x["margin"] or 0), -(x["total_l"] or 0)))

    def total(key: str) -> float | None:
        vals = [x[key] for x in out_rows]
        return None if any(v is None for v in vals) and vals else _r(sum(v for v in vals if v is not None))

    canonical_milk = sum(rec.liters for rec, a in milk_rows if wanted is None or a.id in wanted)
    return {
        "kind": "profitability", "farm_id": farm_id, "start": start.isoformat(), "end": end.isoformat(), "days": days,
        "scope": {"animal_id": animal_id, "group_id": group_id},
        "milk_price": {"price_per_liter": _r(price, 4), "basis": basis, "liters_sold": _r(sold_l, 1), "revenue": _r(revenue)},
        "animals": out_rows,
        "totals": {
            "total_l": _r(sum(x["total_l"] for x in out_rows), 1), "saleable_l": _r(sum(x["saleable_l"] for x in out_rows), 1),
            "milk_value": total("milk_value"), "sales_revenue": total("sales_revenue"), "feed_cost": total("feed_cost"),
            "medicine_cost": total("medicine_cost"), "vet_expenses": total("vet_expenses"), "labour_cost": total("labour_cost"),
            "power_cost": total("power_cost"), "known_costs": total("known_costs"), "margin": total("margin"),
        },
        "unallocated": {"labour": _r(unallocated["labour"]), "power": _r(unallocated["power"])},
        "reconciliation": {
            "milk_l": {"canonical": _r(canonical_milk, 1), "attributed": _r(sum(x["total_l"] for x in out_rows), 1)},
            "own_feed_cost": {"canonical": _r(own_feed_total), "attributed": _r(sum(x["feed_cost_own"] for x in out_rows))},
            "group_feed_cost": {"canonical": _r(group_feed_total), "attributed_to_these_animals": _r(group_feed_attributed),
                                "to_other_heads": _r(group_feed_total - group_feed_attributed)},
            "dairy_overheads": {"labour": _r(dairy_overheads["labour"]), "power": _r(dairy_overheads["power"]), "shared_by": "days_in_milk"},
        },
        "rules": RULES,
    }
