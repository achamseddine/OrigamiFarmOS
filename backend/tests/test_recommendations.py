"""Unit tests for the rule-based recommendation engine (tech spec §15/§20:
"Unit tests: ... recommendation rules ...").
"""
from app.recommendations import engine


class TestHealthRisk:
    def test_full_signal_set_is_high_priority(self):
        rec = engine.evaluate_health_risk(
            entity_type="animal",
            entity_id="cow-744",
            entity_label="Cow 744",
            milk_change_pct=-18,
            feed_change_pct=-12,
            temperature_c=39.6,
            prior_condition_count=2,
            prior_condition_label="Mastitis",
        )
        assert rec is not None
        assert rec.priority == "high"
        assert rec.rule_id == "RULE-HEALTH-RISK"
        assert rec.confidence > 0.8
        assert {e.label for e in rec.evidence} == {"Milk Yield", "Feed Intake", "Temperature", "History"}

    def test_single_weak_signal_does_not_raise_a_recommendation(self):
        rec = engine.evaluate_health_risk(
            entity_type="animal", entity_id="cow-1", entity_label="Cow 1", milk_change_pct=-3
        )
        assert rec is None

    def test_milk_and_feed_drop_without_fever_is_medium_priority(self):
        rec = engine.evaluate_health_risk(
            entity_type="animal",
            entity_id="goat-1",
            entity_label="Goat 1",
            milk_change_pct=-15,
            feed_change_pct=-10,
        )
        assert rec is not None
        assert rec.priority == "medium"

    def test_missing_inputs_are_reported_as_missing_data(self):
        rec = engine.evaluate_health_risk(
            entity_type="animal",
            entity_id="goat-2",
            entity_label="Goat 2",
            milk_change_pct=-15,
            feed_change_pct=-10,
        )
        assert "temperature_c" in rec.missing_data


class TestLowFeed:
    def test_at_or_below_reorder_level_triggers_recommendation(self):
        rec = engine.evaluate_low_feed(
            item_id="i1", item_name="Dairy Mix", current_qty=1800, reorder_level=2000, unit="kg", daily_usage=150
        )
        assert rec is not None
        assert rec.category == "feed"
        assert "200 kg" in rec.suggested_action

    def test_above_reorder_level_returns_none(self):
        rec = engine.evaluate_low_feed(item_id="i1", item_name="Dairy Mix", current_qty=3250, reorder_level=2000, unit="kg")
        assert rec is None

    def test_low_days_remaining_is_high_priority(self):
        rec = engine.evaluate_low_feed(
            item_id="i1", item_name="Layer Feed", current_qty=1150, reorder_level=1500, unit="kg", daily_usage=310
        )
        assert rec is not None
        assert rec.priority == "high"  # ~3.7 days remaining < 7-day threshold


class TestEggDrop:
    def test_drop_over_threshold_triggers_recommendation(self):
        rec = engine.evaluate_egg_drop(flock_id="f1", flock_name="Duck Flock", current_total=1128, baseline_total=1446)
        assert rec is not None
        assert rec.category == "egg"
        assert "22%" in rec.title

    def test_drop_under_threshold_returns_none(self):
        rec = engine.evaluate_egg_drop(flock_id="f1", flock_name="Layer Flock", current_total=4212, baseline_total=4400)
        assert rec is None

    def test_increase_returns_none(self):
        rec = engine.evaluate_egg_drop(flock_id="f1", flock_name="Turkey Flock", current_total=502, baseline_total=487)
        assert rec is None


class TestWithdrawal:
    def test_sale_destination_triggers_block(self):
        rec = engine.evaluate_withdrawal_conflict(
            animal_id="a1", animal_label="Willow", withdrawal_until_label="May 15", destination="sold"
        )
        assert rec is not None
        assert rec.priority == "high"

    def test_non_sale_destination_is_not_blocked(self):
        rec = engine.evaluate_withdrawal_conflict(
            animal_id="a1", animal_label="Willow", withdrawal_until_label="May 15", destination="stored"
        )
        assert rec is None


class TestHarvestDue:
    def test_within_window_triggers_reminder(self):
        rec = engine.evaluate_harvest_due(field_id="f1", field_name="Field 2", crop_type="Tomatoes", hours_until_harvest=20)
        assert rec is not None
        assert rec.category == "harvest"

    def test_far_in_the_future_returns_none(self):
        rec = engine.evaluate_harvest_due(field_id="f1", field_name="Orchard", crop_type="Oranges", hours_until_harvest=700)
        assert rec is None


class TestFeedCostInsight:
    def test_high_share_triggers_insight(self):
        rec = engine.evaluate_feed_cost_insight(feed_expense=1680, total_expense=4230)
        assert rec is not None
        assert rec.category == "finance"

    def test_low_share_returns_none(self):
        rec = engine.evaluate_feed_cost_insight(feed_expense=500, total_expense=4230)
        assert rec is None
