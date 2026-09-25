"""Mouneh & Farm Product Processing — costing engine (tech spec v0.5 §7
"Cost Calculation Logic").

Pure functions: everything here takes plain values in and returns plain
dataclasses out, no DB access, so the whole costing formula is unit
testable directly (see tests/test_mouneh_costing.py). Mirrors the pattern
already used by app/recommendations/engine.py — the DB-touching side
(app/api/v1/mouneh.py) loads recipe/consumption rows and calls these.

Core formula:

    Unit Cost = (Raw Material Cost + Packaging Cost + Labor Cost
                 + Processing Overhead + Logistics Cost
                 + Storage/Cooling Cost + Other Allocated Costs
                 - Byproduct Value) / Sellable Output Quantity

The same `compute_cost_breakdown` is used for both the *planned* cost
(recipe quantities x default unit costs, before a batch starts) and the
*actual* cost (real consumption quantities x real unit costs, after a
batch completes) — the caller decides which inputs to pass.
"""
from __future__ import annotations

from dataclasses import dataclass, field

LABOR_COST_TYPE = "labor"
BYPRODUCT_CREDIT_TYPE = "byproduct_credit"
MINIMUM_MARGIN_PCT_OVER_COST = 10.0  # a suggested price is never below cost + 10%


@dataclass(frozen=True)
class MaterialLine:
    """One raw-material or packaging line consumed by a batch — planned
    (recipe quantity x default unit cost) or actual (real consumption)."""

    material_id: str
    name: str
    category: str  # raw_material | packaging
    quantity: float
    unit: str
    unit_cost: float
    loss_percent: float = 0.0

    @property
    def effective_quantity(self) -> float:
        """Loss/spoilage % means more input has to be bought/used than the
        recipe's clean quantity — e.g. peeling loss on eggplant."""
        return self.quantity * (1 + max(self.loss_percent, 0) / 100)

    @property
    def line_cost(self) -> float:
        return self.effective_quantity * self.unit_cost


@dataclass(frozen=True)
class CostComponentLine:
    """One non-material cost line: labor, utilities, transport, cooling,
    storage, market fees/commissions, other overhead, or a byproduct
    credit (income that offsets cost, e.g. selling eggplant trimmings)."""

    cost_type: str
    label: str
    calculation_method: str  # fixed | per_output_unit | quantity_x_rate | percentage
    amount: float | None = None  # fixed total, or % when method == percentage
    quantity: float | None = None  # e.g. labor hours
    unit_cost: float | None = None  # e.g. hourly wage

    def resolved_amount(self, *, output_qty: float, subtotal_before_this: float) -> float:
        if self.calculation_method == "fixed":
            return self.amount or 0.0
        if self.calculation_method == "per_output_unit":
            return (self.amount or 0.0) * max(output_qty, 0)
        if self.calculation_method == "quantity_x_rate":
            return (self.quantity or 0.0) * (self.unit_cost or 0.0)
        if self.calculation_method == "percentage":
            return subtotal_before_this * ((self.amount or 0.0) / 100)
        raise ValueError(f"Unknown calculation_method: {self.calculation_method!r}")


@dataclass(frozen=True)
class CostBreakdown:
    material_cost: float
    packaging_cost: float
    labor_cost: float
    overhead_cost: float  # utilities + transport + cooling_storage + market_fees + other
    byproduct_credit: float
    output_qty: float
    total_cost: float
    unit_cost: float
    component_breakdown: dict[str, float] = field(default_factory=dict)


def compute_cost_breakdown(
    *,
    materials: list[MaterialLine],
    components: list[CostComponentLine],
    output_qty: float,
) -> CostBreakdown:
    """REQ-MOU-004/005: "System calculates planned cost per batch and per
    unit." Also used, unchanged, to price actual/closed batches — see
    module docstring.
    """
    if output_qty <= 0:
        raise ValueError("output_qty must be greater than zero to compute a unit cost")

    material_cost = sum(m.line_cost for m in materials if m.category != "packaging")
    packaging_cost = sum(m.line_cost for m in materials if m.category == "packaging")

    labor_cost = 0.0
    overhead_cost = 0.0
    byproduct_credit = 0.0
    component_breakdown: dict[str, float] = {}

    # `percentage`-method components (e.g. "market fee = 5% of cost so
    # far") are resolved against a running subtotal, so component order
    # matters: apply materials/packaging first, then components in the
    # order given.
    running_subtotal = material_cost + packaging_cost
    for component in components:
        resolved = component.resolved_amount(output_qty=output_qty, subtotal_before_this=running_subtotal)
        key = component.label or component.cost_type
        component_breakdown[key] = component_breakdown.get(key, 0.0) + resolved

        if component.cost_type == LABOR_COST_TYPE:
            labor_cost += resolved
            running_subtotal += resolved
        elif component.cost_type == BYPRODUCT_CREDIT_TYPE:
            byproduct_credit += resolved
            running_subtotal -= resolved
        else:
            overhead_cost += resolved
            running_subtotal += resolved

    total_cost = material_cost + packaging_cost + labor_cost + overhead_cost - byproduct_credit
    unit_cost = total_cost / output_qty

    return CostBreakdown(
        material_cost=round(material_cost, 4),
        packaging_cost=round(packaging_cost, 4),
        labor_cost=round(labor_cost, 4),
        overhead_cost=round(overhead_cost, 4),
        byproduct_credit=round(byproduct_credit, 4),
        output_qty=output_qty,
        total_cost=round(total_cost, 4),
        unit_cost=round(unit_cost, 4),
        component_breakdown={k: round(v, 4) for k, v in component_breakdown.items()},
    )


@dataclass(frozen=True)
class PriceSuggestion:
    unit_cost: float
    target_margin_pct: float
    suggested_price: float
    minimum_price: float


def suggest_price(*, unit_cost: float, target_margin_pct: float) -> PriceSuggestion:
    """Margin is expressed on selling price (the retail convention): a
    unit costing $2 at a 40% target margin suggests $3.33 (2 / (1-0.4)),
    not $2.80. Never suggests below cost + a floor margin, even if a
    manager types a 0% or negative target.
    """
    if unit_cost < 0:
        raise ValueError("unit_cost cannot be negative")
    margin_fraction = min(max(target_margin_pct, 0) / 100, 0.95)
    suggested = unit_cost / (1 - margin_fraction) if margin_fraction < 1 else unit_cost
    minimum = unit_cost * (1 + MINIMUM_MARGIN_PCT_OVER_COST / 100)
    return PriceSuggestion(
        unit_cost=round(unit_cost, 4),
        target_margin_pct=target_margin_pct,
        suggested_price=round(max(suggested, minimum), 4),
        minimum_price=round(minimum, 4),
    )


@dataclass(frozen=True)
class SaleMargin:
    revenue: float
    cost: float
    profit: float
    margin_pct: float


def compute_sale_margin(*, quantity: float, unit_price: float, discount: float, unit_cost: float) -> SaleMargin:
    """REQ-MOU-006: "Sales reduce finished goods stock and calculate
    profit." Cost is priced at the *batch's actual unit cost at the time
    of sale* (frozen onto finished_goods_stock.unit_cost when the batch
    completes), never recomputed retroactively — so a later recipe change
    never rewrites the profit of a past sale.
    """
    if quantity <= 0:
        raise ValueError("quantity must be greater than zero")
    if discount < 0:
        raise ValueError("discount cannot be negative")
    revenue = max(quantity * unit_price - discount, 0.0)
    cost = quantity * unit_cost
    profit = revenue - cost
    margin_pct = (profit / revenue * 100) if revenue > 0 else 0.0
    return SaleMargin(
        revenue=round(revenue, 4),
        cost=round(cost, 4),
        profit=round(profit, 4),
        margin_pct=round(margin_pct, 2),
    )
