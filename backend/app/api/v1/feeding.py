"""The generic feed architecture's API (docs/GENERIC-FEED-ARCHITECTURE.md
§15, §31): products and lots, formulas and batches, nutrient profiles,
feeding programs and the resolver, assignments and feeding events,
usage policy, allocations, days of cover / forecast / reorder,
reconciliation and costs.

Every write goes through the services, which refuse with a sentence a
farmer can act on; `FeedError` becomes the HTTP answer in `main.py`.
"""
from __future__ import annotations

from datetime import timedelta

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import require_permission, user_can
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import feed_models as fm
from app.domain import models
from app.repositories.base import ensure_utc, now
from app.schemas.feeding import (
    AdjustmentCreate, AllocationCreate, AllocationOut, AllocationTransfer, AssignmentCreate, AssignmentOut, BatchComplete,
    BatchOut, BatchQuarantine, BatchStart, FeedAvailabilityOut, FeedingEventCreate, FeedingEventOut, FeedingEventReverse, FeedProductCreate,
    FeedProductOut, FeedProductUpdate, FormulaCreate, FormulaOut, FormulaVersionCreate, FormulaVersionOut, FeedLotOut,
    LotReceive, LotStatusUpdate, NutrientOut, NutrientProfileCreate, NutrientProfileOut, PolicyDecisionOut, PolicyOut,
    PolicySet, PolicyValidate, ProgramCreate, ProgramOut, ProgramResolveRequest, ProgramVersionCreate, ProgramVersionOut,
    ReconciliationClose, ReconciliationCreate, ReconciliationOut, ReorderAcknowledge, ReorderPolicyOut, ReorderPolicyUpsert,
)
from app.services import feed_batch_service as batches
from app.services import feed_forecast_service as forecast
from app.services import feed_inventory_service as inv
from app.services import feed_policy_service as policy
from app.services import feeding_program_service as programs
from app.services.feed_inventory_service import FeedError

router = APIRouter(tags=["feeding"])

_view = require_permission(perms.FEED_NUTRITION, perms.VIEW)
_create = require_permission(perms.FEED_NUTRITION, perms.CREATE)
_edit = require_permission(perms.FEED_NUTRITION, perms.EDIT)
_approve = require_permission(perms.FEED_NUTRITION, perms.APPROVE)


# ------------------------------------------------------------ serialisers
def _lot_out(lot: fm.FeedLot) -> dict:
    inv.refresh_lot_status(lot)
    return {
        "id": lot.id, "feed_product_id": lot.feed_product_id, "lot_code": lot.lot_code, "source_type": lot.source_type,
        "supplier_id": lot.supplier_id, "supplier_label": lot.supplier_label, "feed_batch_id": lot.feed_batch_id,
        "received_at": lot.received_at, "expiry_date": lot.expiry_date, "ordered_quantity": lot.ordered_quantity,
        "received_quantity": lot.received_quantity, "accepted_quantity": lot.accepted_quantity, "rejected_quantity": lot.rejected_quantity,
        "quantity_on_hand": round(lot.quantity_on_hand, 3), "unit": lot.unit, "unit_cost": lot.unit_cost, "status": lot.status,
        "reference": lot.reference, "notes": lot.notes,
    }


def _product_out(db: Session, product: fm.FeedProduct) -> dict:
    avail = inv.availability(db, product)
    has_formula = db.scalar(select(fm.FeedFormulaVersion.id).join(fm.FeedFormula).where(
        fm.FeedFormula.feed_product_id == product.id, fm.FeedFormula.status == "active", fm.FeedFormulaVersion.status == "active")) is not None
    return {
        "id": product.id, "farm_id": product.farm_id, "code": product.code, "name": product.name, "name_ar": product.name_ar,
        "source_type": product.source_type, "is_ingredient": product.is_ingredient, "is_feedable": product.is_feedable,
        "category": product.category, "unit": product.unit, "inventory_item_id": product.inventory_item_id,
        "default_unit_cost": product.default_unit_cost, "status": product.status, "notes": product.notes,
        "availability": avail.to_dict(), "policy_names": [p.name for p in policy.policies_for(db, product)], "has_active_formula": has_formula,
    }


def _name(db: Session, product_id: str | None) -> str | None:
    if not product_id:
        return None
    p = db.get(fm.FeedProduct, product_id)
    return p.name if p else None


def _version_out(db: Session, v: fm.FeedFormulaVersion) -> dict:
    return {
        "id": v.id, "formula_id": v.formula_id, "version": v.version, "status": v.status, "batch_size": v.batch_size, "unit": v.unit,
        "effective_from": v.effective_from, "effective_to": v.effective_to, "locked": v.locked, "notes": v.notes, "created_at": v.created_at,
        "components": [{"id": c.id, "feed_product_id": c.feed_product_id, "product_name": _name(db, c.feed_product_id), "target_quantity": c.target_quantity,
                        "unit": c.unit, "target_percentage": c.target_percentage, "sort_order": c.sort_order} for c in v.components],
        "planned_cost": batches.planned_cost(db, v, v.batch_size),
    }


def _formula_out(db: Session, f: fm.FeedFormula) -> dict:
    active = next((v.version for v in f.versions if v.status == "active"), None)
    return {
        "id": f.id, "farm_id": f.farm_id, "code": f.code, "name": f.name, "feed_product_id": f.feed_product_id, "product_name": _name(db, f.feed_product_id),
        "species_code": f.species_code, "status": f.status, "description": f.description, "active_version": active,
        "versions": [_version_out(db, v) for v in f.versions],
    }


def _batch_out(db: Session, b: fm.FeedBatch) -> dict:
    version = db.get(fm.FeedFormulaVersion, b.formula_version_id) if b.formula_version_id else None
    comps = []
    for c in b.components:
        lot = db.get(fm.FeedLot, c.lot_id) if c.lot_id else None
        comps.append({"id": c.id, "feed_product_id": c.feed_product_id, "product_name": _name(db, c.feed_product_id), "lot_id": c.lot_id,
                      "lot_code": lot.lot_code if lot else None, "target_quantity": c.target_quantity, "actual_quantity": c.actual_quantity,
                      "unit": c.unit, "unit_cost": c.unit_cost, "cost": c.cost})
    return {
        "id": b.id, "farm_id": b.farm_id, "feed_product_id": b.feed_product_id, "product_name": _name(db, b.feed_product_id),
        "formula_version_id": b.formula_version_id, "formula_code": version.formula.code if version else None,
        "formula_version": version.version if version else None, "batch_code": b.batch_code, "status": b.status,
        "target_quantity": b.target_quantity, "actual_quantity": b.actual_quantity, "unit": b.unit, "planned_cost": b.planned_cost,
        "actual_cost": b.actual_cost, "unit_cost": b.unit_cost, "output_lot_id": b.output_lot_id, "started_at": b.started_at,
        "produced_at": b.produced_at, "mixed_by": b.mixed_by, "notes": b.notes, "components": comps,
        "variance": batches.batch_variance(b) if b.status in ("completed", "quarantined") else [],
    }


def _program_version_out(db: Session, v: fm.FeedingProgramVersion) -> dict:
    return {
        "id": v.id, "program_id": v.program_id, "version": v.version, "status": v.status, "feedings_per_day": v.feedings_per_day,
        "effective_from": v.effective_from, "effective_to": v.effective_to, "locked": v.locked, "notes": v.notes,
        "components": [{"id": c.id, "feed_product_id": c.feed_product_id, "product_name": _name(db, c.feed_product_id), "quantity_per_head": c.quantity_per_head,
                        "unit": c.unit, "frequency": c.frequency, "timing": c.timing, "notes": c.notes,
                        "daily_per_head": c.quantity_per_head * (v.feedings_per_day if c.frequency == "per_feeding" else 1)} for c in v.components],
        "rules": [{"id": r.id, "species_code": r.species_code, "sex": r.sex, "life_stage": r.life_stage, "management_profile": r.management_profile,
                   "reproductive_state": r.reproductive_state, "lactation_state": r.lactation_state, "production_metric": r.production_metric,
                   "production_min": r.production_min, "production_max": r.production_max, "weight_min": r.weight_min, "weight_max": r.weight_max,
                   "age_min_days": r.age_min_days, "age_max_days": r.age_max_days, "priority": r.priority, "notes": r.notes} for r in v.rules],
    }


def _program_out(db: Session, p: fm.FeedingProgram) -> dict:
    active = next((v.version for v in p.versions if v.status == "active"), None)
    version_ids = [v.id for v in p.versions]
    assigned = db.scalar(select(fm.FeedingAssignment.id).where(fm.FeedingAssignment.program_version_id.in_(version_ids), fm.FeedingAssignment.status == "active").limit(1)) if version_ids else None
    count = len(programs._active(db.scalars(select(fm.FeedingAssignment).where(fm.FeedingAssignment.program_version_id.in_(version_ids), fm.FeedingAssignment.status == "active")).all())) if version_ids else 0
    return {
        "id": p.id, "farm_id": p.farm_id, "code": p.code, "name": p.name, "name_ar": p.name_ar, "category": p.category, "status": p.status,
        "description": p.description, "active_version": active, "versions": [_program_version_out(db, v) for v in p.versions],
        "subjects_assigned": count if assigned else 0,
    }


def _assignment_out(db: Session, a: fm.FeedingAssignment) -> dict:
    v = db.get(fm.FeedingProgramVersion, a.program_version_id) if a.program_version_id else None
    return {
        "id": a.id, "farm_id": a.farm_id, "subject_type": a.subject_type, "subject_id": a.subject_id, "program_version_id": a.program_version_id,
        "program_id": v.program_id if v else None, "program_name": v.program.name if v else None, "program_version": v.version if v else None,
        "assignment_type": a.assignment_type, "feed_product_id": a.feed_product_id, "product_name": _name(db, a.feed_product_id),
        "quantity_per_head": a.quantity_per_head, "unit": a.unit, "reason": a.reason, "valid_from": a.valid_from, "valid_to": a.valid_to,
        "status": a.status, "created_by": a.created_by, "created_at": a.created_at, "ended_at": a.ended_at,
    }


def _allocation_out(db: Session, a: fm.FeedAllocation) -> dict:
    return {
        "id": a.id, "farm_id": a.farm_id, "feed_product_id": a.feed_product_id, "product_name": _name(db, a.feed_product_id), "lot_id": a.lot_id,
        "species_code": a.species_code, "subject_type": a.subject_type, "subject_id": a.subject_id, "feeding_program_id": a.feeding_program_id,
        "location_label": a.location_label, "cost_centre": a.cost_centre, "purpose": a.purpose, "allocated_quantity": a.allocated_quantity,
        "consumed_quantity": a.consumed_quantity, "remaining_quantity": inv.allocation_remaining(a), "unit": a.unit, "transferable": a.transferable,
        "status": a.status, "created_by": a.created_by, "created_at": a.created_at, "released_at": a.released_at,
    }


def _policy_out(p: fm.FeedUsagePolicy) -> dict:
    return {
        "id": p.id, "feed_product_id": p.feed_product_id, "lot_id": p.lot_id, "name": p.name, "requires_approved_formula": p.requires_approved_formula,
        "cross_species_transfer_allowed": p.cross_species_transfer_allowed, "status": p.status, "effective_from": p.effective_from,
        "effective_to": p.effective_to, "notes": p.notes,
        "rules": [{"effect": r.effect, "species_code": r.species_code, "management_profile": r.management_profile, "life_stage": r.life_stage,
                   "reproductive_state": r.reproductive_state, "max_inclusion_pct": r.max_inclusion_pct, "min_age_days": r.min_age_days,
                   "max_age_days": r.max_age_days, "reason": r.reason} for r in p.rules],
    }


def _reorder_policy_out(p: fm.FeedReorderPolicy) -> dict:
    return {
        "id": p.id, "farm_id": p.farm_id, "feed_product_id": p.feed_product_id, "location_label": p.location_label, "minimum_stock": p.minimum_stock,
        "reorder_point": p.reorder_point, "safety_stock": p.safety_stock, "preferred_reorder_quantity": p.preferred_reorder_quantity,
        "maximum_stock": p.maximum_stock, "lead_time_days": p.lead_time_days, "cover_margin_days": p.cover_margin_days,
        "variance_threshold_pct": p.variance_threshold_pct, "active": p.active, "unit": p.unit,
    }


def _reconciliation_out(db: Session, r: fm.FeedReconciliation) -> dict:
    return {
        "id": r.id, "farm_id": r.farm_id, "feed_product_id": r.feed_product_id, "product_name": _name(db, r.feed_product_id), "lot_id": r.lot_id,
        "period_from": r.period_from, "period_to": r.period_to, "opening_quantity": r.opening_quantity, "received_quantity": r.received_quantity,
        "issued_to_batches": r.issued_to_batches, "issued_to_feeding": r.issued_to_feeding, "other_issued_quantity": r.other_issued_quantity,
        "waste_quantity": r.waste_quantity, "returned_quantity": r.returned_quantity, "adjustment_quantity": r.adjustment_quantity,
        "expected_closing_quantity": r.expected_closing_quantity, "counted_closing_quantity": r.counted_closing_quantity,
        "variance_quantity": r.variance_quantity, "variance_pct": r.variance_pct, "unit": r.unit, "status": r.status,
        "explanation": r.explanation, "created_at": r.created_at, "closed_at": r.closed_at,
    }


def _commit(db: Session, obj=None):
    db.commit()
    if obj is not None:
        db.refresh(obj)
    return obj


# --------------------------------------------------------------- products
@router.get("/feed-products", response_model=list[FeedProductOut])
def list_feed_products(include_inactive: bool = False, db: Session = Depends(get_db), user: models.User = Depends(_view)):
    stmt = select(fm.FeedProduct).where(fm.FeedProduct.farm_id == user.farm_id)
    if not include_inactive:
        stmt = stmt.where(fm.FeedProduct.status == "active")
    rows = list(db.scalars(stmt.order_by(fm.FeedProduct.name)))
    out = [_product_out(db, p) for p in rows]
    db.commit()  # opening-balance lots created on read are kept
    return out


@router.post("/feed-products", response_model=FeedProductOut, status_code=status.HTTP_201_CREATED)
def create_feed_product(payload: FeedProductCreate, db: Session = Depends(get_db), user: models.User = Depends(_create)):
    product = inv.create_product(db, user.farm_id, **payload.model_dump(), created_by=user.id)
    _commit(db, product)
    return _product_out(db, product)


@router.get("/feed-products/{product_id}", response_model=FeedProductOut)
def get_feed_product(product_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)):
    product = inv.get_product(db, product_id, user.farm_id)
    out = _product_out(db, product)
    db.commit()
    return out


@router.patch("/feed-products/{product_id}", response_model=FeedProductOut)
def update_feed_product(product_id: str, payload: FeedProductUpdate, db: Session = Depends(get_db), user: models.User = Depends(_edit)):
    product = inv.get_product(db, product_id, user.farm_id)
    changes = payload.model_dump(exclude_unset=True)
    if "is_ingredient" in changes or "is_feedable" in changes:
        if not (changes.get("is_ingredient", product.is_ingredient) or changes.get("is_feedable", product.is_feedable)):
            raise FeedError("A feed product must be an ingredient, feedable, or both.")
    for k, v in changes.items():
        setattr(product, k, v)
    if "name" in changes:
        item = db.get(models.InventoryItem, product.inventory_item_id)
        if item is not None:
            item.name = product.name
    _commit(db, product)
    return _product_out(db, product)


@router.get("/feed-products/{product_id}/usage-policy", response_model=list[PolicyOut])
def get_usage_policy(product_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)):
    product = inv.get_product(db, product_id, user.farm_id)
    return [_policy_out(p) for p in policy.policies_for(db, product)]


@router.put("/feed-products/{product_id}/usage-policy", response_model=PolicyOut)
def set_usage_policy(product_id: str, payload: PolicySet, db: Session = Depends(get_db), user: models.User = Depends(_approve)):
    product = inv.get_product(db, product_id, user.farm_id)
    lot = inv.get_lot(db, payload.lot_id, user.farm_id) if payload.lot_id else None
    row = policy.set_policy(
        db, product, name=payload.name, rules=[r.model_dump() for r in payload.rules], requires_approved_formula=payload.requires_approved_formula,
        cross_species_transfer_allowed=payload.cross_species_transfer_allowed, lot=lot, notes=payload.notes, user_id=user.id,
    )
    _commit(db, row)
    return _policy_out(row)


@router.post("/feed-products/{product_id}/usage-policy/validate", response_model=PolicyDecisionOut)
def validate_usage(product_id: str, payload: PolicyValidate, db: Session = Depends(get_db), user: models.User = Depends(_view)):
    product = inv.get_product(db, product_id, user.farm_id)
    lot = inv.get_lot(db, payload.lot_id, user.farm_id) if payload.lot_id else None
    if payload.subject_type and payload.subject_id:
        subject = programs.load_subject(db, payload.subject_type, payload.subject_id, user.farm_id)
        target = programs.subject_state(db, payload.subject_type, subject).policy_target()
    else:
        target = policy.Target(species_code=payload.species_code, management_profile=payload.management_profile, life_stage=payload.life_stage,
                               reproductive_state=payload.reproductive_state, age_days=payload.age_days)
    return policy.evaluate(db, product, target, lot=lot, inclusion_pct=payload.inclusion_pct, through_formula=payload.through_formula).to_dict()


# ------------------------------------------------------------------- lots
@router.get("/feed-lots", response_model=list[FeedLotOut])
def list_lots(feed_product_id: str | None = None, lot_status: str | None = Query(None, alias="status"), db: Session = Depends(get_db), user: models.User = Depends(_view)):
    stmt = select(fm.FeedLot).where(fm.FeedLot.farm_id == user.farm_id)
    if feed_product_id:
        stmt = stmt.where(fm.FeedLot.feed_product_id == feed_product_id)
    rows = list(db.scalars(stmt.order_by(fm.FeedLot.received_at.desc())))
    out = [_lot_out(l) for l in rows]
    if lot_status:
        out = [o for o in out if o["status"] == lot_status]
    db.commit()
    return out


@router.post("/feed-lots/receive", response_model=FeedLotOut, status_code=status.HTTP_201_CREATED)
def receive_lot(payload: LotReceive, db: Session = Depends(get_db), user: models.User = Depends(_create)):
    product = inv.get_product(db, payload.feed_product_id, user.farm_id)
    lot = inv.receive(db, product, **payload.model_dump(exclude={"feed_product_id"}), user_id=user.id)
    _commit(db, lot)
    return _lot_out(lot)


@router.patch("/feed-lots/{lot_id}/status", response_model=FeedLotOut)
def update_lot_status(lot_id: str, payload: LotStatusUpdate, db: Session = Depends(get_db), user: models.User = Depends(_approve)):
    lot = inv.get_lot(db, lot_id, user.farm_id)
    inv.set_lot_status(db, lot, payload.status, reason=payload.reason, user_id=user.id)
    _commit(db, lot)
    return _lot_out(lot)


@router.get("/feed-lots/{lot_id}/trace")
def trace_lot(lot_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return inv.lot_trace(db, inv.get_lot(db, lot_id, user.farm_id))


@router.post("/feed-inventory/adjustments", status_code=status.HTTP_201_CREATED)
def post_adjustment(payload: AdjustmentCreate, db: Session = Depends(get_db), user: models.User = Depends(_approve)) -> dict:
    product = inv.get_product(db, payload.feed_product_id, user.farm_id)
    lot = inv.get_lot(db, payload.lot_id, user.farm_id) if payload.lot_id else None
    tx = inv.adjust(db, product, lot=lot, delta=payload.delta, reason=payload.reason, explanation=payload.explanation, user_id=user.id)
    db.commit()
    return {"transaction_id": tx.id, "feed_product_id": product.id, "delta": payload.delta, "unit": product.unit, "availability": inv.availability(db, product).to_dict()}


# --------------------------------------------------------------- formulas
@router.get("/feed-formulas", response_model=list[FormulaOut])
def list_formulas(db: Session = Depends(get_db), user: models.User = Depends(_view)):
    rows = db.scalars(select(fm.FeedFormula).where(fm.FeedFormula.farm_id == user.farm_id).order_by(fm.FeedFormula.name)).all()
    return [_formula_out(db, f) for f in rows]


@router.post("/feed-formulas", response_model=FormulaOut, status_code=status.HTTP_201_CREATED)
def create_formula(payload: FormulaCreate, db: Session = Depends(get_db), user: models.User = Depends(_create)):
    formula = batches.create_formula(
        db, user.farm_id, code=payload.code, name=payload.name, feed_product_id=payload.feed_product_id, species_code=payload.species_code,
        description=payload.description, batch_size=payload.batch_size, unit=payload.unit, components=[c.model_dump() for c in payload.components],
        notes=payload.notes, activate=payload.activate, user_id=user.id,
    )
    _commit(db, formula)
    return _formula_out(db, formula)


def _formula_or_404(db: Session, formula_id: str, farm_id: str) -> fm.FeedFormula:
    f = db.get(fm.FeedFormula, formula_id)
    if f is None or f.farm_id != farm_id:
        raise FeedError("Formula not found", 404)
    return f


def _formula_version(db: Session, formula_id: str, version: int, farm_id: str) -> fm.FeedFormulaVersion:
    f = _formula_or_404(db, formula_id, farm_id)
    v = next((v for v in f.versions if v.version == version), None)
    if v is None:
        raise FeedError(f"{f.name} has no version {version}", 404)
    return v


@router.get("/feed-formulas/{formula_id}", response_model=FormulaOut)
def get_formula(formula_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)):
    return _formula_out(db, _formula_or_404(db, formula_id, user.farm_id))


@router.post("/feed-formulas/{formula_id}/versions", response_model=FormulaVersionOut, status_code=status.HTTP_201_CREATED)
def add_formula_version(formula_id: str, payload: FormulaVersionCreate, db: Session = Depends(get_db), user: models.User = Depends(_create)):
    formula = _formula_or_404(db, formula_id, user.farm_id)
    version = batches.add_version(db, formula, batch_size=payload.batch_size, unit=payload.unit, components=[c.model_dump() for c in payload.components],
                                  notes=payload.notes, activate=payload.activate, user_id=user.id)
    _commit(db, version)
    return _version_out(db, version)


@router.get("/feed-formulas/{formula_id}/versions/{version}", response_model=FormulaVersionOut)
def get_formula_version(formula_id: str, version: int, db: Session = Depends(get_db), user: models.User = Depends(_view)):
    return _version_out(db, _formula_version(db, formula_id, version, user.farm_id))


@router.post("/feed-formulas/{formula_id}/versions/{version}/activate", response_model=FormulaVersionOut)
def activate_formula_version(formula_id: str, version: int, db: Session = Depends(get_db), user: models.User = Depends(_approve)):
    v = _formula_version(db, formula_id, version, user.farm_id)
    batches.activate_version(db, v, user_id=user.id)
    _commit(db, v)
    return _version_out(db, v)


@router.get("/feed-formulas/{formula_id}/versions/{version}/scale")
def scale_formula_version(formula_id: str, version: int, batch_size: float = Query(gt=0), unit: str | None = None,
                          db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    v = _formula_version(db, formula_id, version, user.farm_id)
    lines = batches.scale(v, batch_size, unit)
    for line in lines:
        product = db.get(fm.FeedProduct, line["feed_product_id"])
        line["product_name"] = product.name if product else None
        line["available"] = inv.availability(db, product).available if product else None
    return {"formula_version_id": v.id, "batch_size": batch_size, "unit": unit or v.unit, "components": lines,
            "planned_cost": batches.planned_cost(db, v, batch_size, unit)}


@router.get("/feed-formulas/{formula_id}/versions/{version}/nutrients")
def formula_version_nutrients(formula_id: str, version: int, basis: str = "as_fed", db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return batches.formula_nutrients(db, _formula_version(db, formula_id, version, user.farm_id), basis=basis)


# ---------------------------------------------------------------- batches
@router.get("/feed-batches", response_model=list[BatchOut])
def list_batches(batch_status: str | None = Query(None, alias="status"), db: Session = Depends(get_db), user: models.User = Depends(_view)):
    stmt = select(fm.FeedBatch).where(fm.FeedBatch.farm_id == user.farm_id)
    if batch_status:
        stmt = stmt.where(fm.FeedBatch.status == batch_status)
    return [_batch_out(db, b) for b in db.scalars(stmt.order_by(fm.FeedBatch.started_at.desc()))]


@router.post("/feed-batches", response_model=BatchOut, status_code=status.HTTP_201_CREATED)
def start_batch(payload: BatchStart, db: Session = Depends(get_db), user: models.User = Depends(_create)):
    batch = batches.start_batch(db, user.farm_id, formula_version_id=payload.formula_version_id, formula_id=payload.formula_id, batch_code=payload.batch_code,
                                target_quantity=payload.target_quantity, unit=payload.unit, notes=payload.notes, user_id=user.id)
    _commit(db, batch)
    return _batch_out(db, batch)


def _batch_or_404(db: Session, batch_id: str, farm_id: str) -> fm.FeedBatch:
    b = db.get(fm.FeedBatch, batch_id)
    if b is None or b.farm_id != farm_id:
        raise FeedError("Batch not found", 404)
    return b


@router.get("/feed-batches/{batch_id}", response_model=BatchOut)
def get_batch(batch_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)):
    return _batch_out(db, _batch_or_404(db, batch_id, user.farm_id))


@router.post("/feed-batches/{batch_id}/complete", response_model=BatchOut)
def complete_batch(batch_id: str, payload: BatchComplete, db: Session = Depends(get_db), user: models.User = Depends(_create)):
    batch = _batch_or_404(db, batch_id, user.farm_id)
    batches.complete_batch(db, batch, actuals=[a.model_dump() for a in payload.actuals], actual_quantity=payload.actual_quantity, produced_at=payload.produced_at,
                           lot_code=payload.lot_code, expiry_date=payload.expiry_date, notes=payload.notes, allow_negative=payload.allow_negative, user_id=user.id)
    _commit(db, batch)
    return _batch_out(db, batch)


@router.post("/feed-batches/{batch_id}/quarantine", response_model=BatchOut)
def quarantine_batch(batch_id: str, payload: BatchQuarantine, db: Session = Depends(get_db), user: models.User = Depends(_approve)):
    batch = _batch_or_404(db, batch_id, user.farm_id)
    batches.quarantine_batch(db, batch, reason=payload.reason, user_id=user.id)
    _commit(db, batch)
    return _batch_out(db, batch)


# -------------------------------------------------------------- nutrients
@router.get("/feed-nutrients", response_model=list[NutrientOut])
def list_nutrients(db: Session = Depends(get_db), _user: models.User = Depends(_view)):
    return list(db.scalars(select(fm.FeedNutrient).order_by(fm.FeedNutrient.sort_order)))


@router.get("/feed-nutrient-profiles", response_model=list[NutrientProfileOut])
def list_nutrient_profiles(subject_type: str, subject_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)):
    rows = db.scalars(select(fm.FeedNutrientProfile).where(fm.FeedNutrientProfile.farm_id == user.farm_id, fm.FeedNutrientProfile.subject_type == subject_type,
                                                          fm.FeedNutrientProfile.subject_id == subject_id).order_by(fm.FeedNutrientProfile.effective_at.desc())).all()
    return [batches.profile_to_dict(p) for p in rows]


@router.post("/feed-nutrient-profiles", response_model=NutrientProfileOut, status_code=status.HTTP_201_CREATED)
def create_nutrient_profile(payload: NutrientProfileCreate, db: Session = Depends(get_db), user: models.User = Depends(_create)):
    profile = batches.record_profile(db, user.farm_id, subject_type=payload.subject_type, subject_id=payload.subject_id, basis=payload.basis,
                                     source_type=payload.source_type, values=[v.model_dump() for v in payload.values], reference=payload.reference,
                                     effective_at=payload.effective_at, user_id=user.id)
    _commit(db, profile)
    return batches.profile_to_dict(profile)


# --------------------------------------------------------------- programs
@router.get("/feeding-programs", response_model=list[ProgramOut])
def list_programs(db: Session = Depends(get_db), user: models.User = Depends(_view)):
    rows = db.scalars(select(fm.FeedingProgram).where(fm.FeedingProgram.farm_id == user.farm_id).order_by(fm.FeedingProgram.name)).all()
    return [_program_out(db, p) for p in rows]


@router.post("/feeding-programs", response_model=ProgramOut, status_code=status.HTTP_201_CREATED)
def create_program(payload: ProgramCreate, db: Session = Depends(get_db), user: models.User = Depends(_create)):
    program = programs.create_program(db, user.farm_id, code=payload.code, name=payload.name, name_ar=payload.name_ar, category=payload.category,
                                      description=payload.description, feedings_per_day=payload.feedings_per_day,
                                      components=[c.model_dump() for c in payload.components], rules=[r.model_dump() for r in payload.rules],
                                      notes=payload.notes, activate=payload.activate, user_id=user.id)
    _commit(db, program)
    return _program_out(db, program)


def _program_or_404(db: Session, program_id: str, farm_id: str) -> fm.FeedingProgram:
    p = db.get(fm.FeedingProgram, program_id)
    if p is None or p.farm_id != farm_id:
        raise FeedError("Feeding program not found", 404)
    return p


@router.get("/feeding-programs/{program_id}", response_model=ProgramOut)
def get_program(program_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)):
    return _program_out(db, _program_or_404(db, program_id, user.farm_id))


@router.post("/feeding-programs/{program_id}/versions", response_model=ProgramVersionOut, status_code=status.HTTP_201_CREATED)
def add_program_version(program_id: str, payload: ProgramVersionCreate, db: Session = Depends(get_db), user: models.User = Depends(_create)):
    program = _program_or_404(db, program_id, user.farm_id)
    version = programs.add_program_version(db, program, feedings_per_day=payload.feedings_per_day, components=[c.model_dump() for c in payload.components],
                                           rules=[r.model_dump() for r in payload.rules], notes=payload.notes, activate=payload.activate, user_id=user.id)
    _commit(db, version)
    return _program_version_out(db, version)


@router.post("/feeding-programs/{program_id}/versions/{version}/activate", response_model=ProgramVersionOut)
def activate_program_version(program_id: str, version: int, db: Session = Depends(get_db), user: models.User = Depends(_approve)):
    program = _program_or_404(db, program_id, user.farm_id)
    v = next((v for v in program.versions if v.version == version), None)
    if v is None:
        raise FeedError(f"{program.name} has no version {version}", 404)
    programs.activate_program_version(db, v, user_id=user.id)
    _commit(db, v)
    return _program_version_out(db, v)


@router.post("/feeding-programs/resolve")
def resolve_programs(payload: ProgramResolveRequest, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    """§14: eligible programs, the best match, the matching rule and why,
    warnings, and whether a review is required — for a real subject or a
    described one."""
    if payload.subject_type and payload.subject_id:
        subject = programs.load_subject(db, payload.subject_type, payload.subject_id, user.farm_id)
        state = programs.subject_state(db, payload.subject_type, subject)
        assignment, _, _ = programs.effective_program(db, payload.subject_type, subject)
        current = None
        if assignment is not None:
            v = db.get(fm.FeedingProgramVersion, assignment.program_version_id)
            current = v.program_id if v else None
        return programs.resolve_state(db, state, current_program_id=current)
    if not payload.species_code:
        raise FeedError("Give a subject (subject_type + subject_id) or at least a species_code.")
    sex = {"F": "F", "FEMALE": "F", "M": "M", "MALE": "M"}.get((payload.sex or "").upper())
    state = programs.SubjectState(
        subject_type="hypothetical", subject_id="", name=f"a {payload.species_code.replace('_', ' ')}", farm_id=user.farm_id,
        species_code=payload.species_code, sex=sex, life_stage=payload.life_stage or "adult", management_profile=payload.management_profile,
        reproductive_state=payload.reproductive_state or (("open" if sex == "F" else None)),
        lactation_state=payload.lactation_state or (("dry" if sex == "F" else None)),
        age_days=payload.age_days, weight_kg=payload.weight_kg, production=payload.production, head_count=payload.head_count,
    )
    return programs.resolve_state(db, state)


# ------------------------------------------------------------ assignments
@router.get("/livestock-subjects/{subject_id}/feeding-plan")
def feeding_plan(subject_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    subject_type, subject = programs.find_subject(db, subject_id, user.farm_id)
    return programs.effective_plan(db, subject_type, subject)


@router.get("/livestock-subjects/{subject_id}/feeding-assignments", response_model=list[AssignmentOut])
def list_assignments(subject_id: str, include_ended: bool = False, db: Session = Depends(get_db), user: models.User = Depends(_view)):
    subject_type, subject = programs.find_subject(db, subject_id, user.farm_id)
    stmt = select(fm.FeedingAssignment).where(fm.FeedingAssignment.subject_type == subject_type, fm.FeedingAssignment.subject_id == subject.id)
    if not include_ended:
        stmt = stmt.where(fm.FeedingAssignment.status == "active")
    return [_assignment_out(db, a) for a in db.scalars(stmt.order_by(fm.FeedingAssignment.created_at.desc()))]


@router.post("/livestock-subjects/{subject_id}/feeding-assignments", response_model=AssignmentOut, status_code=status.HTTP_201_CREATED)
def create_assignment(subject_id: str, payload: AssignmentCreate, db: Session = Depends(get_db), user: models.User = Depends(_create)):
    subject_type, subject = programs.find_subject(db, subject_id, user.farm_id)
    if payload.assignment_type == "restriction" and not user_can(db, user, perms.FEED_NUTRITION, perms.APPROVE) and not user_can(db, user, perms.ANIMAL_HEALTH, perms.CREATE):
        raise FeedError("A feed restriction is a veterinary or management decision; it needs Animal Health or feed approval rights.", 403)
    row = programs.assign(db, user.farm_id, subject_type, subject, **payload.model_dump(), user_id=user.id)
    _commit(db, row)
    return _assignment_out(db, row)


@router.delete("/livestock-subjects/{subject_id}/feeding-assignments/{assignment_id}", response_model=AssignmentOut)
def end_assignment(subject_id: str, assignment_id: str, reason: str | None = None, db: Session = Depends(get_db), user: models.User = Depends(_edit)):
    subject_type, subject = programs.find_subject(db, subject_id, user.farm_id)
    a = db.get(fm.FeedingAssignment, assignment_id)
    if a is None or a.subject_id != subject.id or a.farm_id != user.farm_id:
        raise FeedError("Assignment not found", 404)
    programs.end_assignment(db, a, user_id=user.id, reason=reason)
    _commit(db, a)
    return _assignment_out(db, a)


@router.get("/livestock-subjects/{subject_id}/feeding-history", response_model=list[FeedingEventOut])
def feeding_history(subject_id: str, days: int = Query(30, ge=1, le=365), db: Session = Depends(get_db), user: models.User = Depends(_view)):
    subject_type, subject = programs.find_subject(db, subject_id, user.farm_id)
    return [programs.event_to_dict(e) for e in programs.feeding_history(db, subject_type, subject.id, days=days)]


# ----------------------------------------------------------------- events
@router.post("/feeding-events", response_model=FeedingEventOut, status_code=status.HTTP_201_CREATED)
def record_feeding_event(payload: FeedingEventCreate, db: Session = Depends(get_db), user: models.User = Depends(_create)):
    subject = programs.load_subject(db, payload.subject_type, payload.subject_id, user.farm_id)
    event = programs.record_feeding(db, user.farm_id, subject_type=payload.subject_type, subject=subject, components=[c.model_dump() for c in payload.components],
                                    event_type=payload.event_type, occurred_at=payload.occurred_at, head_count=payload.head_count, notes=payload.notes,
                                    allow_negative=payload.allow_negative, user_id=user.id)
    _commit(db, event)
    return programs.event_to_dict(event)


@router.get("/feeding-events", response_model=list[FeedingEventOut])
def list_feeding_events(days: int = Query(7, ge=1, le=365), subject_type: str | None = None, subject_id: str | None = None,
                        db: Session = Depends(get_db), user: models.User = Depends(_view)):
    since = now() - timedelta(days=days)
    stmt = select(fm.FeedingEvent).where(fm.FeedingEvent.farm_id == user.farm_id, fm.FeedingEvent.occurred_at >= since)
    if subject_type:
        stmt = stmt.where(fm.FeedingEvent.subject_type == subject_type)
    if subject_id:
        stmt = stmt.where(fm.FeedingEvent.subject_id == subject_id)
    return [programs.event_to_dict(e) for e in db.scalars(stmt.order_by(fm.FeedingEvent.occurred_at.desc()))]


@router.post("/feeding-events/{event_id}/reverse", response_model=FeedingEventOut, status_code=status.HTTP_201_CREATED)
def reverse_feeding_event(event_id: str, payload: FeedingEventReverse, db: Session = Depends(get_db), user: models.User = Depends(_edit)):
    event = db.get(fm.FeedingEvent, event_id)
    if event is None or event.farm_id != user.farm_id:
        raise FeedError("Feeding event not found", 404)
    reversal = programs.reverse_feeding(db, event, reason=payload.reason, user_id=user.id)
    _commit(db, reversal)
    return programs.event_to_dict(reversal)


@router.get("/feeding-plan/today")
def feeding_plan_today(db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return programs.daily_plan(db, user.farm_id)


# --------------------------------------------------------------- inventory
@router.get("/feed-inventory/availability", response_model=list[FeedAvailabilityOut])
def inventory_availability(feed_product_id: str | None = None, db: Session = Depends(get_db), user: models.User = Depends(_view)):
    stmt = select(fm.FeedProduct).where(fm.FeedProduct.farm_id == user.farm_id, fm.FeedProduct.status == "active")
    if feed_product_id:
        stmt = stmt.where(fm.FeedProduct.id == feed_product_id)
    out = [inv.availability(db, p).to_dict() for p in db.scalars(stmt.order_by(fm.FeedProduct.name))]
    db.commit()
    return out


@router.get("/feed-inventory/days-of-cover")
def days_of_cover(db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    out = forecast.cover_for_products(db, user.farm_id)
    db.commit()
    return out


@router.get("/feed-inventory/forecast")
def demand_forecast(horizon_days: int = Query(14, ge=1, le=180), db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    out = forecast.forecast(db, user.farm_id, horizon_days=horizon_days, persist=True)
    db.commit()
    return out


@router.get("/feed-inventory/reorder-recommendations")
def reorder_recommendations(db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    out = forecast.reorder_recommendations(db, user.farm_id)
    db.commit()
    return out


@router.post("/feed-inventory/reorder-recommendations/{product_id}/acknowledge", status_code=status.HTTP_201_CREATED)
def acknowledge_reorder(product_id: str, payload: ReorderAcknowledge, db: Session = Depends(get_db), user: models.User = Depends(_create)) -> dict:
    product = inv.get_product(db, product_id, user.farm_id)
    task = forecast.acknowledge_reorder(db, user.farm_id, product, quantity=payload.quantity, note=payload.note, assigned_to=payload.assigned_to, user_id=user.id)
    db.commit()
    return {"task_id": task.id, "title": task.title, "status": task.status, "feed_product_id": product.id}


@router.get("/feed-reorder-policies", response_model=list[ReorderPolicyOut])
def list_reorder_policies(db: Session = Depends(get_db), user: models.User = Depends(_view)):
    return [_reorder_policy_out(p) for p in db.scalars(select(fm.FeedReorderPolicy).where(fm.FeedReorderPolicy.farm_id == user.farm_id))]


@router.put("/feed-reorder-policies", response_model=ReorderPolicyOut)
def upsert_reorder_policy(payload: ReorderPolicyUpsert, db: Session = Depends(get_db), user: models.User = Depends(_edit)):
    product = inv.get_product(db, payload.feed_product_id, user.farm_id)
    row = db.scalar(select(fm.FeedReorderPolicy).where(fm.FeedReorderPolicy.feed_product_id == product.id, fm.FeedReorderPolicy.location_label == payload.location_label))
    if row is None:
        row = fm.FeedReorderPolicy(farm_id=user.farm_id, feed_product_id=product.id, unit=product.unit)
        db.add(row)
    for k, v in payload.model_dump(exclude={"feed_product_id"}).items():
        setattr(row, k, v)
    item = db.get(models.InventoryItem, product.inventory_item_id)
    if item is not None and payload.reorder_point is not None:
        item.reorder_level = payload.reorder_point
    _commit(db, row)
    return _reorder_policy_out(row)


# ------------------------------------------------------------ allocations
@router.get("/feed-allocations", response_model=list[AllocationOut])
def list_allocations(feed_product_id: str | None = None, alloc_status: str | None = Query("active", alias="status"), db: Session = Depends(get_db), user: models.User = Depends(_view)):
    stmt = select(fm.FeedAllocation).where(fm.FeedAllocation.farm_id == user.farm_id)
    if feed_product_id:
        stmt = stmt.where(fm.FeedAllocation.feed_product_id == feed_product_id)
    if alloc_status and alloc_status != "all":
        stmt = stmt.where(fm.FeedAllocation.status == alloc_status)
    return [_allocation_out(db, a) for a in db.scalars(stmt.order_by(fm.FeedAllocation.created_at.desc()))]


@router.post("/feed-allocations", response_model=AllocationOut, status_code=status.HTTP_201_CREATED)
def create_allocation(payload: AllocationCreate, db: Session = Depends(get_db), user: models.User = Depends(_create)):
    product = inv.get_product(db, payload.feed_product_id, user.farm_id)
    alloc = inv.allocate(db, product, **payload.model_dump(exclude={"feed_product_id"}), user_id=user.id)
    _commit(db, alloc)
    return _allocation_out(db, alloc)


def _allocation_or_404(db: Session, allocation_id: str, farm_id: str) -> fm.FeedAllocation:
    a = db.get(fm.FeedAllocation, allocation_id)
    if a is None or a.farm_id != farm_id:
        raise FeedError("Allocation not found", 404)
    return a


@router.post("/feed-allocations/{allocation_id}/release", response_model=AllocationOut)
def release_allocation(allocation_id: str, reason: str | None = None, db: Session = Depends(get_db), user: models.User = Depends(_edit)):
    a = _allocation_or_404(db, allocation_id, user.farm_id)
    inv.release_allocation(db, a, user_id=user.id, reason=reason)
    _commit(db, a)
    return _allocation_out(db, a)


@router.post("/feed-allocations/{allocation_id}/transfer", response_model=AllocationOut, status_code=status.HTTP_201_CREATED)
def transfer_allocation(allocation_id: str, payload: AllocationTransfer, db: Session = Depends(get_db), user: models.User = Depends(_edit)):
    a = _allocation_or_404(db, allocation_id, user.farm_id)
    product = db.get(fm.FeedProduct, a.feed_product_id)
    moved = inv.transfer_allocation(
        db, a, quantity=payload.quantity, species_code=payload.species_code, subject_type=payload.subject_type, subject_id=payload.subject_id,
        feeding_program_id=payload.feeding_program_id, purpose=payload.purpose, authorised=user_can(db, user, perms.FEED_NUTRITION, perms.APPROVE),
        cross_species_allowed=policy.cross_species_transfer_allowed(db, product), user_id=user.id,
    )
    _commit(db, moved)
    return _allocation_out(db, moved)


# --------------------------------------------------------- reconciliation
@router.get("/feed-reconciliations", response_model=list[ReconciliationOut])
def list_reconciliations(rec_status: str | None = Query(None, alias="status"), db: Session = Depends(get_db), user: models.User = Depends(_view)):
    stmt = select(fm.FeedReconciliation).where(fm.FeedReconciliation.farm_id == user.farm_id)
    if rec_status:
        stmt = stmt.where(fm.FeedReconciliation.status == rec_status)
    return [_reconciliation_out(db, r) for r in db.scalars(stmt.order_by(fm.FeedReconciliation.created_at.desc()))]


@router.post("/feed-reconciliations", response_model=ReconciliationOut, status_code=status.HTTP_201_CREATED)
def create_reconciliation(payload: ReconciliationCreate, db: Session = Depends(get_db), user: models.User = Depends(_create)):
    product = inv.get_product(db, payload.feed_product_id, user.farm_id)
    lot = inv.get_lot(db, payload.lot_id, user.farm_id) if payload.lot_id else None
    rec = forecast.reconcile(db, user.farm_id, product, lot=lot, period_from=ensure_utc(payload.period_from), period_to=ensure_utc(payload.period_to),
                             counted_closing_quantity=payload.counted_closing_quantity, explanation=payload.explanation, user_id=user.id)
    _commit(db, rec)
    return _reconciliation_out(db, rec)


@router.get("/feed-reconciliations/{reconciliation_id}", response_model=ReconciliationOut)
def get_reconciliation(reconciliation_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)):
    rec = db.get(fm.FeedReconciliation, reconciliation_id)
    if rec is None or rec.farm_id != user.farm_id:
        raise FeedError("Reconciliation not found", 404)
    return _reconciliation_out(db, rec)


@router.post("/feed-reconciliations/{reconciliation_id}/close", response_model=ReconciliationOut)
def close_reconciliation(reconciliation_id: str, payload: ReconciliationClose, db: Session = Depends(get_db), user: models.User = Depends(_approve)):
    rec = db.get(fm.FeedReconciliation, reconciliation_id)
    if rec is None or rec.farm_id != user.farm_id:
        raise FeedError("Reconciliation not found", 404)
    forecast.close_reconciliation(db, rec, post_adjustment=payload.post_adjustment, explanation=payload.explanation, user_id=user.id)
    _commit(db, rec)
    return _reconciliation_out(db, rec)


# ------------------------------------------------------------------ costs
@router.get("/feed-costs")
def feed_costs(days: int = Query(30, ge=1, le=365), db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return forecast.cost_summary(db, user.farm_id, days=days)
