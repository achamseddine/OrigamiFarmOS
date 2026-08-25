from __future__ import annotations

from datetime import datetime, timezone

from pydantic import BaseModel

from app.schemas.common import ORMModel


class AnimalOut(ORMModel):
    id: str
    farm_id: str
    tag: str
    name: str
    species: str
    breed: str | None = None
    sex: str | None = None
    birth_date: datetime | None = None
    status: str
    location_label: str | None = None
    health_score: int
    pregnant: bool
    pregnancy_days: int | None = None
    lactating: bool
    lactation_cycle: int | None = None
    withdrawal_until: datetime | None = None
    withdrawal_reason: str | None = None
    weight_kg: float | None = None
    group_name: str | None = None
    photo_path: str | None = None

    @property
    def is_under_withdrawal(self) -> bool:
        if self.withdrawal_until is None:
            return False
        # `withdrawal_until` may come back tz-naive on SQLite (see
        # app/repositories/base.ensure_utc) even though every write path in
        # this app is UTC; treat a naive value as already-UTC here.
        withdrawal_until = self.withdrawal_until
        if withdrawal_until.tzinfo is None:
            withdrawal_until = withdrawal_until.replace(tzinfo=timezone.utc)
        return withdrawal_until > datetime.now(timezone.utc)


class AnimalCreate(BaseModel):
    tag: str
    name: str
    species: str
    breed: str | None = None
    sex: str | None = None
    birth_date: datetime | None = None
    location_label: str | None = None
    group_name: str | None = None


class AnimalDigitalTwinOut(AnimalOut):
    recent_observations: list[dict] = []
    recent_events: list[dict] = []
    open_recommendations: list[dict] = []
