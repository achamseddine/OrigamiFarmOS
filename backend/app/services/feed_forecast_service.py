"""Days of cover, demand forecast, replenishment and reconciliation (feed
architecture §27–§29), and the cost view (§20).

    days of cover = usable, eligible stock / forecast daily requirement

"Usable" excludes quarantined, blocked, recalled and expired lots and
stock reserved for another purpose; "eligible" means the demand's species
is allowed to have it. Demand comes from the active programs and head
counts when there are any, and from recent consumption when there are
not — and the answer says which. A breach raises a reorder recommendation
with the reasoning attached; acknowledging it opens the procurement task.
Nothing here creates or approves a purchase.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core import permissions as perms
from app.domain import feed_models as fm
from app.domain import models
from app.feeding import uom
from app.repositories.base import ensure_utc, new_id, now, write_event
from app.services import feed_inventory_service as inv
from app.services import feed_policy_service as policy
from app.services import feeding_program_service as programs
from app.services.feed_inventory_service import FeedError

HISTORY_DAYS = 14


def _historic_daily_usage(db: Session, item_id: str, days: int = HISTORY_DAYS) -> float | None:
    since = now() - timedelta(days=days)
    rows = db.scalars(select(models.InventoryTransaction).where(
        models.InventoryTransaction.item_id == item_id, models.InventoryTransaction.direction == "out",
        models.InventoryTransaction.created_at >= since,
        models.InventoryTransaction.reason.in_(["feeding", "daily_feeding", "supplemental_feeding", "mixing"]),
    )).all()
    if not rows:
        return None
    return sum(r.quantity for r in rows) / days


def _policy_for(db: Session, product_id: str) -> fm.FeedReorderPolicy | None:
    return db.scalar(select(fm.FeedReorderPolicy).where(fm.FeedReorderPolicy.feed_product_id == product_id, fm.FeedReorderPolicy.active.is_(True)))


def cover_for_products(db: Session, farm_id: str, *, products: list[fm.FeedProduct] | None = None) -> list[dict]:
    """§28.2 for every active product: stock by category, demand and its
    source, days of cover, the reorder policy and the status the two imply."""
    demand = programs.demand_by_product(db, farm_id)
    rows = products if products is not None else list(db.scalars(select(fm.FeedProduct).where(fm.FeedProduct.farm_id == farm_id, fm.FeedProduct.status == "active")))
    out = []
    for product in rows:
        avail = inv.availability(db, product)
        item = db.get(models.InventoryItem, product.inventory_item_id)
        d = demand.get(product.id)
        daily = d["daily_quantity"] if d else None
        source = "programs" if d else None
        if daily is None and item is not None:
            hist = _historic_daily_usage(db, item.id)
            if hist:
                daily, source = round(hist, 3), "history"
        warnings: list[str] = []
        eligible_available = avail.available
        binding_species = None
        if d:
            # Eligibility per species: policy blocks and reservations for
            # other species shrink what this species can draw on.
            per_species = []
            for species, qty in d["by_species"].items():
                decision = policy.evaluate(db, product, policy.Target(species_code=species, partial=True), through_formula=True)
                if not decision.allowed:
                    warnings.append(f"{qty:.1f} {uom.describe(product.unit)}/day of demand from {species.replace('_', ' ')} cannot be met by {product.name}: {decision.reasons[0]}")
                    continue
                species_avail = inv.availability(db, product, inv.Purpose(species_code=species)).available
                per_species.append((species, qty, species_avail))
            if per_species:
                cover_by_species = [(s, (a / q) if q else None) for s, q, a in per_species]
                worst = min((c for c in cover_by_species if c[1] is not None), key=lambda c: c[1], default=None)
                if worst is not None:
                    binding_species = worst[0]
                    eligible_available = next(a for s, q, a in per_species if s == worst[0])
        days = None
        if daily and daily > 0:
            days = round(eligible_available / daily, 1)
        pol = _policy_for(db, product.id)
        lead = pol.lead_time_days if pol and pol.lead_time_days is not None else None
        margin = pol.cover_margin_days if pol else 3
        stockout_at = (now() + timedelta(days=days)) if days is not None else None
        status = "ok"
        reasons = []
        if pol and pol.minimum_stock is not None and avail.available < pol.minimum_stock:
            status, reasons = "below_minimum", reasons + [f"available {avail.available:.0f} < minimum {pol.minimum_stock:.0f}"]
        if pol and pol.reorder_point is not None and avail.available <= pol.reorder_point:
            status = "below_minimum" if status == "below_minimum" else "reorder"
            reasons.append(f"available {avail.available:.0f} ≤ reorder point {pol.reorder_point:.0f}")
        if days is not None and lead is not None and days < lead + margin:
            status = "stockout_risk" if status in ("ok", "reorder") else status
            reasons.append(f"{days} days of cover < lead time {lead} d + {margin} d margin")
        if daily is None:
            status = status if status != "ok" else "no_demand"
        out.append({
            "feed_product_id": product.id, "code": product.code, "name": product.name, "unit": product.unit, "source_type": product.source_type,
            "on_hand": round(avail.on_hand, 3), "unusable": round(avail.unusable, 3), "reserved": round(avail.reserved, 3),
            "available": round(avail.available, 3), "eligible_available": round(eligible_available, 3), "binding_species": binding_species,
            "daily_demand": daily, "demand_source": source, "demand_by_species": d["by_species"] if d else {},
            "days_of_cover": days, "projected_stockout_at": stockout_at, "lead_time_days": lead,
            "reorder_policy": None if pol is None else {
                "id": pol.id, "minimum_stock": pol.minimum_stock, "reorder_point": pol.reorder_point, "safety_stock": pol.safety_stock,
                "preferred_reorder_quantity": pol.preferred_reorder_quantity, "maximum_stock": pol.maximum_stock, "lead_time_days": pol.lead_time_days,
                "cover_margin_days": pol.cover_margin_days,
            },
            "status": status, "reasons": reasons, "warnings": warnings,
            "reorder_level_legacy": item.reorder_level if item else None,
        })
    return out


def forecast(db: Session, farm_id: str, *, horizon_days: int = 14, persist: bool = True) -> list[dict]:
    """§28.3: programs × head counts × formula requirements over the
    horizon, plus safety stock, minus eligible stock (no confirmed incoming
    supply exists in this codebase yet) = projected procurement need."""
    rows = cover_for_products(db, farm_id)
    out = []
    start = now()
    for r in rows:
        daily = r["daily_demand"] or 0.0
        pol = r["reorder_policy"] or {}
        safety = pol.get("safety_stock") or 0.0
        need = daily * horizon_days + safety - r["eligible_available"]
        suggested = 0.0
        if need > 0 or r["status"] in ("reorder", "below_minimum", "stockout_risk"):
            suggested = max(need, pol.get("preferred_reorder_quantity") or 0.0, 0.0)
            if pol.get("maximum_stock"):
                suggested = min(suggested, max(pol["maximum_stock"] - r["available"], 0))
        entry = {**r, "horizon_days": horizon_days, "forecast_quantity": round(daily * horizon_days, 3), "safety_stock": safety,
                 "projected_requirement": round(max(need, 0), 3), "suggested_reorder_quantity": round(suggested, 1)}
        out.append(entry)
        if persist:
            db.add(fm.FeedDemandForecast(
                id=new_id(), farm_id=farm_id, feed_product_id=r["feed_product_id"], forecast_from=start, forecast_to=start + timedelta(days=horizon_days),
                daily_demand=daily, forecast_quantity=daily * horizon_days, available_quantity=r["eligible_available"], days_of_cover=r["days_of_cover"],
                projected_stockout_at=r["projected_stockout_at"], suggested_reorder_quantity=suggested, unit=r["unit"], generated_at=start,
                basis_json={"demand_source": r["demand_source"], "by_species": r["demand_by_species"], "status": r["status"], "reasons": r["reasons"]},
            ))
    return out


def _programs_affected(db: Session, farm_id: str, product_id: str) -> list[str]:
    names = set()
    for v in programs.active_versions(db, farm_id):
        if any(c.feed_product_id == product_id for c in v.components):
            names.add(v.program.name)
    return sorted(names)


def open_reorder_task(db: Session, product_id: str) -> models.Task | None:
    return db.scalar(select(models.Task).where(models.Task.source_type == "feed_reorder", models.Task.source_id == product_id, models.Task.status != "done"))


def reorder_recommendations(db: Session, farm_id: str) -> list[dict]:
    """§29: what to reorder, how much, and why — with the livestock and
    programs at risk. A product already covered by an open replenishment
    task is reported as covered rather than alerted again."""
    out = []
    for r in forecast(db, farm_id, persist=False):
        if r["status"] not in ("reorder", "below_minimum", "stockout_risk"):
            continue
        task = open_reorder_task(db, r["feed_product_id"])
        priority = "high" if r["status"] in ("below_minimum", "stockout_risk") else "medium"
        if r["days_of_cover"] is not None and r["days_of_cover"] <= 2:
            priority = "critical"
        out.append({
            **r,
            "priority": priority,
            "programs_affected": _programs_affected(db, farm_id, r["feed_product_id"]),
            "covered_by_task_id": task.id if task else None,
            "covered_by_task_title": task.title if task else None,
        })
    return out


def acknowledge_reorder(db: Session, farm_id: str, product: fm.FeedProduct, *, quantity: float | None, note: str | None, assigned_to: str | None, user_id: str) -> models.Task:
    """The handoff into procurement: a requisition task the manager owns.
    Creating or approving a purchase order is still a human decision."""
    existing = open_reorder_task(db, product.id)
    if existing is not None:
        return existing
    cover = next((r for r in cover_for_products(db, farm_id, products=[product])), None)
    qty = quantity
    if qty is None and cover:
        qty = forecast(db, farm_id, persist=False)
        qty = next((f["suggested_reorder_quantity"] for f in qty if f["feed_product_id"] == product.id), None)
    task = models.Task(
        id=new_id(), farm_id=farm_id, title=f"Reorder {product.name}" + (f" — {qty:.0f} {uom.describe(product.unit)}" if qty else ""),
        description=(note or "") + (f"\nAvailable {cover['available']:.0f} {uom.describe(product.unit)}, {cover['days_of_cover']} days of cover, "
                                    f"lead time {cover['lead_time_days'] or '?'} d. Programs affected: {', '.join(_programs_affected(db, farm_id, product.id)) or 'none'}." if cover else ""),
        assigned_to=assigned_to, due_at=now() + timedelta(days=1), priority="high", status="open", source_type="feed_reorder", source_id=product.id,
    )
    db.add(task)
    write_event(db, farm_id=farm_id, entity_type="feed_product", entity_id=product.id, event_type="feed_reorder_acknowledged",
                payload={"task_id": task.id, "quantity": qty, "note": note}, created_by=user_id)
    return task


def reorder_signals(db: Session, farm_id: str) -> list:
    """For the notification bell (§29): one signal per product at risk,
    suppressed while a replenishment task covers it."""
    from app.services.signals_service import Signal  # local import: signals imports this module

    signals = []
    for r in reorder_recommendations(db, farm_id):
        if r["covered_by_task_id"]:
            continue
        unit = uom.describe(r["unit"])
        when = r["projected_stockout_at"]
        title = f"Reorder {r['name']}" if r["status"] == "reorder" else f"Stockout risk: {r['name']}"
        parts = [f"{r['available']:.0f} {unit} available"]
        if r["reserved"]:
            parts.append(f"{r['reserved']:.0f} reserved")
        if r["days_of_cover"] is not None:
            parts.append(f"{r['days_of_cover']} days of cover")
        if r["lead_time_days"] is not None:
            parts.append(f"lead time {r['lead_time_days']} d")
        if when is not None:
            parts.append(f"runs out ~{ensure_utc(when):%d %b}")
        if r["suggested_reorder_quantity"]:
            parts.append(f"suggest {r['suggested_reorder_quantity']:.0f} {unit}")
        if r["programs_affected"]:
            parts.append("affects " + ", ".join(r["programs_affected"]))
        signals.append(Signal(
            source_type="feed_reorder", source_id=r["feed_product_id"], module_code=perms.FEED_NUTRITION,
            notification_type="feed_reorder_required", title=title, description=" · ".join(parts), priority=r["priority"],
            entity_type="feed_product", entity_id=r["feed_product_id"],
            metadata={k: r[k] for k in ("available", "reserved", "daily_demand", "days_of_cover", "lead_time_days", "suggested_reorder_quantity", "programs_affected", "status")},
        ))
    return signals


# --------------------------------------------------------- reconciliation
_RECEIPT_REASONS = {"purchase", "production", "opening_balance"}
_BATCH_REASONS = {"mixing"}
_FEEDING_REASONS = {"feeding", "daily_feeding", "supplemental_feeding"}
_WASTE_REASONS = {"waste"}
_RETURN_REASONS = {"return", "feeding_reversal"}
_ADJUST_REASONS = {"adjustment", "reconciliation_adjustment", "count_correction"}


def reconcile(
    db: Session,
    farm_id: str,
    product: fm.FeedProduct,
    *,
    lot: fm.FeedLot | None,
    period_from: datetime,
    period_to: datetime,
    counted_closing_quantity: float | None,
    explanation: str | None,
    user_id: str,
) -> fm.FeedReconciliation:
    """§27: every movement in the period by category, the closing balance
    the ledger implies, and — if a count was given — the variance."""
    if period_to <= period_from:
        raise FeedError("period_to must be after period_from.")
    q = select(models.InventoryTransaction).where(models.InventoryTransaction.item_id == product.inventory_item_id)
    if lot is not None:
        q = q.where(models.InventoryTransaction.lot_id == lot.id)
    rows = db.scalars(q).all()
    current = lot.quantity_on_hand if lot is not None else (db.get(models.InventoryItem, product.inventory_item_id).current_qty or 0)

    def signed(tx) -> float:
        return tx.quantity if tx.direction == "in" else -tx.quantity

    after = sum(signed(t) for t in rows if ensure_utc(t.created_at) > period_to)
    within = [t for t in rows if period_from <= ensure_utc(t.created_at) <= period_to]
    closing_book = current - after
    opening = closing_book - sum(signed(t) for t in within)
    rec = fm.FeedReconciliation(
        id=new_id(), farm_id=farm_id, feed_product_id=product.id, lot_id=lot.id if lot else None, period_from=period_from, period_to=period_to,
        opening_quantity=round(opening, 3), received_quantity=0.0, issued_to_batches=0.0, issued_to_feeding=0.0, other_issued_quantity=0.0,
        waste_quantity=0.0, returned_quantity=0.0, adjustment_quantity=0.0, expected_closing_quantity=0.0,
        unit=product.unit, status="open", explanation=explanation, created_by=user_id, created_at=now(),
    )
    for t in within:
        r = t.reason or ""
        if t.direction == "in" and r in _RECEIPT_REASONS:
            rec.received_quantity += t.quantity
        elif t.direction == "in" and r in _RETURN_REASONS:
            rec.returned_quantity += t.quantity
        elif r in _ADJUST_REASONS:
            rec.adjustment_quantity += signed(t)
        elif t.direction == "out" and r in _BATCH_REASONS:
            rec.issued_to_batches += t.quantity
        elif t.direction == "out" and r in _FEEDING_REASONS:
            rec.issued_to_feeding += t.quantity
        elif t.direction == "out" and r in _WASTE_REASONS:
            rec.waste_quantity += t.quantity
        elif t.direction == "out":
            rec.other_issued_quantity += t.quantity
        else:
            rec.adjustment_quantity += t.quantity
    rec.expected_closing_quantity = round(
        rec.opening_quantity + rec.received_quantity + rec.returned_quantity + rec.adjustment_quantity
        - rec.issued_to_batches - rec.issued_to_feeding - rec.waste_quantity - rec.other_issued_quantity, 3,
    )
    if counted_closing_quantity is not None:
        rec.counted_closing_quantity = counted_closing_quantity
        rec.variance_quantity = round(counted_closing_quantity - rec.expected_closing_quantity, 3)
        base = rec.expected_closing_quantity or rec.received_quantity or 1
        rec.variance_pct = round(rec.variance_quantity / base * 100, 2)
    db.add(rec)
    db.flush()
    pol = _policy_for(db, product.id)
    threshold = pol.variance_threshold_pct if pol else 5.0
    if rec.variance_pct is not None and abs(rec.variance_pct) > threshold:
        write_event(
            db, farm_id=farm_id, entity_type="feed_product", entity_id=product.id, event_type="feed_inventory_variance_detected",
            payload={"reconciliation_id": rec.id, "variance_quantity": rec.variance_quantity, "variance_pct": rec.variance_pct, "threshold_pct": threshold, "lot_id": rec.lot_id},
            created_by=user_id,
        )
    return rec


def close_reconciliation(db: Session, rec: fm.FeedReconciliation, *, post_adjustment: bool, explanation: str | None, user_id: str) -> fm.FeedReconciliation:
    """Closing with `post_adjustment` writes the variance as an auditable
    `reconciliation_adjustment` movement — never as consumption or waste."""
    if rec.status == "closed":
        raise FeedError("This reconciliation is already closed.")
    product = db.get(fm.FeedProduct, rec.feed_product_id)
    if post_adjustment:
        if rec.variance_quantity is None:
            raise FeedError("No count was recorded, so there is no variance to post.")
        if abs(rec.variance_quantity) > 0.0005:
            lot = db.get(fm.FeedLot, rec.lot_id) if rec.lot_id else None
            inv.adjust(db, product, lot=lot, delta=rec.variance_quantity, reason="reconciliation_adjustment",
                       explanation=explanation or rec.explanation or "", user_id=user_id, linked_entity_type="feed_reconciliation", linked_entity_id=rec.id)
    if explanation:
        rec.explanation = explanation
    rec.status = "closed"
    rec.closed_at = now()
    write_event(db, farm_id=rec.farm_id, entity_type="feed_product", entity_id=rec.feed_product_id, event_type="feed_reconciliation_completed",
                payload={"reconciliation_id": rec.id, "variance_quantity": rec.variance_quantity, "posted": post_adjustment}, created_by=user_id)
    return rec


def variance_signals(db: Session, farm_id: str) -> list:
    from app.services.signals_service import Signal

    signals = []
    rows = db.scalars(select(fm.FeedReconciliation).where(fm.FeedReconciliation.farm_id == farm_id, fm.FeedReconciliation.status != "closed")).all()
    for rec in rows:
        if rec.variance_pct is None:
            continue
        pol = _policy_for(db, rec.feed_product_id)
        threshold = pol.variance_threshold_pct if pol else 5.0
        if abs(rec.variance_pct) <= threshold:
            continue
        product = db.get(fm.FeedProduct, rec.feed_product_id)
        signals.append(Signal(
            source_type="feed_reconciliation", source_id=rec.id, module_code=perms.FEED_NUTRITION, notification_type="feed_variance",
            title=f"Unexplained feed variance: {product.name if product else rec.feed_product_id}",
            description=f"{rec.variance_quantity:+.1f} {uom.describe(rec.unit)} ({rec.variance_pct:+.1f}%) against the ledger for the period — review before it is posted.",
            priority="high" if abs(rec.variance_pct) > threshold * 2 else "medium", entity_type="feed_reconciliation", entity_id=rec.id,
            metadata={"variance_quantity": rec.variance_quantity, "variance_pct": rec.variance_pct, "threshold_pct": threshold},
        ))
    return signals


# ------------------------------------------------------------------ costs
def cost_summary(db: Session, farm_id: str, *, days: int = 30) -> dict:
    """Feed cost by subject and by product from the actual feeding events,
    batch costs, and cost per litre of milk where the animal is milked."""
    since = now() - timedelta(days=days)
    events = db.scalars(select(fm.FeedingEvent).where(fm.FeedingEvent.farm_id == farm_id, fm.FeedingEvent.occurred_at >= since, fm.FeedingEvent.status == "recorded")).all()
    by_subject: dict[tuple[str, str], dict] = {}
    by_product: dict[str, dict] = {}
    total = 0.0
    for e in events:
        key = (e.subject_type, e.subject_id)
        s = by_subject.setdefault(key, {"subject_type": e.subject_type, "subject_id": e.subject_id, "cost": 0.0, "events": 0, "quantity": 0.0})
        s["cost"] += e.total_cost or 0
        s["events"] += 1
        for c in e.components:
            s["quantity"] += c.quantity_offered
            p = by_product.setdefault(c.feed_product_id, {"feed_product_id": c.feed_product_id, "cost": 0.0, "quantity": 0.0, "unit": c.unit})
            p["cost"] += c.cost or 0
            p["quantity"] += uom.convert(c.quantity_offered, c.unit, p["unit"])
        total += e.total_cost or 0
    subjects = []
    for (stype, sid), s in by_subject.items():
        row = db.get(models.Animal, sid) if stype == "animal" else db.get(models.Flock, sid)
        s["name"] = getattr(row, "name", None)
        s["species"] = getattr(row, "species", None)
        s["cost"] = round(s["cost"], 2)
        s["quantity"] = round(s["quantity"], 2)
        if stype == "animal":
            liters = db.execute(select(models.MilkRecord.liters).where(models.MilkRecord.animal_id == sid, models.MilkRecord.recorded_at >= since)).scalars().all()
            milk = sum(liters)
            s["milk_liters"] = round(milk, 1)
            s["cost_per_liter"] = round(s["cost"] / milk, 3) if milk else None
        subjects.append(s)
    products = []
    for p in by_product.values():
        product = db.get(fm.FeedProduct, p["feed_product_id"])
        products.append({**p, "name": product.name if product else None, "cost": round(p["cost"], 2), "quantity": round(p["quantity"], 2)})
    batches = db.scalars(select(fm.FeedBatch).where(fm.FeedBatch.farm_id == farm_id, fm.FeedBatch.status == "completed", fm.FeedBatch.produced_at >= since)).all()
    batch_rows = [{"batch_id": b.id, "batch_code": b.batch_code, "feed_product_id": b.feed_product_id, "actual_quantity": b.actual_quantity, "unit": b.unit,
                   "actual_cost": b.actual_cost, "unit_cost": b.unit_cost, "planned_cost": b.planned_cost, "produced_at": b.produced_at} for b in batches]
    return {
        "days": days, "total_feeding_cost": round(total, 2), "daily_average": round(total / days, 2),
        "by_subject": sorted(subjects, key=lambda s: -s["cost"]), "by_product": sorted(products, key=lambda p: -p["cost"]),
        "batches": batch_rows, "batch_cost_total": round(sum(b.actual_cost or 0 for b in batches), 2),
    }
