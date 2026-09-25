from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.base import get_db
from app.domain import models
from app.schemas.users import UserProfileOut

router = APIRouter(prefix="/users", tags=["users"])


@router.get("", response_model=list[UserProfileOut])
def list_users(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[models.User]:
    """The farm's staff roster — used by the manager's Team screen and by
    the task-assignment picker. Always scoped to the caller's own farm
    (never accepts a farm_id param) so one account can never enumerate
    another farm's staff.
    """
    return list(db.scalars(select(models.User).where(models.User.farm_id == current_user.farm_id, models.User.active.is_(True)).order_by(models.User.name)))
