from __future__ import annotations

from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.api.deps import require_diagnostic_role
from app.db.base import get_db
from app.domain import models
from app.repositories.base import new_id, now, write_event
from app.schemas.health import TreatmentCreate

router = APIRouter(prefix="/health", tags=["health"])


@router.post("/treatments", status_code=status.HTTP_201_CREATED)
def record_treatment(
    payload: TreatmentCreate, db: Session = Depends(get_db), current_user: models.User = Depends(require_diagnostic_role)
) -> dict:
    """Manager/veterinarian-gated (Constitution: "Veterinarians diagnose
    and prescribe"). `require_diagnostic_role` returns HTTP 403 for
    worker/accountant/read-only accounts before this body ever runs.
    """
    treatment = models.Treatment(
        id=new_id(),
        entity_type=payload.entity_type,
        entity_id=payload.entity_id,
        diagnosis=payload.diagnosis,
        medication=payload.medication,
        dose=payload.dose,
        route=payload.route,
        start_at=payload.start_at or now(),
        end_at=payload.end_at,
        withdrawal_until=payload.withdrawal_until,
        vet_id=payload.vet_id,
        responsible_user_id=payload.responsible_user_id,
        cost=payload.cost,
        notes=payload.notes,
    )
    db.add(treatment)

    farm_id = ""
    if payload.entity_type == "animal":
        animal = db.get(models.Animal, payload.entity_id)
        if animal is not None:
            farm_id = animal.farm_id
            if payload.withdrawal_until is not None:
                animal.withdrawal_until = payload.withdrawal_until
                animal.withdrawal_reason = "Medication"
                animal.status = "under_treatment"
    elif payload.entity_type == "flock":
        flock = db.get(models.Flock, payload.entity_id)
        farm_id = flock.farm_id if flock is not None else ""

    write_event(
        db,
        farm_id=farm_id,
        entity_type=payload.entity_type,
        entity_id=payload.entity_id,
        event_type="treatment_recorded",
        payload={"medication": payload.medication, "withdrawal_until": payload.withdrawal_until.isoformat() if payload.withdrawal_until else None},
        created_by=current_user.id,
    )
    db.commit()
    return {"id": treatment.id, "entity_id": treatment.entity_id, "withdrawal_until": treatment.withdrawal_until}
