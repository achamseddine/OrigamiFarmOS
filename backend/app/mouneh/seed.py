"""Demo data for the Mouneh & Farm Product Processing module.

Tech spec v0.5: "Use Makdous only as demo data." Nothing about Makdous is
special-cased in the module's code — this file builds it the same way a
farm manager would through the Product Builder Wizard / Recipe screen /
Batch screen, just with direct ORM inserts instead of HTTP calls (this
runs at seed time, before any request context exists). Swapping every
"Makdous" string below for "Kishk" or "Rose Jam" would produce an
equally valid product with zero code changes elsewhere.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.security import hash_password
from app.domain import mouneh_models
from app.domain import models as core_models
from app.mouneh import costing
from app.repositories.base import new_id

MOUNEH_MODULE_CODE = "mouneh"


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _days_ago(n: int) -> datetime:
    return _now() - timedelta(days=n)


def seed_mouneh_demo_data(db: Session, farm_id: str) -> None:
    existing = db.scalars(
        select(mouneh_models.ModuleLicense).where(
            mouneh_models.ModuleLicense.farm_id == farm_id, mouneh_models.ModuleLicense.module_code == MOUNEH_MODULE_CODE
        )
    ).first()
    if existing is not None:
        print("Mouneh demo data already present — skipping.")
        return

    # ---- Super user + module activation (REQ-MOU-001) ---------------------
    super_user_id = "user-super-1"
    if db.get(core_models.User, super_user_id) is None:
        db.add(
            core_models.User(
                id=super_user_id,
                farm_id=farm_id,
                name="Sami Nassar (Platform Admin)",
                email="super@origamifarms.com",
                password_hash=hash_password("farmos123"),
                role="super_user",
                language="en",
            )
        )

    license_row = mouneh_models.ModuleLicense(
        id=new_id(),
        farm_id=farm_id,
        module_code=MOUNEH_MODULE_CODE,
        status="active",
        plan="mouneh_addon",
        starts_at=_days_ago(60),
        activated_by=super_user_id,
    )
    db.add(license_row)

    # ---- Raw materials + packaging -----------------------------------
    materials_def = [
        ("mat-eggplant", "Baby Eggplant", "raw_material", "farm_produced", "kg", 1.20, 320, 6),
        ("mat-walnuts", "Walnuts", "raw_material", "purchased", "kg", 7.50, 25, 0),
        ("mat-pepper-paste", "Red Pepper Paste", "raw_material", "purchased", "kg", 3.80, 18, 0),
        ("mat-garlic", "Garlic", "raw_material", "farm_produced", "kg", 2.10, 12, 3),
        ("mat-olive-oil", "Olive Oil", "raw_material", "farm_produced", "liter", 6.50, 60, 0),
        ("mat-salt", "Salt", "raw_material", "purchased", "kg", 0.35, 40, 0),
        ("mat-jars", "Glass Jars (500ml)", "packaging", "purchased", "piece", 0.35, 600, 1),
        ("mat-lids", "Jar Lids", "packaging", "purchased", "piece", 0.08, 600, 1),
        ("mat-labels", "Labels", "packaging", "purchased", "piece", 0.05, 600, 0),
    ]
    for mid, name, category, source_type, unit, cost, stock, loss in materials_def:
        db.add(
            mouneh_models.RawMaterial(
                id=mid, farm_id=farm_id, name=name, category=category, source_type=source_type,
                unit=unit, default_unit_cost=cost, current_stock=stock, loss_percent_default=loss,
            )
        )

    # ---- Product (Dynamic Product Builder) -----------------------------
    product = mouneh_models.MounehProduct(
        id="prod-makdous",
        farm_id=farm_id,
        name="Makdous",
        category="Mouneh",
        output_unit="jar",
        default_batch_size=100,
        shelf_life_days=365,
        warehouse_rules="Store in a cool, dark room. Fully submerged in olive oil.",
        low_stock_threshold=20,
        target_price=6.50,
        wholesale_price=5.00,
        target_margin_pct=40,
        status="active",
        created_by=super_user_id,
    )
    db.add(product)

    # ---- Recipe (Bill of Materials, per a 100-jar batch) ----------------
    recipe = mouneh_models.MounehRecipe(
        id="recipe-makdous-v1", product_id=product.id, version=1, basis_quantity=100, basis_unit="jar",
        notes="Standard Makdous recipe — baby eggplant stuffed with walnuts, red pepper paste and garlic, cured in olive oil.",
    )
    db.add(recipe)

    recipe_items_def = [
        ("mat-eggplant", 45, "kg", 6),
        ("mat-walnuts", 4, "kg", 0),
        ("mat-pepper-paste", 3, "kg", 0),
        ("mat-garlic", 2, "kg", 3),
        ("mat-olive-oil", 18, "liter", 0),
        ("mat-salt", 2.5, "kg", 0),
        ("mat-jars", 100, "piece", 1),
        ("mat-lids", 100, "piece", 1),
        ("mat-labels", 100, "piece", 0),
    ]
    material_lookup = {m[0]: m for m in materials_def}
    for material_id, qty, unit, loss in recipe_items_def:
        db.add(
            mouneh_models.MounehRecipeItem(
                id=new_id(), recipe_id=recipe.id, material_id=material_id,
                material_type=material_lookup[material_id][2], quantity=qty, unit=unit, loss_percent=loss,
            )
        )

    cost_components_def = [
        ("labor", "Labor (curing + packing)", "quantity_x_rate", None, 10, 5.0),
        ("utilities", "Gas & Electricity", "fixed", 14, None, None),
        ("transport", "Delivery to market", "per_output_unit", 0.10, None, None),
        ("cooling_storage", "Cold storage allocation", "fixed", 8, None, None),
        ("market_fees", "Co-op commission", "percentage", 3, None, None),
    ]
    for cost_type, label, method, amount, quantity, unit_cost in cost_components_def:
        db.add(
            mouneh_models.CostComponent(
                id=new_id(), product_id=product.id, cost_type=cost_type, label=label, calculation_method=method,
                amount=amount, quantity=quantity, unit_cost=unit_cost,
            )
        )

    db.flush()  # so relationships below can be loaded

    # ---- One completed batch -> finished goods stock ---------------------
    materials = [
        costing.MaterialLine(
            material_id=mid, name=material_lookup[mid][1], category=material_lookup[mid][2],
            quantity=qty, unit=unit, unit_cost=material_lookup[mid][5], loss_percent=loss,
        )
        for mid, qty, unit, loss in recipe_items_def
    ]
    components = [
        costing.CostComponentLine(cost_type=t, label=l, calculation_method=m, amount=a, quantity=q, unit_cost=uc)
        for t, l, m, a, q, uc in cost_components_def
    ]
    breakdown = costing.compute_cost_breakdown(materials=materials, components=components, output_qty=98)

    batch = mouneh_models.ProductionBatch(
        id="batch-makdous-001",
        farm_id=farm_id,
        product_id=product.id,
        recipe_version_id=recipe.id,
        batch_code="MOU-20260620-001",
        planned_qty=100,
        actual_output_qty=98,
        waste_qty=2,
        damaged_qty=0,
        quality_status="good",
        expiry_date=_now() + timedelta(days=350),
        warehouse_location="Storage Room A — Shelf 3",
        status="completed",
        planned_unit_cost=breakdown.unit_cost,
        planned_total_cost=breakdown.total_cost,
        actual_unit_cost=breakdown.unit_cost,
        actual_total_cost=breakdown.total_cost,
        labor_hours=10,
        started_at=_days_ago(66),
        completed_at=_days_ago(65),
        created_by=super_user_id,
    )
    db.add(batch)
    db.flush()

    for line in materials:
        db.add(
            mouneh_models.BatchInputConsumption(
                id=new_id(), batch_id=batch.id, material_id=line.material_id,
                planned_qty=line.effective_quantity, actual_qty=line.effective_quantity,
                unit_cost=line.unit_cost, total_cost=line.line_cost,
            )
        )

    stock = mouneh_models.FinishedGoodsStock(
        id="stock-makdous-001",
        farm_id=farm_id,
        product_id=product.id,
        batch_id=batch.id,
        warehouse_location=batch.warehouse_location,
        quantity_produced=98,
        quantity_available=98,
        unit_cost=breakdown.unit_cost,
        expiry_date=batch.expiry_date,
    )
    db.add(stock)
    db.flush()

    # ---- A second, still-in-progress batch (dashboard "active batches") --
    batch2_breakdown = costing.compute_cost_breakdown(
        materials=[
            costing.MaterialLine(
                material_id=mid, name=material_lookup[mid][1], category=material_lookup[mid][2],
                quantity=qty * 0.6, unit=unit, unit_cost=material_lookup[mid][5], loss_percent=loss,
            )
            for mid, qty, unit, loss in recipe_items_def
        ],
        components=components,
        output_qty=60,
    )
    batch2 = mouneh_models.ProductionBatch(
        id="batch-makdous-002",
        farm_id=farm_id,
        product_id=product.id,
        recipe_version_id=recipe.id,
        batch_code="MOU-20260821-001",
        planned_qty=60,
        status="in_progress",
        planned_unit_cost=batch2_breakdown.unit_cost,
        planned_total_cost=batch2_breakdown.total_cost,
        warehouse_location="Storage Room A — Shelf 3",
        started_at=_days_ago(2),
        created_by=super_user_id,
    )
    db.add(batch2)
    db.flush()
    for mid, qty, unit, loss in recipe_items_def:
        scale = 60 / 100
        eff_qty = qty * scale * (1 + loss / 100)
        db.add(
            mouneh_models.BatchInputConsumption(
                id=new_id(), batch_id=batch2.id, material_id=mid, planned_qty=eff_qty,
                unit_cost=material_lookup[mid][5],
            )
        )

    # ---- Sales against the completed batch's finished goods -------------
    sales_def = [
        (20, 6.50, 0, "retail", 8),
        (15, 5.00, 5, "wholesale", 5),
        (10, 6.50, 0, "market", 2),
    ]
    for qty, price, discount, channel, days_ago in sales_def:
        margin = costing.compute_sale_margin(quantity=qty, unit_price=price, discount=discount, unit_cost=stock.unit_cost)
        db.add(
            mouneh_models.MounehSaleLine(
                id=new_id(), farm_id=farm_id, product_id=product.id, batch_id=batch.id,
                finished_goods_stock_id=stock.id, quantity=qty, unit_price=price, discount=discount,
                channel=channel, cost_per_unit=stock.unit_cost, revenue=margin.revenue, margin=margin.profit,
                sold_at=_days_ago(days_ago), sold_by=super_user_id,
            )
        )
        stock.quantity_available -= qty
        stock.quantity_sold += qty

    for entity_type, entity_id, event_type, payload in [
        ("mouneh_product", product.id, "product_created", {"name": product.name}),
        ("mouneh_recipe", recipe.id, "recipe_created", {"product_id": product.id, "version": 1}),
        ("production_batch", batch.id, "batch_completed", {"actual_output_qty": 98}),
        ("production_batch", batch2.id, "batch_started", {"planned_qty": 60}),
    ]:
        db.add(
            mouneh_models.MounehEvent(
                id=new_id(), farm_id=farm_id, entity_type=entity_type, entity_id=entity_id,
                event_type=event_type, payload_json=payload, created_by=super_user_id, created_at=_now(),
            )
        )

    print(f"Seeded Mouneh demo data (Makdous) for farm '{farm_id}'. Super user login: super@origamifarms.com / farmos123")
