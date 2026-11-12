from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.livestock.catalog import Cap
from app.services import capability_service, feed_performance_service, feeding_program_service, livestock_state_service
from app.api.deps import ensure_farm_user, owned_or_404, require_any_permission, require_farm_access
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.repositories.base import ensure_utc, new_id, now, write_event
from app.schemas.production import EggRecordCreate, EggRecordOut, FieldOut, HarvestRecordCreate, HarvestRecordOut, MilkRecordCreate, MilkRecordOut

router = APIRouter(prefix="/production", tags=["production"])

# Reads: the record's own module, plus Produce & Harvest — the tablet's
# ProductionProvider loads fields, milk, eggs and harvest in one batch for
# whoever holds it, and the milk/egg screens read from that provider.
_FIELDS_VIEW = require_farm_access(perms.AGRICULTURE, perms.PRODUCE_HARVEST)
_MILK_VIEW = require_farm_access(perms.MILK_PRODUCTION, perms.PRODUCE_HARVEST)
_EGGS_VIEW = require_farm_access(perms.EGG_PRODUCTION, perms.PRODUCE_HARVEST)
_HARVEST_VIEW = require_farm_access(perms.PRODUCE_HARVEST, perms.AGRICULTURE)
# Writes: the same modules the tablet's record sheet offers each action to.
_MILK_CREATE = require_any_permission(perms.MILK_PRODUCTION, action=perms.CREATE)
_EGGS_CREATE = require_any_permission(perms.EGG_PRODUCTION, action=perms.CREATE)
_HARVEST_CREATE = require_any_permission(perms.PRODUCE_HARVEST, perms.AGRICULTURE, action=perms.CREATE)


@router.get("/fields", response_model=list[FieldOut])
def list_fields(db: Session = Depends(get_db), user: models.User = Depends(_FIELDS_VIEW)) -> list[models.Field]:
    return list(db.scalars(select(models.Field).where(models.Field.farm_id == user.farm_id).order_by(models.Field.name)))


@router.get("/milk", response_model=list[MilkRecordOut])
def list_milk_records(days: int = 30, db: Session = Depends(get_db), user: models.User = Depends(_MILK_VIEW)) -> list[models.MilkRecord]:
    cutoff = now() - timedelta(days=days)
    stmt = (
        select(models.MilkRecord)
        .join(models.Animal, models.Animal.id == models.MilkRecord.animal_id)
        .where(models.Animal.farm_id == user.farm_id, models.MilkRecord.recorded_at >= cutoff)
        .order_by(models.MilkRecord.recorded_at.desc())
    )
    return list(db.scalars(stmt))


@router.get("/eggs", response_model=list[EggRecordOut])
def list_egg_records(days: int = 30, db: Session = Depends(get_db), user: models.User = Depends(_EGGS_VIEW)) -> list[models.EggRecord]:
    cutoff = now() - timedelta(days=days)
    stmt = (
        select(models.EggRecord)
        .join(models.Flock, models.Flock.id == models.EggRecord.flock_id)
        .where(models.Flock.farm_id == user.farm_id, models.EggRecord.recorded_at >= cutoff)
        .order_by(models.EggRecord.recorded_at.desc())
    )
    return list(db.scalars(stmt))


@router.get("/harvest", response_model=list[HarvestRecordOut])
def list_harvest_records(days: int = 90, db: Session = Depends(get_db), user: models.User = Depends(_HARVEST_VIEW)) -> list[models.HarvestRecord]:
    cutoff = now() - timedelta(days=days)
    stmt = (
        select(models.HarvestRecord)
        .join(models.Field, models.Field.id == models.HarvestRecord.field_id)
        .where(models.Field.farm_id == user.farm_id, models.HarvestRecord.recorded_at >= cutoff)
        .order_by(models.HarvestRecord.recorded_at.desc())
    )
    return list(db.scalars(stmt))


@router.post("/milk", status_code=status.HTTP_201_CREATED)
def record_milk(payload: MilkRecordCreate, db: Session = Depends(get_db), current_user: models.User = Depends(_MILK_CREATE)) -> dict:
    """Validation rule (tech spec §14): "Milk from an animal under
    withdrawal must show a hard warning or be blocked from sale
    destination." This endpoint hard-blocks it, matching RULE-WITHDRAWAL
    in the recommendation engine.
    """
    animal = owned_or_404(db, models.Animal, payload.animal_id, current_user, "Animal")
    ensure_farm_user(db, current_user, payload.recorded_by, "recorder")
    livestock_state_service.ensure_on_farm(animal, "milk")

    # Milk is a capability (generic animal model §12): a bull, a hen, a
    # meat ewe or a mare cannot have a milk record, however the form was
    # filled in.
    cap_set = capability_service.resolve_for_animal(db, animal)
    if not cap_set.has(Cap.MILK_PRODUCTION):
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            capability_service.describe_missing(cap_set, Cap.MILK_PRODUCTION, animal.name),
        )

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
    db.flush()
    # A yield that crosses a production band asks for a feeding review
    # (feed architecture §11) — a task, never an automatic ration change.
    feeding_program_service.review_after_milk(db, animal, user_id=current_user.id)
    feed_performance_service.on_production_recorded(db, "animal", animal, user_id=current_user.id)
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
def record_eggs(payload: EggRecordCreate, db: Session = Depends(get_db), current_user: models.User = Depends(_EGGS_CREATE)) -> dict:
    """Validation rule (tech spec §14): "Sellable + broken + consumed +
    hatched + wasted cannot exceed total eggs."
    """
    flock = owned_or_404(db, models.Flock, payload.flock_id, current_user, "Flock")
    cap_set = capability_service.resolve_for_group(db, flock)
    if not cap_set.has(Cap.EGG_PRODUCTION):
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            capability_service.describe_missing(cap_set, Cap.EGG_PRODUCTION, flock.name),
        )
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
    db.flush()
    feed_performance_service.on_production_recorded(db, "group", flock, user_id=current_user.id)
    db.commit()
    return {"id": record.id, "flock_id": record.flock_id, "total_eggs": record.total_eggs}


@router.post("/harvest", status_code=status.HTTP_201_CREATED)
def record_harvest(payload: HarvestRecordCreate, db: Session = Depends(get_db), current_user: models.User = Depends(_HARVEST_CREATE)) -> dict:
    field = owned_or_404(db, models.Field, payload.field_id, current_user, "Field")

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
