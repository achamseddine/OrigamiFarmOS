"""Mouneh & Farm Product Processing — tech spec v0.5.

Every endpoint here requires the farm's "mouneh" module license to be
active (router-level dependency below); a super user turns that on/off
via app/api/v1/modules.py. Nothing in this file hard-codes a product
type — "Makdous" only shows up in app/seed.py as demo data created
through these same endpoints.
"""
from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_manager_role, require_module_license
from app.db.base import get_db
from app.domain import models, mouneh_models
from app.mouneh import costing
from app.repositories.base import new_id, now
from app.services import mouneh_service
from app.schemas.mouneh import (
    BatchCompleteRequest,
    BatchConsumeRequest,
    CostBreakdownOut,
    CostPreviewRequest,
    MounehDashboardOut,
    MounehProductCreate,
    MounehProductDetailOut,
    MounehProductOut,
    MounehProductUpdate,
    MounehSaleCreate,
    MounehSaleOut,
    ProductProfitabilityOut,
    ProductionBatchCreate,
    ProductionBatchOut,
    RawMaterialCreate,
    RawMaterialOut,
    RecipeCreate,
    RecipeOut,
)

router = APIRouter(prefix="/mouneh", tags=["mouneh"], dependencies=[Depends(require_module_license("mouneh"))])

MODULE_CODE = "mouneh"


def _write_event(
    db: Session, *, farm_id: str, entity_type: str, entity_id: str, event_type: str, payload: dict, user_id: str
) -> None:
    db.add(
        mouneh_models.MounehEvent(
            id=new_id(),
            farm_id=farm_id,
            entity_type=entity_type,
            entity_id=entity_id,
            event_type=event_type,
            payload_json=payload,
            created_by=user_id,
            created_at=now(),
        )
    )


# ---------------------------------------------------------------------------
# Raw materials (REQ-MOU-002: ingredients + packaging, reusable across
# products — a jar bought for Makdous is the same jar used for Jam)
# ---------------------------------------------------------------------------
@router.post("/raw-materials", response_model=RawMaterialOut, status_code=status.HTTP_201_CREATED)
def create_raw_material(
    payload: RawMaterialCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_manager_role),
) -> mouneh_models.RawMaterial:
    material = mouneh_models.RawMaterial(id=new_id(), farm_id=current_user.farm_id, **payload.model_dump())
    db.add(material)
    _write_event(
        db,
        farm_id=current_user.farm_id,
        entity_type="raw_material",
        entity_id=material.id,
        event_type="raw_material_created",
        payload={"name": material.name, "category": material.category},
        user_id=current_user.id,
    )
    db.commit()
    db.refresh(material)
    return material


@router.get("/raw-materials", response_model=list[RawMaterialOut])
def list_raw_materials(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[mouneh_models.RawMaterial]:
    return list(
        db.scalars(
            select(mouneh_models.RawMaterial)
            .where(mouneh_models.RawMaterial.farm_id == current_user.farm_id, mouneh_models.RawMaterial.active.is_(True))
            .order_by(mouneh_models.RawMaterial.name)
        )
    )


# ---------------------------------------------------------------------------
# Products (REQ-MOU-002/003: the Dynamic Product Builder)
# ---------------------------------------------------------------------------
def _product_or_404(db: Session, product_id: str, farm_id: str) -> mouneh_models.MounehProduct:
    product = db.get(mouneh_models.MounehProduct, product_id)
    if product is None or product.farm_id != farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Product not found")
    return product


@router.post("/products", response_model=MounehProductOut, status_code=status.HTTP_201_CREATED)
def create_product(
    payload: MounehProductCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_manager_role),
) -> mouneh_models.MounehProduct:
    existing = db.scalars(
        select(mouneh_models.MounehProduct).where(
            mouneh_models.MounehProduct.farm_id == current_user.farm_id,
            mouneh_models.MounehProduct.category == payload.category,
            mouneh_models.MounehProduct.name == payload.name,
        )
    ).one_or_none()
    if existing is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, f"A product named '{payload.name}' already exists in category '{payload.category}'")

    product = mouneh_models.MounehProduct(
        id=new_id(), farm_id=current_user.farm_id, created_by=current_user.id, status="draft", **payload.model_dump()
    )
    db.add(product)
    _write_event(
        db,
        farm_id=current_user.farm_id,
        entity_type="mouneh_product",
        entity_id=product.id,
        event_type="product_created",
        payload={"name": product.name, "category": product.category},
        user_id=current_user.id,
    )
    db.commit()
    db.refresh(product)
    return product


@router.get("/products", response_model=list[MounehProductOut])
def list_products(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[mouneh_models.MounehProduct]:
    return list(
        db.scalars(
            select(mouneh_models.MounehProduct)
            .where(mouneh_models.MounehProduct.farm_id == current_user.farm_id)
            .order_by(mouneh_models.MounehProduct.name)
        )
    )


@router.get("/products/{product_id}", response_model=MounehProductDetailOut)
def get_product(product_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> dict:
    product = _product_or_404(db, product_id, current_user.farm_id)
    recipe = mouneh_service.get_active_recipe(db, product.id)
    out = MounehProductOut.model_validate(product).model_dump()
    out["active_recipe"] = _serialize_recipe(db, recipe) if recipe else None
    return out


@router.put("/products/{product_id}", response_model=MounehProductOut)
def update_product(
    product_id: str,
    payload: MounehProductUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_manager_role),
) -> mouneh_models.MounehProduct:
    product = _product_or_404(db, product_id, current_user.farm_id)
    changes = payload.model_dump(exclude_unset=True)
    for field, value in changes.items():
        setattr(product, field, value)
    _write_event(
        db,
        farm_id=current_user.farm_id,
        entity_type="mouneh_product",
        entity_id=product.id,
        event_type="product_updated",
        payload=changes,
        user_id=current_user.id,
    )
    db.commit()
    db.refresh(product)
    return product


# ---------------------------------------------------------------------------
# Recipes (REQ-MOU-002/003: Bill of Materials + labor/overhead template.
# Every call creates a new *version* — a past batch's snapshot cost never
# changes because a manager edited the recipe afterwards.)
# ---------------------------------------------------------------------------
def _serialize_recipe(db: Session, recipe: mouneh_models.MounehRecipe) -> dict:
    out = RecipeOut.model_validate(recipe).model_dump()
    out["cost_components"] = [
        {
            "id": c.id,
            "product_id": c.product_id,
            "batch_id": c.batch_id,
            "cost_type": c.cost_type,
            "label": c.label,
            "calculation_method": c.calculation_method,
            "amount": c.amount,
            "quantity": c.quantity,
            "unit_cost": c.unit_cost,
            "allocation_basis": c.allocation_basis,
        }
        for c in mouneh_service.product_cost_components(db, recipe.product_id)
    ]
    return out


@router.post("/products/{product_id}/recipes", response_model=RecipeOut, status_code=status.HTTP_201_CREATED)
def create_recipe(
    product_id: str,
    payload: RecipeCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_manager_role),
) -> dict:
    product = _product_or_404(db, product_id, current_user.farm_id)

    for item in payload.items:
        material = db.get(mouneh_models.RawMaterial, item.material_id)
        if material is None or material.farm_id != current_user.farm_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, f"Raw material {item.material_id} not found")

    prior = mouneh_service.get_active_recipe(db, product.id)
    next_version = (prior.version + 1) if prior else 1
    if prior is not None:
        prior.active = False

    recipe = mouneh_models.MounehRecipe(
        id=new_id(),
        product_id=product.id,
        version=next_version,
        basis_quantity=payload.basis_quantity,
        basis_unit=payload.basis_unit,
        notes=payload.notes,
        active=True,
    )
    db.add(recipe)
    db.flush()

    for item in payload.items:
        material = db.get(mouneh_models.RawMaterial, item.material_id)
        db.add(
            mouneh_models.MounehRecipeItem(
                id=new_id(),
                recipe_id=recipe.id,
                material_id=item.material_id,
                material_type=material.category,
                quantity=item.quantity,
                unit=item.unit,
                loss_percent=item.loss_percent,
                is_optional=item.is_optional,
            )
        )

    # Replace the product's cost-component template with the new set —
    # this is the "current costing rules" template, not a historical
    # batch record, so replacing it (rather than versioning it) is safe.
    for old in mouneh_service.product_cost_components(db, product.id):
        db.delete(old)
    for component in payload.cost_components:
        db.add(mouneh_models.CostComponent(id=new_id(), product_id=product.id, **component.model_dump()))

    if product.status == "draft":
        product.status = "active"

    _write_event(
        db,
        farm_id=current_user.farm_id,
        entity_type="mouneh_recipe",
        entity_id=recipe.id,
        event_type="recipe_created",
        payload={"product_id": product.id, "version": next_version},
        user_id=current_user.id,
    )
    db.commit()
    db.refresh(recipe)
    return _serialize_recipe(db, recipe)


@router.get("/products/{product_id}/recipes", response_model=list[RecipeOut])
def list_recipes(product_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[dict]:
    product = _product_or_404(db, product_id, current_user.farm_id)
    recipes = db.scalars(
        select(mouneh_models.MounehRecipe)
        .where(mouneh_models.MounehRecipe.product_id == product.id)
        .order_by(mouneh_models.MounehRecipe.version.desc())
    ).all()
    return [_serialize_recipe(db, r) for r in recipes]


# ---------------------------------------------------------------------------
# Cost preview (REQ-MOU-004 — before committing to a batch, or even before
# saving a brand-new product in the builder wizard)
# ---------------------------------------------------------------------------
@router.post("/cost-preview", response_model=CostBreakdownOut)
def cost_preview(payload: CostPreviewRequest, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> dict:
    if payload.product_id or payload.recipe_id:
        recipe = (
            db.get(mouneh_models.MounehRecipe, payload.recipe_id)
            if payload.recipe_id
            else mouneh_service.get_active_recipe(db, payload.product_id)
        )
        if recipe is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "No recipe found to price")
        product = db.get(mouneh_models.MounehProduct, recipe.product_id)
        output_qty = payload.output_qty or recipe.basis_quantity
        materials = mouneh_service.recipe_materials(recipe, output_qty=output_qty)
        components = mouneh_service.components_as_lines(
            mouneh_service.product_cost_components(db, product.id), recipe, output_qty=output_qty
        )
    else:
        if not payload.materials or payload.output_qty is None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Provide product_id/recipe_id, or materials + output_qty for an ad-hoc preview")
        materials = []
        for line in payload.materials:
            material = db.get(mouneh_models.RawMaterial, line.material_id)
            if material is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, f"Raw material {line.material_id} not found")
            materials.append(
                costing.MaterialLine(
                    material_id=material.id,
                    name=material.name,
                    category=material.category,
                    quantity=line.quantity,
                    unit=line.unit,
                    unit_cost=material.default_unit_cost,
                    loss_percent=line.loss_percent,
                )
            )
        components = [
            costing.CostComponentLine(
                cost_type=c.cost_type, label=c.label or c.cost_type, calculation_method=c.calculation_method,
                amount=c.amount, quantity=c.quantity, unit_cost=c.unit_cost,
            )
            for c in (payload.cost_components or [])
        ]
        product = None
        output_qty = payload.output_qty

    breakdown = costing.compute_cost_breakdown(materials=materials, components=components, output_qty=output_qty)
    out = breakdown.__dict__.copy()
    if product is not None and product.target_margin_pct is not None:
        suggestion = costing.suggest_price(unit_cost=breakdown.unit_cost, target_margin_pct=product.target_margin_pct)
        out["suggested_price"] = suggestion.suggested_price
        out["minimum_price"] = suggestion.minimum_price
    return out


# ---------------------------------------------------------------------------
# Production batches (REQ-MOU-004/005)
# ---------------------------------------------------------------------------
def _batch_or_404(db: Session, batch_id: str, farm_id: str) -> mouneh_models.ProductionBatch:
    batch = db.get(mouneh_models.ProductionBatch, batch_id)
    if batch is None or batch.farm_id != farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Batch not found")
    return batch


@router.post("/batches", response_model=ProductionBatchOut, status_code=status.HTTP_201_CREATED)
def create_batch(
    payload: ProductionBatchCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_manager_role),
) -> mouneh_models.ProductionBatch:
    product = _product_or_404(db, payload.product_id, current_user.farm_id)
    recipe = mouneh_service.get_active_recipe(db, product.id)
    if recipe is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"{product.name} has no recipe yet — add raw materials before starting a batch")

    breakdown = mouneh_service.compute_planned_cost(db, product, payload.planned_qty)

    batch = mouneh_models.ProductionBatch(
        id=new_id(),
        farm_id=current_user.farm_id,
        product_id=product.id,
        recipe_version_id=recipe.id,
        batch_code=payload.batch_code or mouneh_service.generate_batch_code(db, current_user.farm_id, product),
        planned_qty=payload.planned_qty,
        status="in_progress",
        planned_unit_cost=breakdown.unit_cost,
        planned_total_cost=breakdown.total_cost,
        warehouse_location=payload.warehouse_location,
        notes=payload.notes,
        started_at=now(),
        created_by=current_user.id,
    )
    db.add(batch)
    db.flush()

    for material in mouneh_service.recipe_materials(recipe, output_qty=payload.planned_qty):
        db.add(
            mouneh_models.BatchInputConsumption(
                id=new_id(),
                batch_id=batch.id,
                material_id=material.material_id,
                planned_qty=material.effective_quantity,
                unit_cost=material.unit_cost,
            )
        )

    _write_event(
        db,
        farm_id=current_user.farm_id,
        entity_type="production_batch",
        entity_id=batch.id,
        event_type="batch_started",
        payload={"product_id": product.id, "planned_qty": payload.planned_qty, "batch_code": batch.batch_code},
        user_id=current_user.id,
    )
    db.commit()
    db.refresh(batch)
    return batch


@router.get("/batches", response_model=list[ProductionBatchOut])
def list_batches(
    product_id: str | None = None,
    status_filter: str | None = None,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> list[mouneh_models.ProductionBatch]:
    stmt = select(mouneh_models.ProductionBatch).where(mouneh_models.ProductionBatch.farm_id == current_user.farm_id)
    if product_id:
        stmt = stmt.where(mouneh_models.ProductionBatch.product_id == product_id)
    if status_filter:
        stmt = stmt.where(mouneh_models.ProductionBatch.status == status_filter)
    return list(db.scalars(stmt.order_by(mouneh_models.ProductionBatch.started_at.desc())))


@router.get("/batches/{batch_id}", response_model=ProductionBatchOut)
def get_batch(batch_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> mouneh_models.ProductionBatch:
    return _batch_or_404(db, batch_id, current_user.farm_id)


@router.post("/batches/{batch_id}/consume", response_model=ProductionBatchOut)
def consume_batch_inputs(
    batch_id: str,
    payload: BatchConsumeRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_manager_role),
) -> mouneh_models.ProductionBatch:
    batch = _batch_or_404(db, batch_id, current_user.farm_id)
    if batch.status != "in_progress":
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"Batch is '{batch.status}' — only an in-progress batch can consume materials")

    by_material = {c.material_id: c for c in batch.consumptions}
    for line in payload.lines:
        consumption = by_material.get(line.material_id)
        if consumption is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, f"Material {line.material_id} is not part of this batch's recipe")
        material = db.get(mouneh_models.RawMaterial, line.material_id)
        consumption.actual_qty = line.actual_qty
        consumption.total_cost = line.actual_qty * consumption.unit_cost

        if material.stock_tracking_enabled:
            new_stock = material.current_stock - line.actual_qty
            if new_stock < 0 and not payload.allow_negative:
                raise HTTPException(
                    status.HTTP_422_UNPROCESSABLE_ENTITY,
                    f"This would take {material.name} stock to {new_stock:.2f} {material.unit}. Pass allow_negative=true to override.",
                )
            material.current_stock = new_stock

    _write_event(
        db,
        farm_id=current_user.farm_id,
        entity_type="production_batch",
        entity_id=batch.id,
        event_type="batch_inputs_consumed",
        payload={"lines": [line.model_dump() for line in payload.lines]},
        user_id=current_user.id,
    )
    db.commit()
    db.refresh(batch)
    return batch


@router.post("/batches/{batch_id}/complete", response_model=ProductionBatchOut)
def complete_batch(
    batch_id: str,
    payload: BatchCompleteRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_manager_role),
) -> mouneh_models.ProductionBatch:
    """REQ-MOU-005: "Batch completion consumes stock and creates finished
    goods." Any material never explicitly /consume'd is deducted here
    at its planned (recipe) quantity, so a manager who skips the granular
    step still gets correct stock and cost."""
    batch = _batch_or_404(db, batch_id, current_user.farm_id)
    if batch.status != "in_progress":
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"Batch is already '{batch.status}'")

    for consumption in batch.consumptions:
        if consumption.actual_qty is None:
            material = db.get(mouneh_models.RawMaterial, consumption.material_id)
            consumption.actual_qty = consumption.planned_qty
            consumption.total_cost = consumption.planned_qty * consumption.unit_cost
            if material.stock_tracking_enabled:
                material.current_stock -= consumption.planned_qty

    extra_components = [
        costing.CostComponentLine(
            cost_type=c.cost_type, label=c.label or c.cost_type, calculation_method=c.calculation_method,
            amount=c.amount, quantity=c.quantity, unit_cost=c.unit_cost,
        )
        for c in payload.extra_cost_components
    ]

    batch.actual_output_qty = payload.actual_output_qty
    batch.waste_qty = payload.waste_qty
    batch.damaged_qty = payload.damaged_qty
    batch.quality_status = payload.quality_status
    batch.expiry_date = payload.expiry_date
    batch.warehouse_location = payload.warehouse_location or batch.warehouse_location
    batch.labor_hours = payload.labor_hours
    batch.status = "completed"
    batch.completed_at = now()

    for c in payload.extra_cost_components:
        db.add(mouneh_models.CostComponent(id=new_id(), batch_id=batch.id, **c.model_dump()))

    breakdown = mouneh_service.batch_actual_cost(db, batch, extra_components=extra_components)
    batch.actual_unit_cost = breakdown.unit_cost
    batch.actual_total_cost = breakdown.total_cost

    stock = mouneh_models.FinishedGoodsStock(
        id=new_id(),
        farm_id=current_user.farm_id,
        product_id=batch.product_id,
        batch_id=batch.id,
        warehouse_location=batch.warehouse_location,
        quantity_produced=payload.actual_output_qty,
        quantity_available=payload.actual_output_qty,
        unit_cost=breakdown.unit_cost,
        expiry_date=payload.expiry_date,
    )
    db.add(stock)

    _write_event(
        db,
        farm_id=current_user.farm_id,
        entity_type="production_batch",
        entity_id=batch.id,
        event_type="batch_completed",
        payload={"actual_output_qty": payload.actual_output_qty, "actual_unit_cost": breakdown.unit_cost, "quality_status": payload.quality_status},
        user_id=current_user.id,
    )
    db.commit()
    db.refresh(batch)
    return batch


# ---------------------------------------------------------------------------
# Finished goods (REQ-MOU-005)
# ---------------------------------------------------------------------------
@router.get("/finished-goods")
def list_finished_goods(
    product_id: str | None = None, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)
) -> list[dict]:
    stmt = select(mouneh_models.FinishedGoodsStock).where(mouneh_models.FinishedGoodsStock.farm_id == current_user.farm_id)
    if product_id:
        stmt = stmt.where(mouneh_models.FinishedGoodsStock.product_id == product_id)
    rows = db.scalars(stmt.order_by(mouneh_models.FinishedGoodsStock.expiry_date.asc().nulls_last())).all()
    return [
        {
            "id": r.id,
            "product_id": r.product_id,
            "batch_id": r.batch_id,
            "warehouse_location": r.warehouse_location,
            "quantity_produced": r.quantity_produced,
            "quantity_available": r.quantity_available,
            "quantity_reserved": r.quantity_reserved,
            "quantity_sold": r.quantity_sold,
            "quantity_expired": r.quantity_expired,
            "quantity_damaged": r.quantity_damaged,
            "unit_cost": r.unit_cost,
            "expiry_date": r.expiry_date,
        }
        for r in rows
    ]


# ---------------------------------------------------------------------------
# Sales (REQ-MOU-006)
# ---------------------------------------------------------------------------
@router.post("/sales", response_model=MounehSaleOut, status_code=status.HTTP_201_CREATED)
def record_sale(
    payload: MounehSaleCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_manager_role),
) -> mouneh_models.MounehSaleLine:
    product = _product_or_404(db, payload.product_id, current_user.farm_id)

    if payload.finished_goods_stock_id:
        stock = db.get(mouneh_models.FinishedGoodsStock, payload.finished_goods_stock_id)
        if stock is None or stock.farm_id != current_user.farm_id or stock.product_id != product.id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Finished goods stock not found for this product")
    else:
        # Auto-pick oldest-expiry stock first (sell-through-oldest-first).
        stock = db.scalars(
            select(mouneh_models.FinishedGoodsStock)
            .where(
                mouneh_models.FinishedGoodsStock.farm_id == current_user.farm_id,
                mouneh_models.FinishedGoodsStock.product_id == product.id,
                mouneh_models.FinishedGoodsStock.quantity_available > 0,
            )
            .order_by(mouneh_models.FinishedGoodsStock.expiry_date.asc().nulls_last())
        ).first()
        if stock is None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"No available stock for {product.name}")

    if payload.quantity > stock.quantity_available:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"Only {stock.quantity_available} units available, cannot sell {payload.quantity}",
        )

    margin = costing.compute_sale_margin(
        quantity=payload.quantity, unit_price=payload.unit_price, discount=payload.discount, unit_cost=stock.unit_cost
    )

    sale = mouneh_models.MounehSaleLine(
        id=new_id(),
        farm_id=current_user.farm_id,
        product_id=product.id,
        batch_id=stock.batch_id,
        finished_goods_stock_id=stock.id,
        quantity=payload.quantity,
        unit_price=payload.unit_price,
        discount=payload.discount,
        customer_id=payload.customer_id,
        channel=payload.channel,
        cost_per_unit=stock.unit_cost,
        revenue=margin.revenue,
        margin=margin.profit,
        sold_at=now(),
        sold_by=current_user.id,
    )
    db.add(sale)

    stock.quantity_available -= payload.quantity
    stock.quantity_sold += payload.quantity

    _write_event(
        db,
        farm_id=current_user.farm_id,
        entity_type="mouneh_sale_line",
        entity_id=sale.id,
        event_type="sale_recorded",
        payload={"product_id": product.id, "quantity": payload.quantity, "revenue": margin.revenue},
        user_id=current_user.id,
    )
    db.commit()
    db.refresh(sale)
    return sale


@router.get("/sales", response_model=list[MounehSaleOut])
def list_sales(
    product_id: str | None = None, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)
) -> list[mouneh_models.MounehSaleLine]:
    stmt = select(mouneh_models.MounehSaleLine).where(mouneh_models.MounehSaleLine.farm_id == current_user.farm_id)
    if product_id:
        stmt = stmt.where(mouneh_models.MounehSaleLine.product_id == product_id)
    return list(db.scalars(stmt.order_by(mouneh_models.MounehSaleLine.sold_at.desc())))


# ---------------------------------------------------------------------------
# Dashboards (REQ-MOU-007)
# ---------------------------------------------------------------------------
@router.get("/products/{product_id}/profitability", response_model=ProductProfitabilityOut)
def product_profitability(product_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> dict:
    product = _product_or_404(db, product_id, current_user.farm_id)
    return mouneh_service.product_profitability(db, product)


@router.get("/dashboard", response_model=MounehDashboardOut)
def dashboard(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> dict:
    license_row = db.scalars(
        select(mouneh_models.ModuleLicense).where(
            mouneh_models.ModuleLicense.farm_id == current_user.farm_id, mouneh_models.ModuleLicense.module_code == MODULE_CODE
        )
    ).one_or_none()
    products = list(db.scalars(select(mouneh_models.MounehProduct).where(mouneh_models.MounehProduct.farm_id == current_user.farm_id)))
    profitabilities = [mouneh_service.product_profitability(db, p) for p in products]
    ranked = sorted(profitabilities, key=lambda p: p["total_revenue"], reverse=True)

    active_batches = db.scalar(
        select(func.count())
        .select_from(mouneh_models.ProductionBatch)
        .where(mouneh_models.ProductionBatch.farm_id == current_user.farm_id, mouneh_models.ProductionBatch.status == "in_progress")
    )

    return {
        "module_status": license_row.status if license_row else "inactive",
        "total_products": len(products),
        "active_batches": active_batches or 0,
        "total_finished_units": round(sum(p["units_remaining"] for p in profitabilities), 3),
        "total_stock_value": round(sum(p["_total_stock_value"] for p in profitabilities), 2),
        "total_revenue_30d": round(sum(p["_recent_revenue"] for p in profitabilities), 2),
        "total_profit_30d": round(sum(p["_recent_profit"] for p in profitabilities), 2),
        "best_sellers": [p for p in ranked if p["units_sold"] > 0][:5],
        "slow_movers": [p for p in profitabilities if p["recommendation"] == "slow_mover"][:5],
    }
