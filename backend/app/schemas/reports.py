from __future__ import annotations

from pydantic import BaseModel


class DailySummaryOut(BaseModel):
    date: str
    revenue_today: float
    expenses_today: float
    gross_margin: float
    cash_collected: float
    pending_payments: float
    sales_breakdown: list[dict]
    expense_breakdown: list[dict]
    top_selling_products: list[dict]
    business_insights: list[str]


class MorningBriefingOut(BaseModel):
    date: str
    farm_name: str
    manager_name: str
    kpis: dict
    priorities: list[dict]
    tasks: list[dict]
