from __future__ import annotations

from fastapi import APIRouter, Depends, status
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_diagnostic_role
from app.db.base import get_db
from app.domain import models
from app.schemas.health import TreatmentCreate, TreatmentOut
from app.services import health_case_service as cases

router = APIRouter(prefix="/health", tags=["health"])


@router.get("/treatments", response_model=list[TreatmentOut])
def list_treatments(farm_id: str, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)) -> list[models.Treatment]:
    """Treatment rows aren't farm-scoped directly (entity_type/entity_id
    is generic) so this resolves the farm's animal and flock ids first,
    matching the same generic-entity pattern used in api/v1/animals.py.
    """
    animal_ids = db.scalars(select(models.Animal.id).where(models.Animal.farm_id == farm_id)).all()
    flock_ids = db.scalars(select(models.Flock.id).where(models.Flock.farm_id == farm_id)).all()
    stmt = select(models.Treatment).where(
        or_(
            (models.Treatment.entity_type == "animal") & models.Treatment.entity_id.in_(animal_ids),
            (models.Treatment.entity_type == "flock") & models.Treatment.entity_id.in_(flock_ids),
        )
    ).order_by(models.Treatment.start_at.desc())
    return list(db.scalars(stmt))


@router.post("/treatments", status_code=status.HTTP_201_CREATED)
def record_treatment(
    payload: TreatmentCreate, db: Session = Depends(get_db), current_user: models.User = Depends(require_diagnostic_role)
) -> dict:
    """Manager/veterinarian-gated (Constitution: "Veterinarians diagnose
    and prescribe"). `require_diagnostic_role` returns HTTP 403 for
    worker/accountant/read-only accounts before this body ever runs. The
    prescription may name the stocked medicine product and the health
    case / plan it belongs to (HEALTH-VETERINARY-SCHEMA treatment_action).
    """
    treatment = cases.record_treatment(db, current_user.farm_id, user=current_user, **payload.model_dump())
    db.commit()
    return {"id": treatment.id, "entity_id": treatment.entity_id, "withdrawal_until": treatment.withdrawal_until, "health_case_id": treatment.health_case_id,
            "medicine_product_id": treatment.medicine_product_id, "treatment_plan_id": treatment.treatment_plan_id}
