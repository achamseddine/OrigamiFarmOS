"""Mouneh & Farm Product Processing — request/response schemas
(tech spec v0.5 §4 "Functional Requirements" + §11 "API Surface").

Kept in its own module alongside app/domain/mouneh_models.py and
app/mouneh/costing.py, per the "separate bounded context" guidance.
"""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, field_validator

from app.schemas.common import ORMModel

OUTPUT_UNITS = {"jar", "bottle", "pack", "kg", "liter", "tray", "piece", "custom"}
MATERIAL_CATEGORIES = {"raw_material", "packaging"}
SOURCE_TYPES = {"farm_produced", "purchased"}
COST_TYPES = {
    "labor",
    "packaging_extra",
    "utilities",
    "transport",
    "cooling_storage",
    "market_fees",
    "byproduct_credit",
    "other",
}
CALCULATION_METHODS = {"fixed", "per_output_unit", "quantity_x_rate", "percentage"}
SALE_CHANNELS = {"retail", "wholesale", "market", "other"}
BATCH_QUALITY_STATUSES = {"good", "substandard", "rejected"}


# ---------------------------------------------------------------------------
# Module license (REQ-MOU-001)
# ---------------------------------------------------------------------------
class ModuleLicenseUpdate(BaseModel):
    status: str = "active"  # active | inactive
    plan: str = "mouneh_addon"
    expires_at: datetime | None = None
    max_users: int | None = None
    max_products: int | None = None

    @field_validator("status")
    @classmethod
    def status_valid(cls, v: str) -> str:
        if v not in {"active", "inactive", "expired"}:
            raise ValueError("status must be one of active, inactive, expired")
        return v


class ModuleLicenseOut(ORMModel):
    id: str
    farm_id: str
    module_code: str
    status: str
    plan: str
    starts_at: datetime | None = None
    expires_at: datetime | None = None
    max_users: int | None = None
    max_products: int | None = None


# ---------------------------------------------------------------------------
# Raw materials (REQ-MOU-002 ingredients + packaging — same table, a
# `category` flag tells them apart)
# ---------------------------------------------------------------------------
class RawMaterialCreate(BaseModel):
    name: str
    category: str = "raw_material"
    source_type: str = "purchased"
    inventory_item_id: str | None = None
    unit: str
    default_unit_cost: float = 0
    stock_tracking_enabled: bool = True
    current_stock: float = 0
    loss_percent_default: float = 0

    @field_validator("category")
    @classmethod
    def category_valid(cls, v: str) -> str:
        if v not in MATERIAL_CATEGORIES:
            raise ValueError(f"category must be one of {sorted(MATERIAL_CATEGORIES)}")
        return v

    @field_validator("source_type")
    @classmethod
    def source_type_valid(cls, v: str) -> str:
        if v not in SOURCE_TYPES:
            raise ValueError(f"source_type must be one of {sorted(SOURCE_TYPES)}")
        return v

    @field_validator("default_unit_cost", "current_stock")
    @classmethod
    def non_negative(cls, v: float) -> float:
        if v < 0:
            raise ValueError("value cannot be negative")
        return v

    @field_validator("loss_percent_default")
    @classmethod
    def loss_percent_range(cls, v: float) -> float:
        if not (0 <= v <= 100):
            raise ValueError("loss_percent_default must be between 0 and 100")
        return v


class RawMaterialOut(ORMModel):
    id: str
    farm_id: str
    name: str
    category: str
    source_type: str
    inventory_item_id: str | None = None
    unit: str
    default_unit_cost: float
    stock_tracking_enabled: bool
    current_stock: float
    loss_percent_default: float
    active: bool


# ---------------------------------------------------------------------------
# Cost components (labor, utilities, transport, cooling/storage, market
# fees, other overhead, byproduct credit)
# ---------------------------------------------------------------------------
class CostComponentCreate(BaseModel):
    cost_type: str
    label: str | None = None
    calculation_method: str = "fixed"
    amount: float | None = None
    quantity: float | None = None
    unit_cost: float | None = None
    allocation_basis: str | None = None

    @field_validator("cost_type")
    @classmethod
    def cost_type_valid(cls, v: str) -> str:
        if v not in COST_TYPES:
            raise ValueError(f"cost_type must be one of {sorted(COST_TYPES)}")
        return v

    @field_validator("calculation_method")
    @classmethod
    def calculation_method_valid(cls, v: str) -> str:
        if v not in CALCULATION_METHODS:
            raise ValueError(f"calculation_method must be one of {sorted(CALCULATION_METHODS)}")
        return v


class CostComponentOut(ORMModel):
    id: str
    product_id: str | None = None
    batch_id: str | None = None
    cost_type: str
    label: str | None = None
    calculation_method: str
    amount: float | None = None
    quantity: float | None = None
    unit_cost: float | None = None
    allocation_basis: str | None = None


# ---------------------------------------------------------------------------
# Recipe items + recipe (REQ-MOU-002/003 — the Bill of Materials)
# ---------------------------------------------------------------------------
class RecipeItemCreate(BaseModel):
    material_id: str
    quantity: float
    unit: str
    loss_percent: float = 0
    is_optional: bool = False

    @field_validator("quantity")
    @classmethod
    def quantity_positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("quantity must be greater than zero")
        return v

    @field_validator("loss_percent")
    @classmethod
    def loss_percent_range(cls, v: float) -> float:
        if not (0 <= v <= 100):
            raise ValueError("loss_percent must be between 0 and 100")
        return v


class RecipeItemOut(ORMModel):
    id: str
    material_id: str
    material_type: str
    quantity: float
    unit: str
    loss_percent: float
    is_optional: bool


class RecipeCreate(BaseModel):
    """POST /mouneh/products/{id}/recipes. A new recipe call always creates
    a new *version* (never mutates a prior one — see tech spec's "never
    overwrite historical batch records" requirement, which extends to the
    BOM feeding those batches)."""

    basis_quantity: float
    basis_unit: str
    notes: str | None = None
    items: list[RecipeItemCreate]
    cost_components: list[CostComponentCreate] = []

    @field_validator("basis_quantity")
    @classmethod
    def basis_quantity_positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("basis_quantity must be greater than zero")
        return v

    @field_validator("items")
    @classmethod
    def items_non_empty(cls, v: list[RecipeItemCreate]) -> list[RecipeItemCreate]:
        if not v:
            raise ValueError("a recipe needs at least one raw material or packaging line")
        return v


class RecipeOut(ORMModel):
    id: str
    product_id: str
    version: int
    effective_from: datetime
    basis_quantity: float
    basis_unit: str
    active: bool
    notes: str | None = None
    items: list[RecipeItemOut] = []
    cost_components: list[CostComponentOut] = []


# ---------------------------------------------------------------------------
# Products (REQ-MOU-002/003 — the Dynamic Product Builder. No enum of
# product names/categories exists anywhere: `name`/`category` are free
# text chosen by the manager.)
# ---------------------------------------------------------------------------
class MounehProductCreate(BaseModel):
    name: str
    category: str = "general"
    photo_path: str | None = None
    output_unit: str
    custom_output_unit_label: str | None = None
    default_batch_size: float = 1
    shelf_life_days: int | None = None
    warehouse_rules: str | None = None
    low_stock_threshold: float | None = None
    target_price: float | None = None
    wholesale_price: float | None = None
    target_margin_pct: float | None = None

    @field_validator("name")
    @classmethod
    def name_non_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("name cannot be empty")
        return v.strip()

    @field_validator("output_unit")
    @classmethod
    def output_unit_valid(cls, v: str) -> str:
        if v not in OUTPUT_UNITS:
            raise ValueError(f"output_unit must be one of {sorted(OUTPUT_UNITS)}")
        return v

    @field_validator("default_batch_size")
    @classmethod
    def default_batch_size_positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("default_batch_size must be greater than zero")
        return v


class MounehProductUpdate(BaseModel):
    name: str | None = None
    category: str | None = None
    photo_path: str | None = None
    default_batch_size: float | None = None
    shelf_life_days: int | None = None
    warehouse_rules: str | None = None
    low_stock_threshold: float | None = None
    target_price: float | None = None
    wholesale_price: float | None = None
    target_margin_pct: float | None = None
    status: str | None = None  # draft | active | archived

    @field_validator("status")
    @classmethod
    def status_valid(cls, v: str | None) -> str | None:
        if v is not None and v not in {"draft", "active", "archived"}:
            raise ValueError("status must be one of draft, active, archived")
        return v


class MounehProductOut(ORMModel):
    id: str
    farm_id: str
    name: str
    category: str
    photo_path: str | None = None
    output_unit: str
    custom_output_unit_label: str | None = None
    default_batch_size: float
    shelf_life_days: int | None = None
    warehouse_rules: str | None = None
    low_stock_threshold: float | None = None
    target_price: float | None = None
    wholesale_price: float | None = None
    target_margin_pct: float | None = None
    status: str
    created_at: datetime


class MounehProductDetailOut(MounehProductOut):
    active_recipe: RecipeOut | None = None


# ---------------------------------------------------------------------------
# Cost preview (REQ-MOU-004 — "System calculates planned cost per batch
# and per unit", before a batch is even started)
# ---------------------------------------------------------------------------
class CostPreviewRequest(BaseModel):
    """Either reference an existing product/recipe, or preview an
    entirely ad-hoc set of materials/components (used by the Product
    Builder wizard before the product is even saved)."""

    product_id: str | None = None
    recipe_id: str | None = None
    output_qty: float | None = None  # defaults to the recipe's basis_quantity
    materials: list[RecipeItemCreate] | None = None
    cost_components: list[CostComponentCreate] | None = None


class CostBreakdownOut(BaseModel):
    material_cost: float
    packaging_cost: float
    labor_cost: float
    overhead_cost: float
    byproduct_credit: float
    output_qty: float
    total_cost: float
    unit_cost: float
    component_breakdown: dict[str, float]
    suggested_price: float | None = None
    minimum_price: float | None = None


# ---------------------------------------------------------------------------
# Production batches (REQ-MOU-004/005)
# ---------------------------------------------------------------------------
class ProductionBatchCreate(BaseModel):
    product_id: str
    batch_code: str | None = None  # auto-generated if omitted
    planned_qty: float
    warehouse_location: str | None = None
    notes: str | None = None

    @field_validator("planned_qty")
    @classmethod
    def planned_qty_positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("planned_qty must be greater than zero")
        return v


class BatchConsumptionLine(BaseModel):
    material_id: str
    actual_qty: float

    @field_validator("actual_qty")
    @classmethod
    def actual_qty_non_negative(cls, v: float) -> float:
        if v < 0:
            raise ValueError("actual_qty cannot be negative")
        return v


class BatchConsumeRequest(BaseModel):
    """POST /mouneh/batches/{id}/consume — records actual raw-material
    usage and deducts it from raw-material stock. Can be called
    incrementally; completion (below) does not require this to have run
    first (it falls back to planned quantities)."""

    lines: list[BatchConsumptionLine]
    allow_negative: bool = False


class BatchCompleteRequest(BaseModel):
    actual_output_qty: float
    waste_qty: float = 0
    damaged_qty: float = 0
    quality_status: str = "good"
    expiry_date: datetime | None = None
    warehouse_location: str | None = None
    labor_hours: float | None = None
    extra_cost_components: list[CostComponentCreate] = []

    @field_validator("actual_output_qty")
    @classmethod
    def actual_output_qty_positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("actual_output_qty must be greater than zero")
        return v

    @field_validator("quality_status")
    @classmethod
    def quality_status_valid(cls, v: str) -> str:
        if v not in BATCH_QUALITY_STATUSES:
            raise ValueError(f"quality_status must be one of {sorted(BATCH_QUALITY_STATUSES)}")
        return v


class BatchInputConsumptionOut(ORMModel):
    id: str
    material_id: str
    planned_qty: float
    actual_qty: float | None = None
    unit_cost: float
    total_cost: float | None = None


class ProductionBatchOut(ORMModel):
    id: str
    farm_id: str
    product_id: str
    recipe_version_id: str
    batch_code: str
    planned_qty: float
    actual_output_qty: float | None = None
    waste_qty: float
    damaged_qty: float
    quality_status: str
    expiry_date: datetime | None = None
    warehouse_location: str | None = None
    status: str
    planned_unit_cost: float | None = None
    planned_total_cost: float | None = None
    actual_unit_cost: float | None = None
    actual_total_cost: float | None = None
    labor_hours: float | None = None
    started_at: datetime
    completed_at: datetime | None = None
    notes: str | None = None
    consumptions: list[BatchInputConsumptionOut] = []


# ---------------------------------------------------------------------------
# Finished goods + sales (REQ-MOU-005/006)
# ---------------------------------------------------------------------------
class FinishedGoodsStockOut(ORMModel):
    id: str
    farm_id: str
    product_id: str
    batch_id: str
    warehouse_location: str | None = None
    quantity_produced: float
    quantity_available: float
    quantity_reserved: float
    quantity_sold: float
    quantity_expired: float
    quantity_damaged: float
    unit_cost: float
    expiry_date: datetime | None = None


class MounehSaleCreate(BaseModel):
    product_id: str
    finished_goods_stock_id: str | None = None  # auto-picked (oldest expiry first) if omitted
    quantity: float
    unit_price: float
    discount: float = 0
    customer_id: str | None = None
    channel: str = "retail"

    @field_validator("quantity", "unit_price")
    @classmethod
    def positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("value must be greater than zero")
        return v

    @field_validator("discount")
    @classmethod
    def discount_non_negative(cls, v: float) -> float:
        if v < 0:
            raise ValueError("discount cannot be negative")
        return v

    @field_validator("channel")
    @classmethod
    def channel_valid(cls, v: str) -> str:
        if v not in SALE_CHANNELS:
            raise ValueError(f"channel must be one of {sorted(SALE_CHANNELS)}")
        return v


class MounehSaleOut(ORMModel):
    id: str
    farm_id: str
    product_id: str
    batch_id: str
    finished_goods_stock_id: str
    quantity: float
    unit_price: float
    discount: float
    customer_id: str | None = None
    channel: str
    cost_per_unit: float
    revenue: float
    margin: float
    sold_at: datetime


# ---------------------------------------------------------------------------
# Dashboards (REQ-MOU-007 — "Dashboard shows production, cost, sales,
# remaining stock and profitability")
# ---------------------------------------------------------------------------
class ProductProfitabilityOut(BaseModel):
    product_id: str
    product_name: str
    units_produced: float
    units_sold: float
    units_remaining: float
    units_expired: float
    units_damaged: float
    avg_unit_cost: float
    avg_sale_price: float
    total_revenue: float
    total_cost: float
    total_profit: float
    gross_margin_pct: float
    sales_velocity_per_day: float
    recommendation: str  # continue_production | slow_mover | review_pricing


class MounehDashboardOut(BaseModel):
    module_status: str
    total_products: int
    active_batches: int
    total_finished_units: float
    total_stock_value: float
    total_revenue_30d: float
    total_profit_30d: float
    best_sellers: list[ProductProfitabilityOut]
    slow_movers: list[ProductProfitabilityOut]
