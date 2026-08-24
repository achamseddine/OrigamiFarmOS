"""Rule-based, explainable recommendation engine (tech spec §15).

CONSTITUTION.md: "AI explains. AI never replaces professional judgement.
Every recommendation requires evidence. Every recommendation has
confidence." Every function below is pure (no DB access) so it can be unit
tested directly with plain input values — see tests/test_recommendations.py.
Nothing here is a black-box model: every branch is an explicit, readable
threshold check, and every returned draft carries the evidence that
produced it.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class EvidenceItem:
    label: str
    value: str


@dataclass(frozen=True)
class RecommendationDraft:
    rule_id: str
    category: str  # health | feed | egg | withdrawal | harvest | finance
    priority: str  # high | medium | low | info
    title: str
    entity_label: str
    confidence: float
    rationale: str
    suggested_action: str
    evidence: list[EvidenceItem]
    entity_type: str | None = None
    entity_id: str | None = None
    missing_data: list[str] = field(default_factory=list)


# ---------------------------------------------------------------------------
# RULE-HEALTH-RISK
# "Milk drop + feed drop -> health observation recommendation."
# "Temperature >= 39.5C + production decline -> high-priority health
#  recommendation."
# ---------------------------------------------------------------------------
MILK_DROP_THRESHOLD_PCT = -10.0
FEED_DROP_THRESHOLD_PCT = -8.0
FEVER_THRESHOLD_C = 39.5


def evaluate_health_risk(
    *,
    entity_type: str,
    entity_id: str,
    entity_label: str,
    milk_change_pct: float | None = None,
    feed_change_pct: float | None = None,
    temperature_c: float | None = None,
    prior_condition_count: int = 0,
    prior_condition_label: str | None = None,
) -> RecommendationDraft | None:
    evidence: list[EvidenceItem] = []
    confidence = 0.35
    missing: list[str] = []

    milk_down = milk_change_pct is not None and milk_change_pct <= MILK_DROP_THRESHOLD_PCT
    if milk_down:
        evidence.append(EvidenceItem("Milk Yield", f"↓{abs(milk_change_pct):.0f}% vs recent baseline"))
        confidence += 0.18
    elif milk_change_pct is None:
        missing.append("milk_change_pct")

    feed_down = feed_change_pct is not None and feed_change_pct <= FEED_DROP_THRESHOLD_PCT
    if feed_down:
        evidence.append(EvidenceItem("Feed Intake", f"↓{abs(feed_change_pct):.0f}% vs recent baseline"))
        confidence += 0.14
    elif feed_change_pct is None:
        missing.append("feed_change_pct")

    fever = temperature_c is not None and temperature_c >= FEVER_THRESHOLD_C
    if fever:
        evidence.append(EvidenceItem("Temperature", f"{temperature_c:.1f}°C — Elevated"))
        confidence += 0.18
    elif temperature_c is None:
        missing.append("temperature_c")

    if prior_condition_count > 0:
        label = prior_condition_label or "prior condition"
        evidence.append(EvidenceItem("History", f"{label} — {prior_condition_count} prior case(s)"))
        confidence += min(0.05 * prior_condition_count, 0.15)

    # Require at least two independent signals before raising a
    # recommendation — a single loose observation should not page the vet.
    signal_count = sum([milk_down, feed_down, fever, prior_condition_count > 0])
    if signal_count < 2:
        return None

    high_priority = fever and milk_down
    priority = "high" if high_priority else "medium"
    confidence = min(confidence, 0.97)

    action = (
        f"Isolate {entity_label} and start a health protocol. Recheck in 12 hours. "
        "Notify veterinarian if fever persists."
        if high_priority
        else f"Schedule a manual check for {entity_label} today and continue close observation."
    )

    return RecommendationDraft(
        rule_id="RULE-HEALTH-RISK",
        category="health",
        priority=priority,
        title="Mastitis Risk Detected" if high_priority else "Declining Condition Detected",
        entity_label=entity_label,
        entity_type=entity_type,
        entity_id=entity_id,
        confidence=round(confidence, 2),
        rationale=(
            f"{entity_label}'s milk yield and feed intake are both trending down"
            + (f", body temperature is elevated ({temperature_c:.1f}°C)," if fever else "")
            + (f" and there {'is' if prior_condition_count == 1 else 'are'} {prior_condition_count} prior "
               f"case(s) of {prior_condition_label}." if prior_condition_count else ".")
        ),
        suggested_action=action,
        evidence=evidence,
        missing_data=missing,
    )


# ---------------------------------------------------------------------------
# RULE-LOW-FEED
# "Feed below reorder level -> reorder task."
# "Days remaining below threshold -> morning warning."
# ---------------------------------------------------------------------------
DAYS_REMAINING_WARNING_THRESHOLD = 7


def evaluate_low_feed(
    *,
    item_id: str,
    item_name: str,
    current_qty: float,
    reorder_level: float,
    unit: str,
    daily_usage: float | None = None,
) -> RecommendationDraft | None:
    if current_qty > reorder_level:
        return None

    evidence = [
        EvidenceItem("Current stock", f"{current_qty:.0f} {unit}"),
        EvidenceItem("Reorder level", f"{reorder_level:.0f} {unit}"),
    ]
    missing: list[str] = []
    days_remaining: float | None = None
    if daily_usage and daily_usage > 0:
        days_remaining = current_qty / daily_usage
        evidence.append(EvidenceItem("Days remaining", f"~{days_remaining:.0f} days"))
    else:
        missing.append("daily_usage")

    priority = "high" if days_remaining is not None and days_remaining < DAYS_REMAINING_WARNING_THRESHOLD else "medium"
    shortfall = max(reorder_level - current_qty, 0)

    return RecommendationDraft(
        rule_id="RULE-LOW-FEED",
        category="feed",
        priority=priority,
        title=f"Low feed: {item_name}",
        entity_label=item_name,
        entity_type="inventory_item",
        entity_id=item_id,
        confidence=0.95,
        rationale=(
            f"{item_name} stock ({current_qty:.0f} {unit}) is at or below its reorder level "
            f"({reorder_level:.0f} {unit})."
            + (f" At the current usage rate this covers roughly {days_remaining:.0f} more day(s)." if days_remaining else "")
        ),
        suggested_action=f"Place a reorder for at least {shortfall:.0f} {unit} of {item_name} this week.",
        evidence=evidence,
        missing_data=missing,
    )


# ---------------------------------------------------------------------------
# RULE-EGG-DROP
# "Egg production down >20% -> investigate feed/water/health."
# ---------------------------------------------------------------------------
EGG_DROP_THRESHOLD_PCT = -20.0


def evaluate_egg_drop(*, flock_id: str, flock_name: str, current_total: int, baseline_total: int) -> RecommendationDraft | None:
    if baseline_total <= 0:
        return None
    change_pct = (current_total - baseline_total) / baseline_total * 100
    if change_pct > EGG_DROP_THRESHOLD_PCT:
        return None

    return RecommendationDraft(
        rule_id="RULE-EGG-DROP",
        category="egg",
        priority="medium",
        title=f"{flock_name} production down {abs(change_pct):.0f}%",
        entity_label=flock_name,
        entity_type="flock",
        entity_id=flock_id,
        confidence=0.74,
        rationale=(
            f"{flock_name} egg output is down {abs(change_pct):.0f}% vs. last week's baseline "
            f"({current_total} vs {baseline_total}), which exceeds the "
            f"{abs(EGG_DROP_THRESHOLD_PCT):.0f}% investigation threshold."
        ),
        suggested_action="Investigate feed intake, water access/temperature, and recent health observations for this flock.",
        evidence=[
            EvidenceItem("Production", f"{current_total} vs {baseline_total} last week"),
            EvidenceItem("Threshold", f">{abs(EGG_DROP_THRESHOLD_PCT):.0f}% drop triggers review"),
        ],
    )


# ---------------------------------------------------------------------------
# RULE-WITHDRAWAL
# "Active treatment withdrawal + sale destination -> block or hard-warn sale."
# ---------------------------------------------------------------------------
def evaluate_withdrawal_conflict(
    *, animal_id: str, animal_label: str, withdrawal_until_label: str, destination: str
) -> RecommendationDraft | None:
    if destination != "sold":
        return None
    return RecommendationDraft(
        rule_id="RULE-WITHDRAWAL",
        category="withdrawal",
        priority="high",
        title=f"{animal_label} is under an active withdrawal period",
        entity_label=animal_label,
        entity_type="animal",
        entity_id=animal_id,
        confidence=0.99,
        rationale=f"{animal_label} is under medication withdrawal until {withdrawal_until_label}. Product from this animal is not safe for sale.",
        suggested_action="Block this sale and route the product to internal use/disposal until the withdrawal period ends.",
        evidence=[EvidenceItem("Withdrawal until", withdrawal_until_label), EvidenceItem("Requested destination", destination)],
    )


# ---------------------------------------------------------------------------
# RULE-HARVEST-DUE
# "Harvest date within 48 hours -> harvest reminder."
# ---------------------------------------------------------------------------
HARVEST_REMINDER_WINDOW_HOURS = 48


def evaluate_harvest_due(*, field_id: str, field_name: str, crop_type: str, hours_until_harvest: float, est_yield_kg: float | None = None) -> RecommendationDraft | None:
    if hours_until_harvest > HARVEST_REMINDER_WINDOW_HOURS or hours_until_harvest < -24:
        return None

    yield_note = f" (~{est_yield_kg:.0f} kg expected)" if est_yield_kg else ""
    return RecommendationDraft(
        rule_id="RULE-HARVEST-DUE",
        category="harvest",
        priority="low",
        title=f"{crop_type} ready in {max(round(hours_until_harvest / 24), 0)} day(s)",
        entity_label=field_name,
        entity_type="field",
        entity_id=field_id,
        confidence=0.9,
        rationale=f"{field_name} ({crop_type}) is expected to be ready for harvest within the next {HARVEST_REMINDER_WINDOW_HOURS} hours{yield_note}.",
        suggested_action=f"Schedule the harvest crew for {field_name}.",
        evidence=[EvidenceItem("Expected harvest", "Within 48 hours")],
    )


# ---------------------------------------------------------------------------
# RULE-FEED-COST-INSIGHT
# "Feed expense unusually high -> business insight."
# ---------------------------------------------------------------------------
FEED_COST_SHARE_THRESHOLD_PCT = 35.0


def evaluate_feed_cost_insight(*, feed_expense: float, total_expense: float) -> RecommendationDraft | None:
    if total_expense <= 0:
        return None
    share_pct = feed_expense / total_expense * 100
    if share_pct < FEED_COST_SHARE_THRESHOLD_PCT:
        return None

    return RecommendationDraft(
        rule_id="RULE-FEED-COST-INSIGHT",
        category="finance",
        priority="info",
        title="Feed cost share is high",
        entity_label="Feed expenses",
        confidence=0.8,
        rationale=(
            f"Feed represents {share_pct:.1f}% of total expenses today, above the "
            f"{FEED_COST_SHARE_THRESHOLD_PCT:.0f}% attention threshold used for supplier/usage review."
        ),
        suggested_action="Review feed usage per group and compare current supplier pricing.",
        evidence=[EvidenceItem("Feed share of expenses", f"{share_pct:.1f}%")],
    )
