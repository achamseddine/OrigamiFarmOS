from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import models


def _today_start() -> datetime:
    return datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)


def build_daily_summary(db: Session, farm_id: str) -> dict:
    """Backs GET /reports/daily-summary — tech spec projections table
    ("Finance summary: Sales, expenses, payments, categories — after
    sale/expense events").
    """
    start = _today_start()
    sales = db.scalars(select(models.Sale).where(models.Sale.farm_id == farm_id, models.Sale.sold_at >= start)).all()
    expenses = db.scalars(select(models.Expense).where(models.Expense.farm_id == farm_id, models.Expense.incurred_at >= start)).all()

    revenue = sum(s.amount for s in sales)
    expense_total = sum(e.amount for e in expenses)
    cash_collected = sum(s.amount for s in sales if s.payment_status == "paid")
    pending = revenue - cash_collected

    sales_by_type: dict[str, float] = defaultdict(float)
    for s in sales:
        sales_by_type[s.product_type] += s.amount

    expenses_by_category: dict[str, float] = defaultdict(float)
    for e in expenses:
        expenses_by_category[e.category] += e.amount

    products_by_label: dict[str, float] = defaultdict(float)
    for s in sales:
        if s.product_label:
            products_by_label[s.product_label] += s.amount

    insights: list[str] = []
    if expense_total > 0:
        feed_share = expenses_by_category.get("feed", 0) / expense_total * 100
        if feed_share >= 30:
            insights.append(
                f"Feed remains the highest-share cost category at {feed_share:.1f}% of total expenses. "
                "Consider reviewing feed usage or suppliers."
            )
    if revenue > 0:
        collection_rate = cash_collected / revenue * 100
        insights.append(f"Cash collection rate is {collection_rate:.0f}% today. "
                         + ("Focus on collecting pending payments to improve cash flow." if collection_rate < 90 else "Strong collection performance."))

    return {
        "date": start.date().isoformat(),
        "revenue_today": round(revenue, 2),
        "expenses_today": round(expense_total, 2),
        "gross_margin": round(revenue - expense_total, 2),
        "cash_collected": round(cash_collected, 2),
        "pending_payments": round(pending, 2),
        "sales_breakdown": [{"product_type": k, "amount": round(v, 2)} for k, v in sorted(sales_by_type.items(), key=lambda kv: -kv[1])],
        "expense_breakdown": [{"category": k, "amount": round(v, 2)} for k, v in sorted(expenses_by_category.items(), key=lambda kv: -kv[1])],
        "top_selling_products": [
            {"product_label": k, "amount": round(v, 2)} for k, v in sorted(products_by_label.items(), key=lambda kv: -kv[1])[:5]
        ],
        "business_insights": insights,
    }


def build_morning_briefing(db: Session, farm_id: str) -> dict:
    """Backs GET /morning-briefing (tech spec projections table)."""
    farm = db.get(models.Farm, farm_id)
    start = _today_start()

    animal_count = len(db.scalars(select(models.Animal).where(models.Animal.farm_id == farm_id, models.Animal.active.is_(True))).all())

    milk_today = sum(
        r.liters
        for r in db.scalars(
            select(models.MilkRecord).join(models.Animal).where(models.Animal.farm_id == farm_id, models.MilkRecord.recorded_at >= start)
        ).all()
    )
    eggs_today = sum(
        r.total_eggs
        for r in db.scalars(
            select(models.EggRecord).join(models.Flock).where(models.Flock.farm_id == farm_id, models.EggRecord.recorded_at >= start)
        ).all()
    )
    active_fields = len(db.scalars(select(models.Field).where(models.Field.farm_id == farm_id)).all())
    open_alerts = len(
        db.scalars(
            select(models.Recommendation).where(
                models.Recommendation.farm_id == farm_id,
                models.Recommendation.status == "generated",
                models.Recommendation.priority.in_(["high", "medium"]),
            )
        ).all()
    )
    tasks_due = db.scalars(
        select(models.Task).where(models.Task.farm_id == farm_id, models.Task.status != "done").order_by(models.Task.due_at)
    ).all()

    priorities = db.scalars(
        select(models.Recommendation)
        .where(models.Recommendation.farm_id == farm_id, models.Recommendation.status == "generated")
        .order_by(models.Recommendation.priority, models.Recommendation.generated_at.desc())
        .limit(6)
    ).all()

    return {
        "date": start.date().isoformat(),
        "farm_name": farm.name if farm else "",
        "manager_name": "Rami",
        "kpis": {
            "animals": animal_count,
            "milk_today_l": round(milk_today, 1),
            "eggs_today": eggs_today,
            "active_fields": active_fields,
            "open_alerts": open_alerts,
            "tasks_due": len(tasks_due),
        },
        "priorities": [
            {"id": r.id, "category": r.category, "priority": r.priority, "title": r.title, "entity_label": r.entity_label}
            for r in priorities
        ],
        "tasks": [{"id": t.id, "title": t.title, "due_at": t.due_at.isoformat() if t.due_at else None, "priority": t.priority} for t in tasks_due],
    }
