"""Formulas, mixing batches and nutrient profiles (feed architecture §5–§8).

A formula is a recipe family; a version is one immutable composition; a
batch is one mixing occurrence that consumed real lots and produced a new
lot at a real cost. Target quantities are scaled from the version; actual
quantities are what was weighed — and only the actuals touch inventory
and cost. The version is locked the moment a completed batch refers to
it, so history always resolves to the exact recipe used.
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import feed_models as fm
from app.domain import models
from app.feeding import catalog, uom
from app.repositories.base import new_id, now, write_event
from app.services import feed_inventory_service as inv
from app.services import feed_policy_service as policy
from app.services.feed_inventory_service import FeedError


# -------------------------------------------------------------- formulas
def _validate_components(db: Session, farm_id: str, formula: fm.FeedFormula | None, batch_size: float, unit: str, components: list[dict], *, species_code: str | None, user_id: str) -> list[fm.FeedFormulaComponent]:
    if not components:
        raise FeedError("A formula needs at least one component.")
    if batch_size <= 0:
        raise FeedError("Batch size must be greater than zero.")
    rows = []
    total = 0.0
    for i, c in enumerate(components):
        product = inv.get_product(db, c["feed_product_id"], farm_id)
        if not product.is_ingredient:
            raise FeedError(f"{product.name} is a finished feed, not an ingredient; it cannot go into a formula.")
        qty = float(c.get("target_quantity") or 0)
        c_unit = uom.normalise(c.get("unit") or product.unit)
        if qty <= 0:
            raise FeedError(f"Target quantity for {product.name} must be greater than zero.")
        if not uom.compatible(c_unit, unit):
            raise FeedError(f"{product.name} is measured in {c_unit}; the formula is in {unit}.")
        in_formula_unit = uom.convert(qty, c_unit, unit)
        pct = c.get("target_percentage")
        if pct is None:
            pct = round(in_formula_unit / batch_size * 100, 3)
        # The policy check of §24 at authoring time: a cattle-only premix in
        # a horse formula fails here, before any batch exists.
        policy.check_or_raise(
            db, product, policy.Target(species_code=species_code, label=f"{formula.name if formula else 'this formula'} ({species_code or 'general'})", partial=True),
            inclusion_pct=pct, through_formula=True, context="formula_component", user_id=user_id,
        )
        total += in_formula_unit
        rows.append(fm.FeedFormulaComponent(id=new_id(), feed_product_id=product.id, target_quantity=qty, unit=c_unit, target_percentage=pct, sort_order=i))
    if abs(total - batch_size) > batch_size * 0.02:
        raise FeedError(f"The components add up to {total:.1f} {unit}, not the batch size of {batch_size:.1f} {unit}.")
    return rows


def create_formula(
    db: Session,
    farm_id: str,
    *,
    code: str | None,
    name: str,
    feed_product_id: str,
    species_code: str | None,
    description: str | None,
    batch_size: float,
    unit: str,
    components: list[dict],
    notes: str | None = None,
    activate: bool = True,
    user_id: str,
) -> fm.FeedFormula:
    product = inv.get_product(db, feed_product_id, farm_id)
    if product.source_type != "farm_produced":
        raise FeedError(f"{product.name} is a purchased feed; a formula describes a farm-produced one. Feed it directly (§22).")
    unit = uom.normalise(unit or product.unit)
    formula = fm.FeedFormula(
        id=new_id(), farm_id=farm_id, code=inv.unique_code(db, farm_id, inv.slug(code or name)) if _formula_code_taken(db, farm_id, code) else (code or inv.slug(name)),
        name=name, feed_product_id=product.id, species_code=species_code, status="active", description=description, created_at=now(),
    )
    db.add(formula)
    db.flush()
    add_version(db, formula, batch_size=batch_size, unit=unit, components=components, notes=notes, activate=activate, user_id=user_id)
    return formula


def _formula_code_taken(db: Session, farm_id: str, code: str | None) -> bool:
    if not code:
        return True
    return db.scalar(select(fm.FeedFormula.id).where(fm.FeedFormula.farm_id == farm_id, fm.FeedFormula.code == code)) is not None


def add_version(
    db: Session,
    formula: fm.FeedFormula,
    *,
    batch_size: float,
    unit: str | None,
    components: list[dict],
    notes: str | None = None,
    activate: bool = True,
    user_id: str,
) -> fm.FeedFormulaVersion:
    """A new composition. The previous version is untouched — retired if
    this one is activated, still referenced by every batch it made."""
    unit = uom.normalise(unit or (formula.versions[-1].unit if formula.versions else "kg"))
    rows = _validate_components(db, formula.farm_id, formula, batch_size, unit, components, species_code=formula.species_code, user_id=user_id)
    next_version = (max((v.version for v in formula.versions), default=0)) + 1
    version = fm.FeedFormulaVersion(
        id=new_id(), formula_id=formula.id, version=next_version, status="draft", batch_size=batch_size, unit=unit,
        notes=notes, created_by=user_id, created_at=now(),
    )
    version.components.extend(rows)
    db.add(version)
    formula.versions.append(version)
    db.flush()
    if activate:
        activate_version(db, version, user_id=user_id)
    return version


def activate_version(db: Session, version: fm.FeedFormulaVersion, *, user_id: str) -> fm.FeedFormulaVersion:
    formula = version.formula
    for other in formula.versions:
        if other.id != version.id and other.status == "active":
            other.status = "retired"
            other.effective_to = now()
    version.status = "active"
    version.effective_from = now()
    version.effective_to = None
    write_event(
        db, farm_id=formula.farm_id, entity_type="feed_formula", entity_id=formula.id, event_type="feed_formula_version_activated",
        payload={"version_id": version.id, "version": version.version, "batch_size": version.batch_size, "unit": version.unit}, created_by=user_id,
    )
    return version


def assert_editable(version: fm.FeedFormulaVersion) -> None:
    if version.locked:
        raise FeedError(f"Version {version.version} has been used by a completed batch and cannot be changed — create a new version.")


def scale(version: fm.FeedFormulaVersion, batch_size: float, unit: str | None = None) -> list[dict]:
    """The version's targets at another batch size (§17 mixing screen)."""
    unit = uom.normalise(unit or version.unit)
    factor = uom.convert(batch_size, unit, version.unit) / version.batch_size
    return [
        {"feed_product_id": c.feed_product_id, "target_quantity": round(c.target_quantity * factor, 3), "unit": c.unit,
         "target_percentage": c.target_percentage}
        for c in version.components
    ]


def planned_cost(db: Session, version: fm.FeedFormulaVersion, batch_size: float, unit: str | None = None) -> float | None:
    total = 0.0
    known = False
    for line in scale(version, batch_size, unit):
        product = db.get(fm.FeedProduct, line["feed_product_id"])
        item = db.get(models.InventoryItem, product.inventory_item_id) if product else None
        cost = inv.unit_cost_of(None, product, item) if product else None
        if cost is None:
            continue
        known = True
        total += uom.convert(line["target_quantity"], line["unit"], product.unit) * cost
    return round(total, 4) if known else None


# --------------------------------------------------------------- batches
def _unique_batch_code(db: Session, farm_id: str, base: str) -> str:
    code, n = base, 2
    while db.scalar(select(fm.FeedBatch.id).where(fm.FeedBatch.farm_id == farm_id, fm.FeedBatch.batch_code == code)):
        code = f"{base}-{n}"
        n += 1
    return code


def start_batch(
    db: Session,
    farm_id: str,
    *,
    formula_version_id: str | None,
    formula_id: str | None,
    batch_code: str | None,
    target_quantity: float,
    unit: str | None,
    notes: str | None,
    user_id: str,
) -> fm.FeedBatch:
    """Opens a mixing batch from the active formula version, with scaled
    targets. Re-runs the usage-policy check on every component (§33: the
    restriction is revalidated when the physical batch is created)."""
    version: fm.FeedFormulaVersion | None = None
    if formula_version_id:
        version = db.get(fm.FeedFormulaVersion, formula_version_id)
    elif formula_id:
        formula = db.get(fm.FeedFormula, formula_id)
        if formula is None or formula.farm_id != farm_id:
            raise FeedError("Formula not found", 404)
        version = next((v for v in formula.versions if v.status == "active"), None)
        if version is None:
            raise FeedError(f"{formula.name} has no active version.")
    if version is None or version.formula.farm_id != farm_id:
        raise FeedError("Formula version not found", 404)
    if version.status != "active":
        raise FeedError(f"{version.formula.name} v{version.version} is {version.status}; mix from the active version.")
    if target_quantity <= 0:
        raise FeedError("Target quantity must be greater than zero.")
    unit = uom.normalise(unit or version.unit)
    formula = version.formula
    product = db.get(fm.FeedProduct, formula.feed_product_id)
    when = now()
    batch = fm.FeedBatch(
        id=new_id(), farm_id=farm_id, feed_product_id=product.id, formula_version_id=version.id,
        batch_code=_unique_batch_code(db, farm_id, batch_code or f"MIX-{when:%Y%m%d}-{formula.code}"),
        status="in_progress", target_quantity=target_quantity, unit=unit, planned_cost=planned_cost(db, version, target_quantity, unit),
        started_at=when, mixed_by=user_id, notes=notes, created_at=when,
    )
    for line in scale(version, target_quantity, unit):
        component = inv.get_product(db, line["feed_product_id"], farm_id)
        policy.check_or_raise(db, component, policy.Target(species_code=formula.species_code, label=f"batch of {formula.name}", partial=True),
                              inclusion_pct=line["target_percentage"], through_formula=True, context="batch_start", user_id=user_id)
        batch.components.append(fm.FeedBatchComponent(
            id=new_id(), feed_product_id=component.id, target_quantity=line["target_quantity"], unit=line["unit"],
            unit_cost=inv.unit_cost_of(None, component, db.get(models.InventoryItem, component.inventory_item_id)),
        ))
    db.add(batch)
    db.flush()
    write_event(
        db, farm_id=farm_id, entity_type="feed_batch", entity_id=batch.id, event_type="feed_batch_started",
        payload={"batch_code": batch.batch_code, "formula": formula.code, "version": version.version, "target_quantity": target_quantity, "unit": unit},
        created_by=user_id,
    )
    return batch


def complete_batch(
    db: Session,
    batch: fm.FeedBatch,
    *,
    actuals: list[dict],
    actual_quantity: float,
    produced_at: datetime | None = None,
    lot_code: str | None = None,
    expiry_date: datetime | None = None,
    notes: str | None = None,
    allow_negative: bool = False,
    user_id: str,
) -> fm.FeedBatch:
    """§7: the actual weighed quantities consume inventory (from the lots
    named, else FIFO), cost the batch, and produce the output lot. Targets
    stay on the components for variance. Locks the formula version."""
    if batch.status not in ("planned", "in_progress"):
        raise FeedError(f"Batch {batch.batch_code} is {batch.status}.")
    if actual_quantity <= 0:
        raise FeedError("Actual quantity produced must be greater than zero.")
    version = db.get(fm.FeedFormulaVersion, batch.formula_version_id) if batch.formula_version_id else None
    formula = version.formula if version else None
    provided = {a["feed_product_id"]: a for a in actuals}
    targets = {c.feed_product_id: c for c in batch.components}
    missing = [targets[p].feed_product_id for p in targets if p not in provided]
    if missing:
        names = ", ".join(db.get(fm.FeedProduct, p).name for p in missing)
        raise FeedError(f"Actual quantities are missing for: {names}. Record zero explicitly if none was used.")

    when = produced_at or now()
    new_components: list[fm.FeedBatchComponent] = []
    total_cost = 0.0
    cost_known = False
    total_in = 0.0
    for product_id, a in provided.items():
        product = inv.get_product(db, product_id, batch.farm_id)
        qty = float(a.get("actual_quantity") or 0)
        unit = uom.normalise(a.get("unit") or product.unit)
        target = targets.get(product_id)
        if qty < 0:
            raise FeedError(f"Actual quantity for {product.name} cannot be negative.")
        in_batch_unit = uom.convert(qty, unit, batch.unit)
        pct = in_batch_unit / actual_quantity * 100 if actual_quantity else None
        policy.check_or_raise(db, product, policy.Target(species_code=formula.species_code if formula else None, label=f"batch {batch.batch_code}", partial=True),
                              inclusion_pct=pct, through_formula=True, context="batch_complete", user_id=user_id)
        if qty == 0:
            new_components.append(fm.FeedBatchComponent(id=new_id(), feed_product_id=product.id, lot_id=None, target_quantity=target.target_quantity if target else None, actual_quantity=0, unit=unit, unit_cost=None, cost=0))
            continue
        draws = inv.consume(db, product, qty, unit, reason="mixing", linked_entity_type="feed_batch", linked_entity_id=batch.id,
                            lot_id=a.get("lot_id"), allow_negative=allow_negative, user_id=user_id, occurred_at=when)
        first = True
        for d in draws:
            new_components.append(fm.FeedBatchComponent(
                id=new_id(), feed_product_id=product.id, lot_id=d.lot.id if d.lot else None,
                target_quantity=(uom.convert(target.target_quantity, target.unit, product.unit) if (target and first) else None),
                actual_quantity=round(d.quantity, 3), unit=product.unit, unit_cost=d.unit_cost, cost=d.cost,
            ))
            first = False
            if d.cost is not None:
                cost_known = True
                total_cost += d.cost
        total_in += in_batch_unit
    if abs(total_in - actual_quantity) > max(actual_quantity * 0.1, 1):
        raise FeedError(f"The ingredients weigh {total_in:.1f} {batch.unit} but the batch is recorded as {actual_quantity:.1f} {batch.unit} — check the quantities.")
    batch.components.clear()
    db.flush()
    batch.components.extend(new_components)
    batch.actual_quantity = actual_quantity
    batch.actual_cost = round(total_cost, 4) if cost_known else None
    batch.unit_cost = round(total_cost / actual_quantity, 6) if cost_known else None
    batch.produced_at = when
    batch.status = "completed"
    if notes:
        batch.notes = (batch.notes + "\n" if batch.notes else "") + notes
    if version is not None:
        version.locked = True
    output = db.get(fm.FeedProduct, batch.feed_product_id)
    lot = inv.receive(
        db, output, quantity=actual_quantity, unit=batch.unit, unit_cost=batch.unit_cost, lot_code=lot_code or batch.batch_code,
        source_type="farm_produced", expiry_date=expiry_date, feed_batch_id=batch.id, received_at=when,
        notes=f"Produced by batch {batch.batch_code}", user_id=user_id,
    )
    batch.output_lot_id = lot.id
    write_event(
        db, farm_id=batch.farm_id, entity_type="feed_batch", entity_id=batch.id, event_type="feed_batch_completed",
        payload={"batch_code": batch.batch_code, "actual_quantity": actual_quantity, "unit": batch.unit, "actual_cost": batch.actual_cost,
                 "unit_cost": batch.unit_cost, "output_lot_id": lot.id, "formula_version_id": batch.formula_version_id},
        created_by=user_id,
    )
    return batch


def quarantine_batch(db: Session, batch: fm.FeedBatch, *, reason: str, user_id: str) -> fm.FeedBatch:
    if batch.status != "completed":
        raise FeedError("Only a completed batch can be quarantined.")
    batch.status = "quarantined"
    if batch.output_lot_id:
        lot = db.get(fm.FeedLot, batch.output_lot_id)
        if lot is not None:
            inv.set_lot_status(db, lot, "quarantined", reason=reason, user_id=user_id)
    write_event(db, farm_id=batch.farm_id, entity_type="feed_batch", entity_id=batch.id, event_type="feed_batch_quarantined",
                payload={"reason": reason}, created_by=user_id)
    return batch


def batch_variance(batch: fm.FeedBatch) -> list[dict]:
    by_product: dict[str, dict] = {}
    for c in batch.components:
        e = by_product.setdefault(c.feed_product_id, {"feed_product_id": c.feed_product_id, "target": 0.0, "actual": 0.0, "unit": c.unit, "lots": []})
        e["target"] += c.target_quantity or 0
        e["actual"] += c.actual_quantity or 0
        if c.lot_id:
            e["lots"].append(c.lot_id)
    for e in by_product.values():
        e["variance"] = round(e["actual"] - e["target"], 3)
        e["variance_pct"] = round((e["actual"] - e["target"]) / e["target"] * 100, 2) if e["target"] else None
    return list(by_product.values())


# ------------------------------------------------------------- nutrients
def record_profile(
    db: Session,
    farm_id: str,
    *,
    subject_type: str,
    subject_id: str,
    basis: str,
    source_type: str,
    values: list[dict],
    reference: str | None = None,
    effective_at: datetime | None = None,
    user_id: str,
) -> fm.FeedNutrientProfile:
    if subject_type not in catalog.PROFILE_SUBJECTS:
        raise FeedError(f"subject_type must be one of {list(catalog.PROFILE_SUBJECTS)}")
    if basis not in catalog.BASES:
        raise FeedError(f"basis must be one of {list(catalog.BASES)}")
    if source_type not in catalog.PROFILE_SOURCES:
        raise FeedError(f"source_type must be one of {list(catalog.PROFILE_SOURCES)}")
    if not values:
        raise FeedError("A nutrient profile needs at least one value.")
    profile = fm.FeedNutrientProfile(
        id=new_id(), farm_id=farm_id, subject_type=subject_type, subject_id=subject_id, basis=basis, source_type=source_type,
        reference=reference, effective_at=effective_at or now(), created_by=user_id, created_at=now(),
    )
    for v in values:
        nutrient = db.get(fm.FeedNutrient, v["nutrient_code"])
        if nutrient is None:
            raise FeedError(f"Unknown nutrient {v['nutrient_code']}; add it to the catalog first.")
        profile.values.append(fm.FeedNutrientValue(id=new_id(), nutrient_code=nutrient.code, value=float(v["value"]), unit=v.get("unit") or nutrient.unit))
    db.add(profile)
    db.flush()
    write_event(
        db, farm_id=farm_id, entity_type=subject_type, entity_id=subject_id,
        event_type="feed_analysis_received" if source_type == "lab" else "feed_nutrient_profile_recorded",
        payload={"profile_id": profile.id, "basis": basis, "source_type": source_type, "reference": reference, "values": len(values)},
        created_by=user_id,
    )
    return profile


_SOURCE_RANK = {"lab": 0, "declared": 1, "calculated": 2}


def latest_profile(db: Session, subject_type: str, subject_id: str, *, basis: str | None = None) -> fm.FeedNutrientProfile | None:
    """The profile to trust: the newest lab result, else the declared one,
    else a calculation — never a lab result overwritten by a declaration."""
    rows = db.scalars(select(fm.FeedNutrientProfile).where(fm.FeedNutrientProfile.subject_type == subject_type, fm.FeedNutrientProfile.subject_id == subject_id)).all()
    if basis:
        rows = [r for r in rows if r.basis == basis]
    if not rows:
        return None
    rows.sort(key=lambda r: (_SOURCE_RANK.get(r.source_type, 9), -r.effective_at.timestamp()))
    return rows[0]


def profile_to_dict(p: fm.FeedNutrientProfile) -> dict:
    return {
        "id": p.id, "subject_type": p.subject_type, "subject_id": p.subject_id, "basis": p.basis, "source_type": p.source_type,
        "reference": p.reference, "effective_at": p.effective_at,
        "values": [{"nutrient_code": v.nutrient_code, "value": v.value, "unit": v.unit} for v in p.values],
    }


def formula_nutrients(db: Session, version: fm.FeedFormulaVersion, *, basis: str = "as_fed") -> dict:
    """Weighted average of the components' profiles (§8) — a calculated
    profile, reported with its coverage so a missing ingredient analysis
    is visible rather than silently treated as zero."""
    total = 0.0
    covered = 0.0
    sums: dict[str, dict] = {}
    missing: list[str] = []
    for c in version.components:
        product = db.get(fm.FeedProduct, c.feed_product_id)
        weight = uom.convert(c.target_quantity, c.unit, version.unit)
        total += weight
        profile = latest_profile(db, "feed_product", c.feed_product_id, basis=basis)
        if profile is None:
            missing.append(product.name if product else c.feed_product_id)
            continue
        covered += weight
        for v in profile.values:
            entry = sums.setdefault(v.nutrient_code, {"nutrient_code": v.nutrient_code, "weighted": 0.0, "weight": 0.0, "unit": v.unit})
            entry["weighted"] += v.value * weight
            entry["weight"] += weight
    values = [
        {"nutrient_code": code, "value": round(e["weighted"] / e["weight"], 3), "unit": e["unit"], "coverage_pct": round(e["weight"] / total * 100, 1) if total else 0}
        for code, e in sums.items()
    ]
    return {"formula_version_id": version.id, "basis": basis, "source_type": "calculated", "coverage_pct": round(covered / total * 100, 1) if total else 0,
            "missing_profiles": missing, "values": values}
