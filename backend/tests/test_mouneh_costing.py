"""Unit tests for the Mouneh costing engine (app/mouneh/costing.py) —
tech spec v0.5 §7 "Cost Calculation Logic". Pure functions, no DB.
"""
import pytest

from app.mouneh import costing


def _materials():
    return [
        costing.MaterialLine("m1", "Baby eggplant", "raw_material", 20, "kg", 1.5, loss_percent=5),
        costing.MaterialLine("m2", "Walnuts", "raw_material", 2, "kg", 8, loss_percent=0),
        costing.MaterialLine("m3", "Jars", "packaging", 100, "piece", 0.35),
    ]


class TestMaterialLine:
    def test_loss_percent_inflates_effective_quantity_and_cost(self):
        line = costing.MaterialLine("m1", "Eggplant", "raw_material", 100, "kg", 1.0, loss_percent=10)
        assert line.effective_quantity == pytest.approx(110)
        assert line.line_cost == pytest.approx(110)

    def test_zero_loss_percent_is_a_no_op(self):
        line = costing.MaterialLine("m1", "Eggplant", "raw_material", 100, "kg", 2.0, loss_percent=0)
        assert line.effective_quantity == 100
        assert line.line_cost == 200


class TestCostComponentLine:
    def test_fixed_ignores_output_qty(self):
        c = costing.CostComponentLine("utilities", "Gas", "fixed", amount=12)
        assert c.resolved_amount(output_qty=1, subtotal_before_this=0) == 12
        assert c.resolved_amount(output_qty=1000, subtotal_before_this=0) == 12

    def test_per_output_unit_scales_with_output(self):
        c = costing.CostComponentLine("transport", "Delivery", "per_output_unit", amount=0.1)
        assert c.resolved_amount(output_qty=100, subtotal_before_this=0) == pytest.approx(10)

    def test_quantity_x_rate_multiplies_hours_by_wage(self):
        c = costing.CostComponentLine("labor", "Labor", "quantity_x_rate", quantity=6, unit_cost=5)
        assert c.resolved_amount(output_qty=100, subtotal_before_this=0) == 30

    def test_percentage_applies_to_running_subtotal(self):
        c = costing.CostComponentLine("market_fees", "Commission", "percentage", amount=10)
        assert c.resolved_amount(output_qty=1, subtotal_before_this=200) == pytest.approx(20)

    def test_unknown_method_raises(self):
        c = costing.CostComponentLine("other", "Mystery", "not_a_method")
        with pytest.raises(ValueError):
            c.resolved_amount(output_qty=1, subtotal_before_this=0)


class TestComputeCostBreakdown:
    def test_zero_output_qty_raises(self):
        with pytest.raises(ValueError):
            costing.compute_cost_breakdown(materials=[], components=[], output_qty=0)

    def test_material_and_packaging_costs_are_split(self):
        breakdown = costing.compute_cost_breakdown(materials=_materials(), components=[], output_qty=100)
        # eggplant: 20 * 1.05 * 1.5 = 31.5 ; walnuts: 2 * 8 = 16
        assert breakdown.material_cost == pytest.approx(47.5)
        assert breakdown.packaging_cost == pytest.approx(35.0)
        assert breakdown.labor_cost == 0
        assert breakdown.total_cost == pytest.approx(82.5)
        assert breakdown.unit_cost == pytest.approx(0.825)

    def test_full_formula_matches_hand_calculation(self):
        components = [
            costing.CostComponentLine("labor", "Labor", "quantity_x_rate", quantity=6, unit_cost=5),
            costing.CostComponentLine("utilities", "Gas/Electricity", "fixed", amount=12),
            costing.CostComponentLine("transport", "Delivery", "per_output_unit", amount=0.1),
        ]
        breakdown = costing.compute_cost_breakdown(materials=_materials(), components=components, output_qty=100)
        # materials 47.5 + packaging 35 + labor 30 + utilities 12 + transport 10 = 134.5
        assert breakdown.total_cost == pytest.approx(134.5)
        assert breakdown.unit_cost == pytest.approx(1.345)
        assert breakdown.component_breakdown["Labor"] == pytest.approx(30.0)
        assert breakdown.component_breakdown["Delivery"] == pytest.approx(10.0)

    def test_byproduct_credit_reduces_total_cost(self):
        components = [costing.CostComponentLine("byproduct_credit", "Trimmings sold", "fixed", amount=15)]
        breakdown = costing.compute_cost_breakdown(materials=_materials(), components=components, output_qty=100)
        assert breakdown.byproduct_credit == 15
        assert breakdown.total_cost == pytest.approx(82.5 - 15)

    def test_percentage_component_is_applied_after_prior_components(self):
        components = [
            costing.CostComponentLine("labor", "Labor", "fixed", amount=20),
            costing.CostComponentLine("market_fees", "Commission", "percentage", amount=10),
        ]
        # subtotal before commission = 47.5 (materials) + 35 (packaging) + 20 (labor) = 102.5
        breakdown = costing.compute_cost_breakdown(materials=_materials(), components=components, output_qty=100)
        assert breakdown.component_breakdown["Commission"] == pytest.approx(10.25)
        assert breakdown.total_cost == pytest.approx(82.5 + 20 + 10.25)


class TestSuggestPrice:
    def test_margin_is_expressed_on_selling_price(self):
        suggestion = costing.suggest_price(unit_cost=2.0, target_margin_pct=40)
        # price = cost / (1 - margin) = 2 / 0.6 = 3.333..
        assert suggestion.suggested_price == pytest.approx(3.3333, abs=1e-3)

    def test_negative_unit_cost_raises(self):
        with pytest.raises(ValueError):
            costing.suggest_price(unit_cost=-1, target_margin_pct=20)

    def test_never_suggests_below_the_cost_floor(self):
        suggestion = costing.suggest_price(unit_cost=5.0, target_margin_pct=0)
        assert suggestion.suggested_price >= suggestion.minimum_price
        assert suggestion.minimum_price == pytest.approx(5.5)

    def test_margin_above_95_percent_is_clamped(self):
        suggestion = costing.suggest_price(unit_cost=1.0, target_margin_pct=999)
        # margin fraction clamped to 0.95 -> price = 1 / 0.05 = 20
        assert suggestion.suggested_price == pytest.approx(20.0)


class TestComputeSaleMargin:
    def test_basic_margin_calculation(self):
        margin = costing.compute_sale_margin(quantity=10, unit_price=5, discount=0, unit_cost=2)
        assert margin.revenue == 50
        assert margin.cost == 20
        assert margin.profit == 30
        assert margin.margin_pct == pytest.approx(60.0)

    def test_discount_reduces_revenue(self):
        margin = costing.compute_sale_margin(quantity=10, unit_price=5, discount=5, unit_cost=2)
        assert margin.revenue == 45
        assert margin.profit == 25

    def test_revenue_never_goes_negative(self):
        margin = costing.compute_sale_margin(quantity=1, unit_price=1, discount=100, unit_cost=0.5)
        assert margin.revenue == 0
        assert margin.margin_pct == 0

    def test_zero_quantity_raises(self):
        with pytest.raises(ValueError):
            costing.compute_sale_margin(quantity=0, unit_price=5, discount=0, unit_cost=2)

    def test_negative_discount_raises(self):
        with pytest.raises(ValueError):
            costing.compute_sale_margin(quantity=1, unit_price=5, discount=-1, unit_cost=2)
