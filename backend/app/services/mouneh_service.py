"""DB-touching side of the Mouneh module: loads recipe/material/cost rows
and calls the pure costing engine (app/mouneh/costing.py) — mirrors the
recommendation_service.py / recommendations/engine.py split already used
elsewhere in this backend.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import mouneh_models
from app.mouneh import costing
from app.repositories.base import ensure_utc

# Cost components attached directly to a product (batch_id is None) are the
# product's *current* template — labor/utilities/transport/etc rules that
# apply to every future batch until a manager edits the recipe again.
# Components attached to a specific batch are one-off additions recorded at
# completion time (e.g. this batch's actual labor hours).


def get_active_recipe(db: Session, product_id: str) -> mouneh_models.MounehRecipe | None:
    return db.scalars(
        select(mouneh_models.MounehRecipe)
        .where(mouneh_models.MounehRecipe.product_id == product_id, mouneh_models.MounehRecipe.active.is_(True))
        .order_by(mouneh_models.MounehRecipe.version.desc())
    ).first()


def product_cost_components(db: Session, product_id: str) -> list[mouneh_models.CostComponent]:
    return list(
        db.scalars(
            select(mouneh_models.CostComponent).where(
                mouneh_models.CostComponent.product_id == product_id,
                mouneh_models.CostComponent.batch_id.is_(None),
            )
        )
    )


def _scale_factor(recipe: mouneh_models.MounehRecipe, output_qty: float) -> float:
    return output_qty / recipe.basis_quantity if recipe.basis_quantity else 1.0


def recipe_materials(
    recipe: mouneh_models.MounehRecipe, *, output_qty: float | None = None
) -> list[costing.MaterialLine]:
    """Recipe items are stored per `basis_quantity` (e.g. "this makes 100
    jars"); scale to whatever output_qty a specific batch is planning for.
    """
    scale = _scale_factor(recipe, output_qty) if output_qty is not None else 1.0
    return [
        costing.MaterialLine(
            material_id=item.material_id,
            name=item.material.name,
            category=item.material_type,
            quantity=item.quantity * scale,
            unit=item.unit,
            unit_cost=item.material.default_unit_cost,
            loss_percent=item.loss_percent,
        )
        for item in recipe.items
    ]


def components_as_lines(
    components: list[mouneh_models.CostComponent],
    recipe: mouneh_models.MounehRecipe | None = None,
    *,
    output_qty: float | None = None,
) -> list[costing.CostComponentLine]:
    """`fixed` and `quantity_x_rate` components are defined at the
    recipe's basis batch size, so they scale with it the same way
    materials do; `per_output_unit` and `percentage` are already
    self-scaling (see costing.CostComponentLine.resolved_amount)."""
    scale = _scale_factor(recipe, output_qty) if (recipe is not None and output_qty is not None) else 1.0
    lines: list[costing.CostComponentLine] = []
    for c in components:
        amount = c.amount
        quantity = c.quantity
        if c.calculation_method == "fixed" and amount is not None:
            amount = amount * scale
        if c.calculation_method == "quantity_x_rate" and quantity is not None:
            quantity = quantity * scale
        lines.append(
            costing.CostComponentLine(
                cost_type=c.cost_type,
                label=c.label or c.cost_type,
                calculation_method=c.calculation_method,
                amount=amount,
                quantity=quantity,
                unit_cost=c.unit_cost,
            )
        )
    return lines


def compute_planned_cost(db: Session, product: mouneh_models.MounehProduct, output_qty: float) -> costing.CostBreakdown | None:
    recipe = get_active_recipe(db, product.id)
    if recipe is None:
        return None
    materials = recipe_materials(recipe, output_qty=output_qty)
    components = components_as_lines(product_cost_components(db, product.id), recipe, output_qty=output_qty)
    return costing.compute_cost_breakdown(materials=materials, components=components, output_qty=output_qty)


def generate_batch_code(db: Session, farm_id: str, product: mouneh_models.MounehProduct) -> str:
    today = datetime.now(timezone.utc)
    prefix = f"{(product.category or 'GEN')[:3].upper()}-{today.strftime('%Y%m%d')}"
    existing = db.scalars(
        select(mouneh_models.ProductionBatch).where(
            mouneh_models.ProductionBatch.farm_id == farm_id,
            mouneh_models.ProductionBatch.batch_code.like(f"{prefix}%"),
        )
    ).all()
    return f"{prefix}-{len(existing) + 1:03d}"


def batch_actual_cost(
    db: Session, batch: mouneh_models.ProductionBatch, *, extra_components: list[costing.CostComponentLine] | None = None
) -> costing.CostBreakdown:
    """Actual cost from real consumption records (falls back to the
    planned/recipe quantity for any material never explicitly consumed —
    a manager who skips the granular /consume step still gets a sane
    actual cost at completion)."""
    recipe = db.get(mouneh_models.MounehRecipe, batch.recipe_version_id)
    materials = [
        costing.MaterialLine(
            material_id=c.material_id,
            name=c.material.name,
            category=next((i.material_type for i in recipe.items if i.material_id == c.material_id), "raw_material"),
            quantity=c.actual_qty if c.actual_qty is not None else c.planned_qty,
            unit="",
            unit_cost=c.unit_cost,
            loss_percent=0,  # planned_qty/actual_qty are already loss-adjusted at consumption time
        )
        for c in batch.consumptions
    ]
    components = components_as_lines(product_cost_components(db, batch.product_id))
    components += extra_components or []
    output_qty = batch.actual_output_qty or batch.planned_qty
    return costing.compute_cost_breakdown(materials=materials, components=components, output_qty=output_qty)


def product_profitability(db: Session, product: mouneh_models.MounehProduct, *, window_days: int = 30) -> dict:
    stocks = list(
        db.scalars(select(mouneh_models.FinishedGoodsStock).where(mouneh_models.FinishedGoodsStock.product_id == product.id))
    )
    sales = list(db.scalars(select(mouneh_models.MounehSaleLine).where(mouneh_models.MounehSaleLine.product_id == product.id)))

    units_produced = sum(s.quantity_produced for s in stocks)
    units_sold = sum(s.quantity_sold for s in stocks)
    units_remaining = sum(s.quantity_available for s in stocks)
    units_expired = sum(s.quantity_expired for s in stocks)
    units_damaged = sum(s.quantity_damaged for s in stocks)
    total_stock_value = sum(s.quantity_available * s.unit_cost for s in stocks)
    avg_unit_cost = (sum(s.quantity_produced * s.unit_cost for s in stocks) / units_produced) if units_produced else 0.0

    total_revenue = sum(sl.revenue for sl in sales)
    total_cost = sum(sl.cost_per_unit * sl.quantity for sl in sales)
    total_profit = sum(sl.margin for sl in sales)
    avg_sale_price = (sum(sl.unit_price * sl.quantity for sl in sales) / units_sold) if units_sold else 0.0
    gross_margin_pct = (total_profit / total_revenue * 100) if total_revenue else 0.0

    cutoff = datetime.now(timezone.utc) - timedelta(days=window_days)
    recent_units_sold = sum(sl.quantity for sl in sales if ensure_utc(sl.sold_at) >= cutoff)
    recent_revenue = sum(sl.revenue for sl in sales if ensure_utc(sl.sold_at) >= cutoff)
    recent_profit = sum(sl.margin for sl in sales if ensure_utc(sl.sold_at) >= cutoff)
    sales_velocity = recent_units_sold / window_days

    if total_revenue > 0 and gross_margin_pct < 10:
        recommendation = "review_pricing"
    elif sales_velocity > 0 and units_remaining / sales_velocity > (product.shelf_life_days or window_days):
        recommendation = "slow_mover"
    elif units_remaining == 0 and units_produced > 0 and gross_margin_pct >= 10:
        recommendation = "continue_production"
    elif sales_velocity > 0:
        recommendation = "continue_production"
    else:
        recommendation = "slow_mover" if units_produced > 0 else "continue_production"

    return {
        "product_id": product.id,
        "product_name": product.name,
        "units_produced": round(units_produced, 3),
        "units_sold": round(units_sold, 3),
        "units_remaining": round(units_remaining, 3),
        "units_expired": round(units_expired, 3),
        "units_damaged": round(units_damaged, 3),
        "avg_unit_cost": round(avg_unit_cost, 4),
        "avg_sale_price": round(avg_sale_price, 4),
        "total_revenue": round(total_revenue, 2),
        "total_cost": round(total_cost, 2),
        "total_profit": round(total_profit, 2),
        "gross_margin_pct": round(gross_margin_pct, 2),
        "sales_velocity_per_day": round(sales_velocity, 3),
        "recommendation": recommendation,
        "_total_stock_value": round(total_stock_value, 2),
        "_recent_revenue": round(recent_revenue, 2),
        "_recent_profit": round(recent_profit, 2),
    }
