"""Mouneh & Farm Product Processing — SQLAlchemy models.

Tech spec v0.5 §3 "Core Data Model". Kept in its own module (a separate
bounded context, per §10 "AI Agent Implementation Guidance": "Implement
the module as a separate bounded context with feature flags and license
checks") rather than folded into domain/models.py. Same engine-agnostic
conventions as the rest of the app (plain String ids, generic JSON).

Table/field names mirror the spec's data model table exactly; nothing
about "Makdous" is hard-coded here — see app/mouneh/seed.py for the demo
data that happens to use Makdous as its example product.
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import JSON, Boolean, DateTime, Float, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base
from app.domain.models import _now, _uuid


class ModuleLicense(Base):
    """REQ-MOU-001: super user activates/deactivates a module per farm."""

    __tablename__ = "module_licenses"
    __table_args__ = (UniqueConstraint("farm_id", "module_code", name="uq_module_license_farm_module"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    module_code: Mapped[str] = mapped_column(String(50))  # e.g. "mouneh"
    status: Mapped[str] = mapped_column(String(20), default="inactive")  # active | inactive | expired
    plan: Mapped[str] = mapped_column(String(50), default="mouneh_addon")
    starts_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    max_users: Mapped[int | None] = mapped_column(Integer, nullable=True)
    max_products: Mapped[int | None] = mapped_column(Integer, nullable=True)
    activated_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)


class MounehProduct(Base):
    """REQ-MOU-002/003: manager-defined product type, no code change needed."""

    __tablename__ = "mouneh_products"
    __table_args__ = (UniqueConstraint("farm_id", "category", "name", name="uq_mouneh_product_farm_category_name"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    name: Mapped[str] = mapped_column(String(200))
    category: Mapped[str] = mapped_column(String(100), default="general")
    photo_path: Mapped[str | None] = mapped_column(String(500), nullable=True)
    output_unit: Mapped[str] = mapped_column(String(30))  # jar|bottle|pack|kg|liter|tray|piece|custom
    custom_output_unit_label: Mapped[str | None] = mapped_column(String(50), nullable=True)
    default_batch_size: Mapped[float] = mapped_column(Float, default=1)
    shelf_life_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    warehouse_rules: Mapped[str | None] = mapped_column(Text, nullable=True)
    low_stock_threshold: Mapped[float | None] = mapped_column(Float, nullable=True)
    target_price: Mapped[float | None] = mapped_column(Float, nullable=True)
    wholesale_price: Mapped[float | None] = mapped_column(Float, nullable=True)
    target_margin_pct: Mapped[float | None] = mapped_column(Float, nullable=True)
    status: Mapped[str] = mapped_column(String(20), default="draft")  # draft|active|archived
    license_required: Mapped[str] = mapped_column(String(50), default="mouneh")
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)

    recipes: Mapped[list["MounehRecipe"]] = relationship(back_populates="product")


class MounehRecipe(Base):
    """A versioned Bill of Materials for a product. Corrections create a
    new version rather than mutating history (tech spec §7: "Batch
    completion must be immutable; corrections use adjustment events" —
    the same discipline applies to recipes feeding completed batches).
    """

    __tablename__ = "mouneh_recipes"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    product_id: Mapped[str] = mapped_column(String(36), ForeignKey("mouneh_products.id"))
    version: Mapped[int] = mapped_column(Integer, default=1)
    effective_from: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    basis_quantity: Mapped[float] = mapped_column(Float)  # e.g. 100
    basis_unit: Mapped[str] = mapped_column(String(30))  # e.g. "jar"
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    product: Mapped[MounehProduct] = relationship(back_populates="recipes")
    items: Mapped[list["MounehRecipeItem"]] = relationship(back_populates="recipe", cascade="all, delete-orphan")


class RawMaterial(Base):
    """An ingredient OR a packaging input (jars, lids, labels use
    category='packaging'; both are consumed and costed the same way).
    """

    __tablename__ = "raw_materials"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    name: Mapped[str] = mapped_column(String(200))
    category: Mapped[str] = mapped_column(String(30), default="raw_material")  # raw_material | packaging
    source_type: Mapped[str] = mapped_column(String(20), default="purchased")  # farm_produced | purchased
    inventory_item_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("inventory_items.id"), nullable=True)
    unit: Mapped[str] = mapped_column(String(20))
    default_unit_cost: Mapped[float] = mapped_column(Float, default=0)
    stock_tracking_enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    current_stock: Mapped[float] = mapped_column(Float, default=0)
    loss_percent_default: Mapped[float] = mapped_column(Float, default=0)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class MounehRecipeItem(Base):
    __tablename__ = "mouneh_recipe_items"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    recipe_id: Mapped[str] = mapped_column(String(36), ForeignKey("mouneh_recipes.id"))
    material_id: Mapped[str] = mapped_column(String(36), ForeignKey("raw_materials.id"))
    material_type: Mapped[str] = mapped_column(String(30), default="raw_material")  # snapshot of category at add-time
    quantity: Mapped[float] = mapped_column(Float)
    unit: Mapped[str] = mapped_column(String(20))
    loss_percent: Mapped[float] = mapped_column(Float, default=0)
    is_optional: Mapped[bool] = mapped_column(Boolean, default=False)

    recipe: Mapped[MounehRecipe] = relationship(back_populates="items")
    material: Mapped[RawMaterial] = relationship()


class CostComponent(Base):
    """Non-material cost rules (labor, utilities, transport, cooling/
    storage, market fees, other overhead, byproduct credit). Raw-material
    and packaging costs are NOT cost_components — they're computed from
    recipe items / batch_input_consumption, per tech spec §4's formula.

    A row with `product_id` set and `batch_id` null is a *default
    planning assumption* used for cost-preview and new batches. A row
    with `batch_id` set is the *actual* recorded cost for that specific
    batch, entered at completion time.
    """

    __tablename__ = "cost_components"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    product_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("mouneh_products.id"), nullable=True)
    batch_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("production_batches.id"), nullable=True)
    cost_type: Mapped[str] = mapped_column(String(30))
    # labor | packaging_extra | utilities | transport | cooling_storage | market_fees | byproduct_credit | other
    label: Mapped[str | None] = mapped_column(String(200), nullable=True)
    calculation_method: Mapped[str] = mapped_column(String(30), default="fixed")
    # fixed | per_output_unit | quantity_x_rate | percentage
    amount: Mapped[float | None] = mapped_column(Float, nullable=True)  # fixed amount, or % when method=percentage
    quantity: Mapped[float | None] = mapped_column(Float, nullable=True)  # e.g. hours, days
    unit_cost: Mapped[float | None] = mapped_column(Float, nullable=True)  # e.g. hourly rate
    allocation_basis: Mapped[str | None] = mapped_column(String(50), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class ProductionBatch(Base):
    __tablename__ = "production_batches"
    __table_args__ = (UniqueConstraint("farm_id", "batch_code", name="uq_batch_farm_code"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    product_id: Mapped[str] = mapped_column(String(36), ForeignKey("mouneh_products.id"))
    recipe_version_id: Mapped[str] = mapped_column(String(36), ForeignKey("mouneh_recipes.id"))
    batch_code: Mapped[str] = mapped_column(String(50))
    planned_qty: Mapped[float] = mapped_column(Float)
    actual_output_qty: Mapped[float | None] = mapped_column(Float, nullable=True)
    waste_qty: Mapped[float] = mapped_column(Float, default=0)
    damaged_qty: Mapped[float] = mapped_column(Float, default=0)
    quality_status: Mapped[str] = mapped_column(String(20), default="good")  # good | substandard | rejected
    expiry_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    warehouse_location: Mapped[str | None] = mapped_column(String(200), nullable=True)
    status: Mapped[str] = mapped_column(String(20), default="draft")  # draft|in_progress|completed|cancelled
    planned_unit_cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    planned_total_cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    actual_unit_cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    actual_total_cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    labor_hours: Mapped[float | None] = mapped_column(Float, nullable=True)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)

    consumptions: Mapped[list["BatchInputConsumption"]] = relationship(back_populates="batch", cascade="all, delete-orphan")


class BatchInputConsumption(Base):
    __tablename__ = "batch_input_consumptions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    batch_id: Mapped[str] = mapped_column(String(36), ForeignKey("production_batches.id"))
    material_id: Mapped[str] = mapped_column(String(36), ForeignKey("raw_materials.id"))
    planned_qty: Mapped[float] = mapped_column(Float)
    actual_qty: Mapped[float | None] = mapped_column(Float, nullable=True)
    unit_cost: Mapped[float] = mapped_column(Float)
    total_cost: Mapped[float | None] = mapped_column(Float, nullable=True)

    batch: Mapped[ProductionBatch] = relationship(back_populates="consumptions")
    material: Mapped[RawMaterial] = relationship()


class FinishedGoodsStock(Base):
    __tablename__ = "finished_goods_stock"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    product_id: Mapped[str] = mapped_column(String(36), ForeignKey("mouneh_products.id"))
    batch_id: Mapped[str] = mapped_column(String(36), ForeignKey("production_batches.id"))
    warehouse_location: Mapped[str | None] = mapped_column(String(200), nullable=True)
    quantity_produced: Mapped[float] = mapped_column(Float, default=0)
    quantity_available: Mapped[float] = mapped_column(Float, default=0)
    quantity_reserved: Mapped[float] = mapped_column(Float, default=0)
    quantity_sold: Mapped[float] = mapped_column(Float, default=0)
    quantity_expired: Mapped[float] = mapped_column(Float, default=0)
    quantity_damaged: Mapped[float] = mapped_column(Float, default=0)
    unit_cost: Mapped[float] = mapped_column(Float, default=0)
    expiry_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class MounehSaleLine(Base):
    __tablename__ = "mouneh_sale_lines"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    sale_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("sales.id"), nullable=True)
    product_id: Mapped[str] = mapped_column(String(36), ForeignKey("mouneh_products.id"))
    batch_id: Mapped[str] = mapped_column(String(36), ForeignKey("production_batches.id"))
    finished_goods_stock_id: Mapped[str] = mapped_column(String(36), ForeignKey("finished_goods_stock.id"))
    quantity: Mapped[float] = mapped_column(Float)
    unit_price: Mapped[float] = mapped_column(Float)
    discount: Mapped[float] = mapped_column(Float, default=0)
    customer_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("customers.id"), nullable=True)
    channel: Mapped[str] = mapped_column(String(30), default="retail")  # retail | wholesale | market | other
    cost_per_unit: Mapped[float] = mapped_column(Float)
    revenue: Mapped[float] = mapped_column(Float)
    margin: Mapped[float] = mapped_column(Float)
    sold_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    sold_by: Mapped[str | None] = mapped_column(String(36), nullable=True)


class MounehEvent(Base):
    """Mouneh-scoped mirror of the core `events` table (tech spec §9:
    "Sync conflict rules must protect inventory integrity by using event
    logs rather than overwriting stock totals"). Kept separate from
    `events` to preserve the bounded-context boundary; both feed the same
    audit discipline.
    """

    __tablename__ = "mouneh_events"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    entity_type: Mapped[str] = mapped_column(String(40))
    entity_id: Mapped[str] = mapped_column(String(36))
    event_type: Mapped[str] = mapped_column(String(50))
    payload_json: Mapped[dict] = mapped_column(JSON, default=dict)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
