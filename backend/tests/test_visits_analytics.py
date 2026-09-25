"""Unit tests for the Farm Visits & Agri-Tourism pure analytics engine
(app/visits/analytics.py) — tech spec v0.6 §5/§9. No DB involved.
"""
import pytest

from app.visits import analytics


class TestStatusTransitions:
    def test_draft_can_be_confirmed(self):
        analytics.validate_status_transition("draft", "confirmed")  # does not raise

    def test_draft_can_be_cancelled(self):
        analytics.validate_status_transition("draft", "cancelled")

    def test_confirmed_can_be_checked_in_or_no_show_or_cancelled(self):
        for target in ("checked_in", "no_show", "cancelled"):
            analytics.validate_status_transition("confirmed", target)

    def test_checked_in_can_only_complete_or_cancel(self):
        analytics.validate_status_transition("checked_in", "completed")
        analytics.validate_status_transition("checked_in", "cancelled")
        with pytest.raises(ValueError):
            analytics.validate_status_transition("checked_in", "draft")

    def test_completed_cancelled_no_show_can_be_refunded(self):
        for start in ("completed", "cancelled", "no_show"):
            analytics.validate_status_transition(start, "refunded")

    def test_refunded_is_terminal(self):
        with pytest.raises(ValueError):
            analytics.validate_status_transition("refunded", "confirmed")

    def test_cannot_skip_straight_from_draft_to_checked_in(self):
        with pytest.raises(ValueError):
            analytics.validate_status_transition("draft", "checked_in")

    def test_cannot_go_backwards_from_confirmed_to_draft(self):
        with pytest.raises(ValueError):
            analytics.validate_status_transition("confirmed", "draft")

    def test_unknown_status_raises(self):
        with pytest.raises(ValueError):
            analytics.validate_status_transition("draft", "made_up_status")
        with pytest.raises(ValueError):
            analytics.validate_status_transition("made_up_status", "draft")


class TestSessionCapacity:
    def test_accepts_when_within_capacity(self):
        analytics.validate_session_capacity(capacity=10, already_booked=6, requested=4)  # does not raise

    def test_rejects_when_capacity_would_be_exceeded(self):
        with pytest.raises(ValueError, match="only 3"):
            analytics.validate_session_capacity(capacity=10, already_booked=7, requested=4)

    def test_exact_capacity_is_allowed(self):
        analytics.validate_session_capacity(capacity=10, already_booked=6, requested=4)

    def test_negative_requested_raises(self):
        with pytest.raises(ValueError):
            analytics.validate_session_capacity(capacity=10, already_booked=0, requested=-1)


class TestActivityCapacityAndWelfare:
    def test_activity_capacity_rejects_overbooking(self):
        with pytest.raises(ValueError, match="only 1"):
            analytics.validate_activity_capacity(capacity_per_slot=4, already_booked=3, requested=2)

    def test_activity_capacity_accepts_exact_fit(self):
        analytics.validate_activity_capacity(capacity_per_slot=4, already_booked=2, requested=2)

    def test_welfare_limit_none_never_blocks(self):
        analytics.validate_welfare_limit(welfare_limit=None, uses_today=99, requested=10)

    def test_welfare_limit_blocks_when_exceeded(self):
        with pytest.raises(ValueError, match="welfare"):
            analytics.validate_welfare_limit(welfare_limit={"max_uses_per_day": 6}, uses_today=5, requested=2)

    def test_welfare_limit_allows_exact_max(self):
        analytics.validate_welfare_limit(welfare_limit={"max_uses_per_day": 6}, uses_today=4, requested=2)

    def test_handler_assignment_required_and_missing(self):
        with pytest.raises(ValueError, match="horse_handler"):
            analytics.validate_handler_assignment(requires_staff_role="horse_handler", assigned_roles={"guide", "cashier"})

    def test_handler_assignment_present(self):
        analytics.validate_handler_assignment(requires_staff_role="horse_handler", assigned_roles={"guide", "horse_handler"})

    def test_handler_assignment_not_required(self):
        analytics.validate_handler_assignment(requires_staff_role=None, assigned_roles=set())


class TestAnalyticsFormulas:
    def test_visitor_revenue_sums_three_sources(self):
        assert analytics.compute_visitor_revenue(package_revenue=100, activity_revenue=20, retail_revenue=30) == 150

    def test_direct_visit_cost_sums_all_categories(self):
        assert analytics.compute_direct_visit_cost(
            staff_cost=40, activity_cost=10, included_product_cost=5, cleaning_utilities_cost=15, other_cost=2
        ) == 72

    def test_gross_margin_can_be_negative(self):
        assert analytics.compute_gross_margin(visitor_revenue=50, direct_visit_cost=80) == -30

    def test_revenue_per_visitor(self):
        assert analytics.compute_revenue_per_visitor(visitor_revenue=150, checked_in_visitors=10) == 15.0

    def test_revenue_per_visitor_zero_visitors_is_safe(self):
        assert analytics.compute_revenue_per_visitor(visitor_revenue=150, checked_in_visitors=0) == 0.0

    def test_activity_utilization_percentage(self):
        assert analytics.compute_activity_utilization(sold_slots=3, available_slots=4) == 75.0

    def test_activity_utilization_zero_available_is_safe(self):
        assert analytics.compute_activity_utilization(sold_slots=0, available_slots=0) == 0.0

    def test_retail_conversion_percentage(self):
        assert analytics.compute_retail_conversion(visitors_with_purchase=4, checked_in_visitors=10) == 40.0

    def test_average_basket_value(self):
        assert analytics.compute_average_basket_value(retail_sales_total=60, purchase_count=4) == 15.0

    def test_average_basket_value_zero_purchases_is_safe(self):
        assert analytics.compute_average_basket_value(retail_sales_total=0, purchase_count=0) == 0.0

    def test_package_profitability(self):
        assert analytics.compute_package_profitability(package_revenue=200, allocated_costs=120) == 80


class TestSummarizeProfitability:
    def test_full_summary_matches_component_formulas(self):
        summary = analytics.summarize_profitability(
            package_revenue=100, activity_revenue=20, retail_revenue=30,
            staff_cost=40, activity_cost=5, included_product_cost=5, cleaning_utilities_cost=10, other_cost=0,
            checked_in_visitors=10, visitors_with_purchase=4, purchase_count=5,
        )
        assert summary.visitor_revenue == 150
        assert summary.direct_visit_cost == 60
        assert summary.gross_margin == 90
        assert summary.revenue_per_visitor == 15.0
        assert summary.retail_conversion_pct == 40.0
        assert summary.average_basket_value == 6.0
        assert summary.checked_in_visitors == 10
