from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel

from app.schemas.common import ORMModel, Evidence


class RecommendationOut(ORMModel):
    id: str
    farm_id: str
    category: str
    priority: str
    title: str
    entity_type: str | None = None
    entity_id: str | None = None
    entity_label: str | None = None
    confidence: float
    rationale: str
    suggested_action: str
    status: str
    rule_id: str | None = None
    generated_at: datetime
    evidence: list[Evidence] = []


class RecommendationDecision(BaseModel):
    decision: str  # accepted | rejected | postponed
    decided_by: str
    note: str | None = None
