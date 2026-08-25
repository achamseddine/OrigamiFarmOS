from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.base import get_db
from app.domain import models
from app.repositories.base import ensure_utc, new_id, now, write_event
from app.schemas.production import EggRecordCreate, HarvestRecordCreate, MilkRecordCreate

router = APIRouter(prefix="/production", tags=["production"])


@router.post("/milk", status_code=status.HTTP_201_CREATED)
def record_milk(payload: MilkRecordCreate, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> dict:
    """Validation rule (tech spec §14): "Milk from an animal under
    withdrawal must show a hard warning or be blocked from sale
    destination." This endpoint hard-blocks it, matching RULE-WITHDRAWAL
    in the recommendation engine.
    """
    animal = db.get(models.Animal, payload.animal_id)
    if animal is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Animal not found")

    under_withdrawal = animal.withdrawal_until is not None and ensure_utc(animal.withdrawal_until) > datetime.now(timezone.utc)
    if under_withdrawal and payload.destination == "sold":
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"{animal.name} is under withdrawal until {animal.withdrawal_until.isoformat()}. "
            "Milk from this animal cannot be sold.",
        )

    record = models.MilkRecord(
        id=new_id(),
        animal_id=payload.animal_id,
        session=payload.session,
        liters=payload.liters,
        quality_status=payload.quality_status,
        destination=payload.destination,
        recorded_at=payload.recorded_at or now(),
        recorded_by=payload.recorded_by or current_user.id,
    )
    db.add(record)
    write_event(
        db,
        farm_id=animal.farm_id,
        entity_type="animal",
        entity_id=animal.id,
        event_type="milk_recorded",
        payload={"session": payload.session, "liters": payload.liters, "destination": payload.destination},
        created_by=current_user.id,
    )
    db.commit()
    return {"id": record.id, "animal_id": record.animal_id, "liters": record.liters, "under_withdrawal_warning": under_withdrawal}


@router.post("/eggs", status_code=status.HTTP_201_CREATED)
def record_eggs(payload: EggRecordCreate, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> dict:
    """Validation rule (tech spec §14): "Sellable + broken + consumed +
    hatched + wasted cannot exceed total eggs."
    """
    flock = db.get(models.Flock, payload.flock_id)
    if flock is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Flock not found")
    if not payload.is_allocation_valid():
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"Allocation ({payload.allocation_total()}) exceeds total eggs ({payload.total_eggs}).",
        )

    record = models.EggRecord(
        id=new_id(),
        flock_id=payload.flock_id,
        total_eggs=payload.total_eggs,
        sellable_eggs=payload.sellable_eggs,
        broken_eggs=payload.broken_eggs,
        consumed=payload.consumed,
        hatched=payload.hatched,
        wasted=payload.wasted,
        recorded_at=payload.recorded_at or now(),
    )
    db.add(record)
    write_event(
        db,
        farm_id=flock.farm_id,
        entity_type="flock",
        entity_id=flock.id,
        event_type="eggs_recorded",
        payload={"total_eggs": payload.total_eggs, "sellable_eggs": payload.sellable_eggs},
        created_by=current_user.id,
    )
    db.commit()
    return {"id": record.id, "flock_id": record.flock_id, "total_eggs": record.total_eggs}


@router.post("/harvest", status_code=status.HTTP_201_CREATED)
def record_harvest(payload: HarvestRecordCreate, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> dict:
    field = db.get(models.Field, payload.field_id)
    if field is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Field not found")

    record = models.HarvestRecord(
        id=new_id(),
        field_id=payload.field_id,
        product_name=payload.product_name,
        quantity=payload.quantity,
        unit=payload.unit,
        waste_qty=payload.waste_qty,
        destination=payload.destination,
        recorded_at=payload.recorded_at or now(),
    )
    db.add(record)
    write_event(
        db,
        farm_id=field.farm_id,
        entity_type="field",
        entity_id=field.id,
        event_type="harvest_recorded",
        payload={"product_name": payload.product_name, "quantity": payload.quantity},
        created_by=current_user.id,
    )
    db.commit()
    return {"id": record.id, "field_id": record.field_id, "quantity": record.quantity}
