"""Agriculture: fields, crop types, plantings and daily harvest
(tech spec §14–§17).

The agriculture employee's whole day lives here: define the field, record
what was planted in it, and every evening record what came out of it. The
harvest endpoint is the one that matters most — it is what turns a field
into real numbers (yield, waste, sellable stock) rather than an estimate.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_permission
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.repositories.base import diff_changes, new_id, now, snapshot, write_audit_log, write_event
from app.schemas.agriculture import (
    CropCreate,
    CropOut,
    CropPlantingCreate,
    CropPlantingOut,
    CropPlantingUpdate,
    DailyHarvestCreate,
    DailyHarvestOut,
    FieldCreate,
    FieldUpdate,
)
from app.schemas.production import FieldOut

router = APIRouter(tags=["agriculture"])

_AUDITED_FIELD_COLUMNS = [
    "name", "field_code", "area_value", "area_unit", "location_label",
    "soil_type", "irrigation_method", "status", "crop_type", "stage",
    "est_yield_kg", "notes",
]


# ---------------------------------------------------------------------------
# Fields (tech spec §15)
# ---------------------------------------------------------------------------
def _field_or_404(db: Session, field_id: str, farm_id: str) -> models.Field:
    field = db.get(models.Field, field_id)
    if field is None or field.farm_id != farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Field not found")
    return field


@router.post("/fields", response_model=FieldOut, status_code=status.HTTP_201_CREATED)
def create_field(
    payload: FieldCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.AGRICULTURE, perms.CREATE)),
) -> models.Field:
    field = models.Field(id=new_id(), farm_id=current_user.farm_id, **payload.model_dump())
    db.add(field)
    write_event(
        db, farm_id=current_user.farm_id, entity_type="field", entity_id=field.id,
        event_type="field_created", payload={"name": field.name, "area_value": field.area_value},
        created_by=current_user.id,
    )
    write_audit_log(
        db, farm_id=current_user.farm_id, user_id=current_user.id, action="field_created",
        entity_type="field", entity_id=field.id, module_code=perms.AGRICULTURE,
        summary=f"{current_user.name} created field {field.name}",
    )
    db.commit()
    db.refresh(field)
    return field


@router.patch("/fields/{field_id}", response_model=FieldOut)
def update_field(
    field_id: str,
    payload: FieldUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.AGRICULTURE, perms.EDIT)),
) -> models.Field:
    field = _field_or_404(db, field_id, current_user.farm_id)
    before = snapshot(field, _AUDITED_FIELD_COLUMNS)
    for name, value in payload.model_dump(exclude_unset=True).items():
        setattr(field, name, value)
    write_audit_log(
        db, farm_id=current_user.farm_id, user_id=current_user.id, action="field_updated",
        entity_type="field", entity_id=field.id, module_code=perms.AGRICULTURE,
        summary=f"{current_user.name} updated field {field.name}",
        changes=diff_changes(before, field, _AUDITED_FIELD_COLUMNS),
    )
    db.commit()
    db.refresh(field)
    return field


# ---------------------------------------------------------------------------
# Crop types (tech spec §16 — never hard-coded)
# ---------------------------------------------------------------------------
@router.get("/crops", response_model=list[CropOut])
def list_crops(
    include_inactive: bool = False,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> list[models.Crop]:
    stmt = select(models.Crop).where(models.Crop.farm_id == current_user.farm_id)
    if not include_inactive:
        stmt = stmt.where(models.Crop.active.is_(True))
    return list(db.scalars(stmt.order_by(models.Crop.name)))


@router.post("/crops", response_model=CropOut, status_code=status.HTTP_201_CREATED)
def create_crop(
    payload: CropCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.AGRICULTURE, perms.CREATE)),
) -> models.Crop:
    existing = db.scalars(
        select(models.Crop).where(models.Crop.farm_id == current_user.farm_id, models.Crop.name == payload.name)
    ).one_or_none()
    if existing is not None:
        # Re-activate rather than duplicate: a farm that stopped growing
        # basil and starts again should get its old crop back.
        if not existing.active:
            existing.active = True
            db.commit()
            db.refresh(existing)
            return existing
        raise HTTPException(status.HTTP_409_CONFLICT, f"'{payload.name}' is already in this farm's crop list.")

    crop = models.Crop(id=new_id(), farm_id=current_user.farm_id, **payload.model_dump())
    db.add(crop)
    write_audit_log(
        db, farm_id=current_user.farm_id, user_id=current_user.id, action="crop_created",
        entity_type="crop", entity_id=crop.id, module_code=perms.AGRICULTURE,
        summary=f"{current_user.name} added crop type {crop.name}",
    )
    db.commit()
    db.refresh(crop)
    return crop


@router.delete("/crops/{crop_id}", status_code=status.HTTP_204_NO_CONTENT)
def archive_crop(
    crop_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.AGRICULTURE, perms.DELETE)),
) -> None:
    crop = db.get(models.Crop, crop_id)
    if crop is None or crop.farm_id != current_user.farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Crop not found")
    crop.active = False  # past plantings still reference it
    write_audit_log(
        db, farm_id=current_user.farm_id, user_id=current_user.id, action="crop_archived",
        entity_type="crop", entity_id=crop.id, module_code=perms.AGRICULTURE,
        summary=f"{current_user.name} archived crop type {crop.name}",
    )
    db.commit()


# ---------------------------------------------------------------------------
# Plantings (tech spec §16)
# ---------------------------------------------------------------------------
@router.get("/crop-plantings", response_model=list[CropPlantingOut])
def list_plantings(
    field_id: str | None = None,
    active_only: bool = True,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> list[models.CropPlanting]:
    stmt = select(models.CropPlanting).where(models.CropPlanting.farm_id == current_user.farm_id)
    if field_id:
        stmt = stmt.where(models.CropPlanting.field_id == field_id)
    if active_only:
        stmt = stmt.where(models.CropPlanting.status == "active")
    return list(db.scalars(stmt.order_by(models.CropPlanting.planted_date.desc())))


@router.post("/crop-plantings", response_model=CropPlantingOut, status_code=status.HTTP_201_CREATED)
def create_planting(
    payload: CropPlantingCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.AGRICULTURE, perms.CREATE)),
) -> models.CropPlanting:
    field = _field_or_404(db, payload.field_id, current_user.farm_id)
    crop = db.get(models.Crop, payload.crop_id)
    if crop is None or crop.farm_id != current_user.farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Crop not found")

    data = payload.model_dump()
    planting = models.CropPlanting(
        id=new_id(), farm_id=current_user.farm_id, created_by=current_user.id, **data
    )
    if planting.expected_harvest_date is None and planting.planted_date and crop.default_cycle_days:
        from datetime import timedelta

        planting.expected_harvest_date = planting.planted_date + timedelta(days=crop.default_cycle_days)
    db.add(planting)

    # Keep the field's own summary columns in step, so the Produce screen's
    # field cards read correctly without joining every planting.
    field.crop_type = crop.name
    field.stage = planting.stage
    field.expected_harvest_date = planting.expected_harvest_date
    if planting.expected_yield_kg:
        field.est_yield_kg = planting.expected_yield_kg

    write_event(
        db, farm_id=current_user.farm_id, entity_type="field", entity_id=field.id,
        event_type="crop_planted", payload={"crop": crop.name, "planting_id": planting.id},
        created_by=current_user.id,
    )
    write_audit_log(
        db, farm_id=current_user.farm_id, user_id=current_user.id, action="planting_created",
        entity_type="crop_planting", entity_id=planting.id, module_code=perms.AGRICULTURE,
        summary=f"{current_user.name} planted {crop.name} in {field.name}",
    )
    db.commit()
    db.refresh(planting)
    return planting


@router.patch("/crop-plantings/{planting_id}", response_model=CropPlantingOut)
def update_planting(
    planting_id: str,
    payload: CropPlantingUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.AGRICULTURE, perms.EDIT)),
) -> models.CropPlanting:
    planting = db.get(models.CropPlanting, planting_id)
    if planting is None or planting.farm_id != current_user.farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Planting not found")
    tracked = ["variety", "planted_area", "expected_yield_kg", "stage", "status", "notes"]
    before = snapshot(planting, tracked)
    for name, value in payload.model_dump(exclude_unset=True).items():
        setattr(planting, name, value)

    field = db.get(models.Field, planting.field_id)
    if field is not None and payload.stage is not None:
        field.stage = payload.stage

    write_audit_log(
        db, farm_id=current_user.farm_id, user_id=current_user.id, action="planting_updated",
        entity_type="crop_planting", entity_id=planting.id, module_code=perms.AGRICULTURE,
        summary=f"{current_user.name} updated a planting in {field.name if field else planting.field_id}",
        changes=diff_changes(before, planting, tracked),
    )
    db.commit()
    db.refresh(planting)
    return planting


# ---------------------------------------------------------------------------
# Daily harvest (tech spec §17)
# ---------------------------------------------------------------------------
@router.post("/harvest", response_model=DailyHarvestOut, status_code=status.HTTP_201_CREATED)
def record_daily_harvest(
    payload: DailyHarvestCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.PRODUCE_HARVEST, perms.CREATE)),
) -> dict:
    """Records the day's pick and moves the sellable part into real
    inventory, so "168 kg ready for sale" on the Produce screen is stock
    that exists rather than a number someone typed.
    """
    field = _field_or_404(db, payload.field_id, current_user.farm_id)

    product_name = payload.product_name
    planting = None
    if payload.planting_id:
        planting = db.get(models.CropPlanting, payload.planting_id)
        if planting is None or planting.farm_id != current_user.farm_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Planting not found")
    if not product_name and payload.crop_id:
        crop = db.get(models.Crop, payload.crop_id)
        product_name = crop.name if crop else None
    if not product_name and planting is not None:
        crop = db.get(models.Crop, planting.crop_id)
        product_name = crop.name if crop else None
    if not product_name:
        product_name = field.crop_type
    if not product_name:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "Tell us what was harvested — pass a product_name, crop_id or planting_id.",
        )

    waste = payload.waste_quantity
    sellable = payload.sellable_quantity
    if sellable is None:
        sellable = payload.total_quantity - waste
    if sellable < 0:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Waste cannot exceed the total harvested.")
    if round(sellable + waste, 6) > round(payload.total_quantity, 6):
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"Sellable ({sellable}) plus waste ({waste}) is more than the {payload.total_quantity} harvested.",
        )

    recorded_at = payload.recorded_at or now()
    record = models.HarvestRecord(
        id=new_id(),
        field_id=field.id,
        product_name=product_name,
        quantity=payload.total_quantity,
        unit=payload.unit,
        waste_qty=waste,
        destination=payload.destination,
        recorded_at=recorded_at,
    )
    db.add(record)

    # The sellable part becomes stock. One inventory item per produce
    # product, created on first harvest so a farm never has to pre-register
    # its own crops as inventory by hand.
    item = None
    qty_after = None
    if sellable > 0:
        item = db.scalars(
            select(models.InventoryItem).where(
                models.InventoryItem.farm_id == current_user.farm_id,
                models.InventoryItem.name == product_name,
                models.InventoryItem.category == "produce",
            )
        ).one_or_none()
        if item is None:
            item = models.InventoryItem(
                id=new_id(), farm_id=current_user.farm_id, name=product_name,
                category="produce", unit=payload.unit, current_qty=0, reorder_level=0,
            )
            db.add(item)
            db.flush()
        item.current_qty += sellable
        qty_after = item.current_qty
        db.add(
            models.InventoryTransaction(
                id=new_id(), item_id=item.id, direction="in", quantity=sellable,
                reason="harvest", linked_entity_type="harvest_record", linked_entity_id=record.id,
                created_at=recorded_at,
            )
        )

    if planting is not None:
        planting.stage = "harvested"

    write_event(
        db, farm_id=current_user.farm_id, entity_type="field", entity_id=field.id,
        event_type="harvest_recorded",
        payload={"product_name": product_name, "total": payload.total_quantity, "sellable": sellable, "waste": waste},
        created_by=current_user.id,
    )
    write_audit_log(
        db, farm_id=current_user.farm_id, user_id=current_user.id, action="harvest_recorded",
        entity_type="harvest_record", entity_id=record.id, module_code=perms.PRODUCE_HARVEST,
        summary=(
            f"{current_user.name} recorded {payload.total_quantity:g} {payload.unit} of "
            f"{product_name} from {field.name}"
        ),
        metadata={"sellable": sellable, "waste": waste, "field_id": field.id},
    )
    db.commit()
    db.refresh(record)
    return {
        "id": record.id,
        "field_id": record.field_id,
        "product_name": record.product_name,
        "total_quantity": record.quantity,
        "sellable_quantity": sellable,
        "waste_quantity": waste,
        "unit": record.unit,
        "recorded_at": record.recorded_at,
        "inventory_item_id": item.id if item else None,
        "inventory_qty_after": qty_after,
    }
