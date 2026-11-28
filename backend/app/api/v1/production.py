from __future__ import annotations

from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.livestock.catalog import Cap
from app.services import approval_service, capability_service, feed_performance_service, feeding_program_service, livestock_state_service, milk_service
from app.services import milk_handover_service as handover
from app.services import milk_safety_service as milk_safety
from app.services import milk_sales_service as milk_sales
from app.api.deps import ensure_farm_user, owned_or_404, require_any_permission, require_farm_access, user_can
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.core import duplicates, offline
from app.core.record_time import not_in_future
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event
from app.schemas.approvals import MilkCorrectionIn
from app.schemas.production import (EggRecordCreate, EggRecordOut, FieldOut, HarvestRecordCreate, HarvestRecordOut, HeldMilkOut, MilkRecordCreate,
                                    MilkRecordOut, MilkReviewIn, MilkSaleCancel, MilkSaleCreate, MilkTankAdjust, MilkHandoverCreate, MilkRoutineUpdate)

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
# Correcting milk already on record is the manager's (approve); an employee
# sends the correction as an approval request (POST /approval-requests).
_MILK_APPROVE = require_any_permission(perms.MILK_PRODUCTION, action=perms.APPROVE)
_EGGS_CREATE = require_any_permission(perms.EGG_PRODUCTION, action=perms.CREATE)
_HARVEST_CREATE = require_any_permission(perms.PRODUCE_HARVEST, perms.AGRICULTURE, action=perms.CREATE)
# Milk safety (v0.8.5): read by whoever sees milk or animal health; the
# release of held milk is checked against the reviewer's role in the service.
_MILK_SAFETY_READ = require_any_permission(perms.MILK_PRODUCTION, perms.PRODUCE_HARVEST, perms.ANIMAL_HEALTH, action=perms.VIEW)


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
def record_milk(payload: MilkRecordCreate, request: Request, db: Session = Depends(get_db),
                current_user: models.User = Depends(_MILK_CREATE)) -> dict:
    """Validation rule (tech spec §14): "Milk from an animal under
    withdrawal must show a hard warning or be blocked from sale
    destination." This endpoint hard-blocks it, matching RULE-WITHDRAWAL
    in the recommendation engine.

    A milking a tablet entered offline (`X-Offline-Recorded-At`, ADR-008)
    that a recorded withdrawal covers is kept as entered and held — out of
    the tank, the collector's handover and every sale, never released — and
    the manager and the veterinarian are told: the person never saw the
    refusal, and the milk may already be in the tank.
    """
    animal = owned_or_404(db, models.Animal, payload.animal_id, current_user, "Animal")
    ensure_farm_user(db, current_user, payload.recorded_by, "recorder")
    livestock_state_service.ensure_on_farm(animal, "milk")
    recorded_at = not_in_future(payload.recorded_at, "Milk")
    # On the farm, able to give milk, within a lactation that covers the
    # milking, and withheld if a recorded withdrawal covers it — judged at
    # the milking's own time, so a late entry or an offline replay gets the
    # same answer as at the parlour (milk_service — the same checks a
    # correction passes; v0.8.5).
    entered_offline = offline.recorded_offline_at(request)
    check = milk_service.check_milk(db, animal, recorded_at, payload.destination, recorded_offline_at=entered_offline)

    # The same cow, the same session, the same farm day: two people (or one
    # person twice) recording one milking. A second milking is confirmed.
    at = recorded_at or now()
    day_start, day_end = duplicates.farm_day(db, animal.farm_id, at)
    earlier = db.scalar(select(models.MilkRecord).where(
        models.MilkRecord.animal_id == animal.id, models.MilkRecord.session == payload.session,
        models.MilkRecord.recorded_at >= day_start, models.MilkRecord.recorded_at < day_end,
    ).order_by(models.MilkRecord.recorded_at))
    match = duplicates.guard(
        earlier,
        f"{animal.name}'s {payload.session} milk is already recorded for this day ({earlier.liters:g} L)." if earlier else "",
        confirm=payload.confirm_duplicate,
    )

    record = models.MilkRecord(
        id=new_id(),
        animal_id=payload.animal_id,
        session=payload.session,
        liters=payload.liters,
        quality_status=payload.quality_status,
        destination=payload.destination,
        recorded_at=at,
        recorded_by=payload.recorded_by or current_user.id,
    )
    milk_service.apply_check(record, check, animal)
    db.add(record)
    db.flush()
    duplicates.log_confirmed(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, match_id=match.id if match else None,
                             what=f"milk:{record.id}", user_id=current_user.id)
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
        payload={"session": payload.session, "liters": payload.liters, "destination": payload.destination,
                 "withdrawal_check": record.withdrawal_check, "release_status": record.release_status,
                 "recorded_offline_at": entered_offline.isoformat() if entered_offline else None},
        created_by=current_user.id,
    )
    if check.held_offline_under_withdrawal:
        # Out of the tank on the books; perhaps in it in fact. Said loudly.
        write_event(db, farm_id=animal.farm_id, entity_type="animal", entity_id=animal.id, event_type="milk_held_for_review",
                    payload={"milk_record_ids": [record.id], "liters": record.liters, "source": "an entry made offline during a withdrawal",
                             "recorded_offline_at": entered_offline.isoformat()}, created_by=current_user.id)
        write_audit_log(db, farm_id=animal.farm_id, user_id=current_user.id, action="milk_held_offline_under_withdrawal", entity_type="milk_record",
                        entity_id=record.id, module_code=perms.MILK_PRODUCTION,
                        summary=f"{record.liters:g} L of {animal.name}'s milk entered offline as {record.destination} during a withdrawal: held"[:500],
                        metadata={"recorded_offline_at": entered_offline.isoformat(), "destination": record.destination})
        title = f"{record.liters:g} L of {animal.name}'s milk under withdrawal entered offline as {record.destination}"
        milk_safety._notify_reviewers(db, animal, title, record.safety_note or "", key=f"held:{record.id}")
        milk_safety.notify_recorder(db, animal, current_user, title, record.safety_note or "", key=f"held:{record.id}")
    elif record.release_status == milk_safety.HELD:
        milk_safety._notify_reviewers(db, animal, f"{record.liters:g} L of {animal.name}'s milk held for review", record.safety_note or "",
                                      key=f"held:{record.id}")
    db.commit()
    return {"id": record.id, "animal_id": record.animal_id, "liters": record.liters, "under_withdrawal_warning": check.under_withdrawal,
            "withdrawal_check": record.withdrawal_check, "release_status": record.release_status, "safety_note": record.safety_note,
            "lactation_episode_id": record.lactation_episode_id}


@router.post("/milk/{record_id}/correct", response_model=MilkRecordOut)
def correct_milk_record(record_id: str, payload: MilkCorrectionIn, db: Session = Depends(get_db), current_user: models.User = Depends(_MILK_APPROVE)):
    """A milk record entered wrongly — the amount, the session, the day,
    the destination or the animal. Corrected in place with the before and
    after in the audit log; every total reads the corrected value. Needs
    Milk Production approval; an employee asks through an approval request."""
    record, _ = milk_service.get_record(db, record_id, current_user.farm_id)
    approval_service.ensure_none_pending(db, current_user.farm_id, record.id)
    milk_service.apply_correction(db, record, payload.model_dump(exclude={"reason"}, exclude_none=True), reason=payload.reason, user=current_user)
    db.commit()
    return record


@router.get("/milk-held", response_model=list[HeldMilkOut])
def list_held_milk(db: Session = Depends(get_db), user: models.User = Depends(_MILK_SAFETY_READ)) -> list[dict]:
    """Milk kept but not saleable until a veterinarian or the farm manager
    reviews it (v0.8.5): its withdrawal at the milking time cannot be
    confirmed from the records, or a withdrawal was recorded after it."""
    return [{**MilkRecordOut.model_validate(r).model_dump(), "animal_name": a.name} for r, a in milk_service.held_records(db, user.farm_id)]


@router.post("/milk/{record_id}/review", response_model=MilkRecordOut)
def review_held_milk(record_id: str, payload: MilkReviewIn, db: Session = Depends(get_db), user: models.User = Depends(_MILK_SAFETY_READ)):
    """Release held milk (it may be sold) or withhold it, saying why — a
    veterinarian or the farm manager. Milk a recorded withdrawal covers is
    never released here (409)."""
    record, _ = milk_service.get_record(db, record_id, user.farm_id)
    milk_service.review(db, record, decision=payload.decision, note=payload.note, user=user)
    db.commit()
    return record


@router.get("/milk-safety")
def milk_safety_at(animal_id: str, at: datetime | None = None, db: Session = Depends(get_db), user: models.User = Depends(_MILK_SAFETY_READ)) -> dict:
    """What the server would say about a milking of [animal_id] at [at]
    (now by default): its withdrawal status from the dated history, and the
    lactation it would belong to — so a form can choose *withheld* before
    saving. The save itself checks again."""
    animal = owned_or_404(db, models.Animal, animal_id, user, "Animal")
    when = ensure_utc(at) if at else now()
    out = milk_safety.assess(db, animal, when).to_dict(animal.name)
    lac = milk_safety.lactation_at(db, animal, when)
    out.update({"animal_id": animal.id, "lactation_episode_id": lac.episode.id if lac.episode else None, "lactation_problem": lac.problem})
    return out


@router.get("/milk-safety/review")
def milk_safety_legacy_review(days: int = 365, db: Session = Depends(get_db), user: models.User = Depends(_MILK_SAFETY_READ)) -> dict:
    """Milk recorded before v0.8.5 that the dated veterinary history now says
    was under withdrawal (or cannot confirm). Read only — nothing is
    changed; docs/runbooks/MILK-SAFETY-REVIEW.md says what to do."""
    return milk_service.legacy_review(db, user.farm_id, days=days)


# ------------------------------------------------------------ selling milk
# Selling is a commercial act: Sales or Finance *create*, or the milk
# module's approval (the farm manager). Cancelling a sale and adjusting the
# tank change the record: *approve*. Reading: whoever sees milk or sales.
_MILK_SALES_VIEW = require_any_permission(perms.MILK_PRODUCTION, perms.SALES, perms.FINANCE, action=perms.VIEW)
_MILK_SALES_APPROVE = require_any_permission(perms.MILK_PRODUCTION, perms.SALES, perms.FINANCE, action=perms.APPROVE)


def _sell_dep(db: Session = Depends(get_db), user: models.User = Depends(require_any_permission(perms.MILK_PRODUCTION, perms.SALES, perms.FINANCE))):
    if not (user_can(db, user, perms.SALES, perms.CREATE) or user_can(db, user, perms.FINANCE, perms.CREATE)
            or user_can(db, user, perms.MILK_PRODUCTION, perms.APPROVE)):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Selling milk needs Sales or Finance, or Milk production approval — ask the farm manager.")
    return user


@router.get("/milk-tank")
def milk_tank(db: Session = Depends(get_db), user: models.User = Depends(_MILK_SALES_VIEW)) -> dict:
    """Milk in the tank: stored milk recorded − sold + adjustments. Worked
    out from the records every time, never stored."""
    return milk_sales.tank(db, user.farm_id)


@router.get("/milk-sales")
def list_milk_sales(days: int = 90, db: Session = Depends(get_db), user: models.User = Depends(_MILK_SALES_VIEW)) -> list[dict]:
    from app.domain import milk_models as mm

    cutoff = now() - timedelta(days=days)
    rows = db.scalars(select(mm.MilkSale).where(mm.MilkSale.farm_id == user.farm_id, mm.MilkSale.sold_at >= cutoff).order_by(mm.MilkSale.sold_at.desc()))
    return [milk_sales.sale_dict(r) for r in rows]


@router.post("/milk-sales", status_code=status.HTTP_201_CREATED)
def sell_milk(payload: MilkSaleCreate, db: Session = Depends(get_db), user: models.User = Depends(_sell_dep)) -> dict:
    """Milk sold from the tank: litres, price per litre, buyer, paid or to be
    paid. Writes the farm's revenue record (product "milk") as well."""
    sale = milk_sales.sell(db, user, liters=payload.liters, price_per_liter=payload.price_per_liter, sold_at=payload.sold_at,
                           customer_id=payload.customer_id, buyer_name=payload.buyer_name, payment_status=payload.payment_status,
                           reference=payload.reference, notes=payload.notes, allow_negative=payload.allow_negative,
                           can_override=user_can(db, user, perms.MILK_PRODUCTION, perms.APPROVE), confirm_duplicate=payload.confirm_duplicate)
    db.commit()
    return milk_sales.sale_dict(sale)


@router.post("/milk-sales/{sale_id}/paid")
def milk_sale_paid(sale_id: str, db: Session = Depends(get_db), user: models.User = Depends(_sell_dep)) -> dict:
    sale = milk_sales.mark_paid(db, milk_sales.get_sale(db, sale_id, user.farm_id), user)
    db.commit()
    return milk_sales.sale_dict(sale)


@router.post("/milk-sales/{sale_id}/cancel")
def cancel_milk_sale(sale_id: str, payload: MilkSaleCancel, db: Session = Depends(get_db), user: models.User = Depends(_MILK_SALES_APPROVE)) -> dict:
    """A sale recorded by mistake: kept, marked cancelled with the reason;
    the revenue is reversed and the milk is back in the tank."""
    sale = milk_sales.cancel(db, milk_sales.get_sale(db, sale_id, user.farm_id), user, reason=payload.reason)
    db.commit()
    return milk_sales.sale_dict(sale)


# ------------------------------------------- the milking routine (v0.8.1)
def _routine_dep(db: Session = Depends(get_db), user: models.User = Depends(require_any_permission(perms.MILK_PRODUCTION, perms.SALES, perms.FINANCE))):
    if not (user_can(db, user, perms.MILK_PRODUCTION, perms.APPROVE) or user_can(db, user, perms.FINANCE, perms.APPROVE)
            or user_can(db, user, perms.SETTINGS, perms.CONFIGURE)):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "The milk collector and his price are set by the farm manager.")
    return user


@router.get("/milk-handovers")
def list_milk_handovers(days: int = 14, db: Session = Depends(get_db), user: models.User = Depends(_MILK_SALES_VIEW)) -> dict:
    """Each milking of the last [days] days: milk stored, to the calves, to
    the collector, left; with the farm's collector, price and milking names."""
    return handover.handovers(db, user.farm_id, days=days)


@router.post("/milk-handovers", status_code=status.HTTP_201_CREATED)
def hand_over_milk(payload: MilkHandoverCreate, db: Session = Depends(get_db),
                   user: models.User = Depends(_MILK_CREATE)) -> dict:
    """After a milking: litres to the calves and litres the collector took —
    sold to him at the agreed price, to be paid with the week."""
    out = handover.hand_over(db, user, day=payload.day, session=payload.session, calves_l=payload.calves_l, collected_l=payload.collected_l,
                             notes=payload.notes, allow_negative=payload.allow_negative,
                             can_override=user_can(db, user, perms.MILK_PRODUCTION, perms.APPROVE), confirm_duplicate=payload.confirm_duplicate)
    db.commit()
    return out


@router.get("/milk-routine")
def milk_routine(db: Session = Depends(get_db), user: models.User = Depends(_MILK_SALES_VIEW)) -> dict:
    return handover.settings(db, user.farm_id)


@router.put("/milk-routine")
def set_milk_routine(payload: MilkRoutineUpdate, db: Session = Depends(get_db), user: models.User = Depends(_routine_dep)) -> dict:
    """The collector, his price per litre (USD or LBP) and what the second milking is called."""
    out = handover.set_settings(db, user, collector_name=payload.collector_name, collector_price=payload.collector_price,
                                collector_currency=payload.collector_currency, second_milking=payload.second_milking)
    db.commit()
    return out


@router.get("/milk-tank/adjustments")
def list_tank_adjustments(days: int = 90, db: Session = Depends(get_db), user: models.User = Depends(_MILK_SALES_VIEW)) -> list[dict]:
    from app.domain import milk_models as mm

    cutoff = now() - timedelta(days=days)
    rows = db.scalars(select(mm.MilkTankAdjustment).where(mm.MilkTankAdjustment.farm_id == user.farm_id, mm.MilkTankAdjustment.occurred_at >= cutoff)
                      .order_by(mm.MilkTankAdjustment.occurred_at.desc()))
    return [milk_sales.adjustment_dict(r) for r in rows]


@router.post("/milk-tank/adjustments", status_code=status.HTTP_201_CREATED)
def adjust_milk_tank(payload: MilkTankAdjust, db: Session = Depends(get_db), user: models.User = Depends(_MILK_APPROVE)) -> dict:
    """Milk that left the tank outside a sale, or a count of the tank —
    the farm manager's (Milk production approval)."""
    row = milk_sales.adjust_tank(db, user, reason=payload.reason, liters=payload.liters, counted_level=payload.counted_level,
                                 occurred_at=payload.occurred_at, notes=payload.notes)
    db.commit()
    return milk_sales.adjustment_dict(row)


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

    at = not_in_future(payload.recorded_at, "An egg collection") or now()
    lo, hi = duplicates.near(at)
    earlier = db.scalar(select(models.EggRecord).where(
        models.EggRecord.flock_id == flock.id, models.EggRecord.total_eggs == payload.total_eggs,
        models.EggRecord.recorded_at >= lo, models.EggRecord.recorded_at <= hi,
    ))
    match = duplicates.guard(earlier, f"{payload.total_eggs} eggs from {flock.name} were already recorded within half an hour.",
                             confirm=payload.confirm_duplicate)

    record = models.EggRecord(
        id=new_id(),
        flock_id=payload.flock_id,
        total_eggs=payload.total_eggs,
        sellable_eggs=payload.sellable_eggs,
        broken_eggs=payload.broken_eggs,
        consumed=payload.consumed,
        hatched=payload.hatched,
        wasted=payload.wasted,
        recorded_at=at,
    )
    db.add(record)
    duplicates.log_confirmed(db, farm_id=flock.farm_id, entity_type="flock", entity_id=flock.id, match_id=match.id if match else None,
                             what=f"eggs:{record.id}", user_id=current_user.id)
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
    if payload.waste_qty > payload.quantity:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY,
                            f"Waste ({payload.waste_qty:g}) cannot be more than the quantity harvested ({payload.quantity:g}).")
    at = not_in_future(payload.recorded_at, "A harvest") or now()
    lo, hi = duplicates.near(at)
    earlier = db.scalar(select(models.HarvestRecord).where(
        models.HarvestRecord.field_id == field.id, models.HarvestRecord.product_name == payload.product_name,
        models.HarvestRecord.quantity == payload.quantity, models.HarvestRecord.recorded_at >= lo, models.HarvestRecord.recorded_at <= hi,
    ))
    match = duplicates.guard(earlier, f"{payload.quantity:g} {payload.unit} of {payload.product_name} from {field.name} was already recorded within half an hour.",
                             confirm=payload.confirm_duplicate)

    record = models.HarvestRecord(
        id=new_id(),
        field_id=payload.field_id,
        product_name=payload.product_name,
        quantity=payload.quantity,
        unit=payload.unit,
        waste_qty=payload.waste_qty,
        destination=payload.destination,
        recorded_at=at,
    )
    db.add(record)
    duplicates.log_confirmed(db, farm_id=field.farm_id, entity_type="field", entity_id=field.id, match_id=match.id if match else None,
                             what=f"harvest:{record.id}", user_id=current_user.id)
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
