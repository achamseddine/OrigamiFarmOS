"""Farm pharmacy API (database/MEDICINE-PHARMACY-SCHEMA.md).

Reads need inventory or animal-health view; stock writes need inventory
create/edit; thresholds need inventory configure (or edit); closing an
alert by hand needs inventory approve; an administration needs animal-
health create and, for a prescription-only medicine, a recorded
treatment or an approved protocol step. Stocking a medicine never
authorises its use.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_permission, user_can
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.domain import pharmacy_models as pm
from app.schemas.pharmacy import (
    AdministrationReverse, MedicationAdministrationIn, MedicineLotOpen, MedicineLotReceive, MedicineLotStatus, MedicineLotStorage,
    MedicineProductIn, MedicineProductPatch, PharmacyAdjustment, PharmacyAlertClose, PharmacyPolicyIn,
)
from app.services import pharmacy_service as ph

router = APIRouter(prefix="/pharmacy", tags=["pharmacy"])


def _either(*checks: tuple[str, str]):
    """Passes when the user holds any one of the (module, action) pairs —
    the pharmacy sits between stock and animal health."""

    def _dep(db: Session = Depends(get_db), user: models.User = Depends(get_current_user)) -> models.User:
        for module, action in checks:
            if user_can(db, user, module, action):
                return user
        raise HTTPException(status.HTTP_403_FORBIDDEN, "You do not have permission for the farm pharmacy. Ask a farm manager to grant inventory or animal-health access.")

    return _dep


_view = _either((perms.INVENTORY, perms.VIEW), (perms.ANIMAL_HEALTH, perms.VIEW))
_stock = _either((perms.INVENTORY, perms.CREATE), (perms.INVENTORY, perms.EDIT))
_stock_edit = require_permission(perms.INVENTORY, perms.EDIT)
_configure = _either((perms.INVENTORY, perms.CONFIGURE), (perms.INVENTORY, perms.EDIT))
_approve = require_permission(perms.INVENTORY, perms.APPROVE)
_administer = require_permission(perms.ANIMAL_HEALTH, perms.CREATE)
_health_edit = require_permission(perms.ANIMAL_HEALTH, perms.EDIT)


# ---------------------------------------------------------------- summary
@router.get("/summary")
def pharmacy_summary(db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return ph.summary(db, user.farm_id)


@router.post("/evaluate")
def evaluate(db: Session = Depends(get_db), user: models.User = Depends(_stock)) -> dict:
    """The pharmacy scan (notification rules §Trigger model): every
    medicine against its lots' expiry and the farm's thresholds."""
    out = ph.evaluate_farm(db, user.farm_id, user_id=user.id)
    db.commit()
    return out


@router.get("/categories")
def list_categories(db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    ph.ensure_pharmacy_reference_data(db)
    db.commit()
    return [{"id": c.id, "code": c.code, "name": c.name, "name_ar": c.name_ar, "active": c.active} for c in db.scalars(select(pm.MedicineCategory).order_by(pm.MedicineCategory.code))]


@router.get("/ingredients")
def list_ingredients(db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    ph.ensure_pharmacy_reference_data(db)
    db.commit()
    return [{"id": i.id, "code": i.code, "name": i.name, "active": i.active} for i in db.scalars(select(pm.MedicineActiveIngredient).order_by(pm.MedicineActiveIngredient.name))]


# -------------------------------------------------------------- medicines
@router.get("/medicines")
def list_medicines(include_inactive: bool = False, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    """The essential medicine dashboard (§10): eligible against on hand,
    thresholds, lots, earliest expiry, storage exceptions, open reorder
    and the OK / LOW / CRITICAL / OUT status."""
    return ph.dashboard(db, user.farm_id, include_inactive=include_inactive)


@router.post("/medicines", status_code=status.HTTP_201_CREATED)
def create_medicine(payload: MedicineProductIn, db: Session = Depends(get_db), user: models.User = Depends(_stock)) -> dict:
    body = payload.model_dump()
    body["ingredients"] = [i.model_dump() for i in payload.ingredients]
    product = ph.create_product(db, user.farm_id, user_id=user.id, **body)
    db.commit()
    return ph.product_dict(db, product, with_lots=True)


@router.get("/medicines/{item_id}")
def get_medicine(item_id: str, db: Session = Depends(get_db), user: models.User = Depends(_view)) -> dict:
    return ph.product_dict(db, ph.get_product(db, item_id, user.farm_id), with_lots=True)


@router.patch("/medicines/{item_id}")
def update_medicine(item_id: str, payload: MedicineProductPatch, db: Session = Depends(get_db), user: models.User = Depends(_stock_edit)) -> dict:
    changes = payload.model_dump(exclude_unset=True)
    if "ingredients" in changes and changes["ingredients"] is not None:
        changes["ingredients"] = [i.model_dump() for i in payload.ingredients]
    product = ph.update_product(db, ph.get_product(db, item_id, user.farm_id), changes, user_id=user.id)
    db.commit()
    return ph.product_dict(db, product, with_lots=True)


# ------------------------------------------------------------------- lots
@router.get("/lots")
def list_lots(inventory_item_id: str | None = None, lot_status: str | None = Query(None, alias="status"), eligible_only: bool = False,
              db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    stmt = select(pm.InventoryLot).where(pm.InventoryLot.farm_id == user.farm_id)
    if inventory_item_id:
        stmt = stmt.where(pm.InventoryLot.inventory_item_id == inventory_item_id)
    rows = [ph.lot_dict(db, l) for l in db.scalars(stmt.order_by(pm.InventoryLot.expiry_date, pm.InventoryLot.received_at))]
    if lot_status:
        rows = [r for r in rows if r["status"] == lot_status]
    if eligible_only:
        rows = [r for r in rows if r["eligible"]]
    return rows


@router.post("/lots/receive", status_code=status.HTTP_201_CREATED)
def receive_lot(payload: MedicineLotReceive, db: Session = Depends(get_db), user: models.User = Depends(_stock)) -> dict:
    product = ph.get_product(db, payload.inventory_item_id, user.farm_id)
    body = payload.model_dump(exclude={"inventory_item_id"})
    lot = ph.receive_lot(db, product, user_id=user.id, **body)
    db.commit()
    return ph.lot_dict(db, lot)


@router.patch("/lots/{lot_id}/status")
def set_lot_status(lot_id: str, payload: MedicineLotStatus, db: Session = Depends(get_db), user: models.User = Depends(_stock_edit)) -> dict:
    lot = ph.set_lot_status(db, ph.get_lot(db, lot_id, user.farm_id), payload.status, reason=payload.reason, recall_reference=payload.recall_reference, user_id=user.id)
    db.commit()
    return ph.lot_dict(db, lot)


@router.patch("/lots/{lot_id}/storage")
def set_lot_storage(lot_id: str, payload: MedicineLotStorage, db: Session = Depends(get_db), user: models.User = Depends(_stock_edit)) -> dict:
    lot = ph.set_storage_status(db, ph.get_lot(db, lot_id, user.farm_id), storage_status=payload.storage_status, cold_chain_exception=payload.cold_chain_exception,
                                note=payload.note, user_id=user.id)
    db.commit()
    return ph.lot_dict(db, lot)


@router.post("/lots/{lot_id}/open")
def open_lot(lot_id: str, payload: MedicineLotOpen | None = None, db: Session = Depends(get_db), user: models.User = Depends(_stock)) -> dict:
    lot = ph.open_lot(db, ph.get_lot(db, lot_id, user.farm_id), opened_at=payload.opened_at if payload else None, user_id=user.id)
    db.commit()
    return ph.lot_dict(db, lot)


@router.post("/adjustments", status_code=status.HTTP_201_CREATED)
def adjust_stock(payload: PharmacyAdjustment, db: Session = Depends(get_db), user: models.User = Depends(_stock_edit)) -> dict:
    product = ph.get_product(db, payload.inventory_item_id, user.farm_id)
    lot = ph.get_lot(db, payload.lot_id, user.farm_id)
    tx = ph.adjust(db, product, lot=lot, delta=payload.delta, reason=payload.reason, explanation=payload.explanation, user_id=user.id)
    db.commit()
    return {"transaction_id": tx.id, "lot": ph.lot_dict(db, lot), "medicine": ph.product_dict(db, product)}


# --------------------------------------------------------------- policies
@router.get("/policies")
def list_policies(db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    return [ph.policy_dict(p) for p in db.scalars(select(pm.PharmacyStockPolicy).where(pm.PharmacyStockPolicy.farm_id == user.farm_id))]


@router.put("/policies/{item_id}")
def upsert_policy(item_id: str, payload: PharmacyPolicyIn, db: Session = Depends(get_db), user: models.User = Depends(_configure)) -> dict:
    """The farm manager's minimum / critical / target per medicine (and
    optionally per location). Thresholds are configuration, never advice."""
    product = ph.get_product(db, item_id, user.farm_id)
    body = payload.model_dump()
    location_id = body.pop("location_id")
    policy = ph.upsert_policy(db, product, location_id=location_id, user_id=user.id, **body)
    db.commit()
    return {"policy": ph.policy_dict(policy), "medicine": ph.product_dict(db, product)}


# ----------------------------------------------------------------- alerts
@router.get("/alerts")
def list_alerts(alert_status: str | None = Query("open", alias="status"), inventory_item_id: str | None = None,
                db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    stmt = select(pm.PharmacyStockAlert).where(pm.PharmacyStockAlert.farm_id == user.farm_id)
    if alert_status == "open":
        stmt = stmt.where(pm.PharmacyStockAlert.status != "resolved")
    elif alert_status and alert_status != "all":
        stmt = stmt.where(pm.PharmacyStockAlert.status == alert_status)
    if inventory_item_id:
        stmt = stmt.where(pm.PharmacyStockAlert.inventory_item_id == inventory_item_id)
    return [ph.alert_dict(db, a) for a in db.scalars(stmt.order_by(pm.PharmacyStockAlert.detected_at.desc()))]


def _alert(db: Session, alert_id: str, farm_id: str) -> pm.PharmacyStockAlert:
    a = db.get(pm.PharmacyStockAlert, alert_id)
    if a is None or a.farm_id != farm_id:
        raise ph.PharmacyError("Alert not found", 404)
    return a


@router.post("/alerts/{alert_id}/acknowledge")
def acknowledge_alert(alert_id: str, db: Session = Depends(get_db), user: models.User = Depends(_stock)) -> dict:
    a = ph.acknowledge_alert(db, _alert(db, alert_id, user.farm_id), user_id=user.id)
    db.commit()
    return ph.alert_dict(db, a)


@router.post("/alerts/{alert_id}/resolve")
def resolve_alert(alert_id: str, payload: PharmacyAlertClose, db: Session = Depends(get_db), user: models.User = Depends(_approve)) -> dict:
    a = ph.resolve_alert_manually(db, _alert(db, alert_id, user.farm_id), note=payload.note, user_id=user.id)
    db.commit()
    return ph.alert_dict(db, a)


@router.post("/alerts/{alert_id}/requisition")
def create_requisition(alert_id: str, db: Session = Depends(get_db), user: models.User = Depends(_stock)) -> dict:
    """Opens one DRAFT requisition task for the shortage (§9). Calling it
    again returns the same open draft; nothing here approves a purchase."""
    task, created = ph.create_requisition(db, _alert(db, alert_id, user.farm_id), user_id=user.id)
    db.commit()
    return {"task_id": task.id, "title": task.title, "status": task.status, "created": created, "alert": ph.alert_dict(db, _alert(db, alert_id, user.farm_id))}


# -------------------------------------------------------- administrations
@router.get("/administrations")
def list_administrations(subject_id: str | None = None, inventory_item_id: str | None = None, limit: int = Query(100, ge=1, le=500),
                         db: Session = Depends(get_db), user: models.User = Depends(_view)) -> list[dict]:
    stmt = select(pm.MedicationAdministration).where(pm.MedicationAdministration.farm_id == user.farm_id)
    if subject_id:
        stmt = stmt.where(pm.MedicationAdministration.subject_id == subject_id)
    if inventory_item_id:
        stmt = stmt.where(pm.MedicationAdministration.inventory_item_id == inventory_item_id)
    return [ph.administration_dict(db, a) for a in db.scalars(stmt.order_by(pm.MedicationAdministration.administered_at.desc()).limit(limit))]


@router.post("/administrations", status_code=status.HTTP_201_CREATED)
def record_administration(payload: MedicationAdministrationIn, db: Session = Depends(get_db), user: models.User = Depends(_administer)) -> dict:
    """The dose actually given, bound to the exact lot (§11): validates
    the treatment context and the lot, posts the consumption, applies the
    product's authorised withdrawal and re-evaluates the thresholds."""
    adm = ph.administer(db, user.farm_id, user_id=user.id, **payload.model_dump())
    db.commit()
    return ph.administration_dict(db, adm)


@router.post("/administrations/{administration_id}/reverse", status_code=status.HTTP_201_CREATED)
def reverse_administration(administration_id: str, payload: AdministrationReverse, db: Session = Depends(get_db), user: models.User = Depends(_health_edit)) -> dict:
    adm = db.get(pm.MedicationAdministration, administration_id)
    if adm is None or adm.farm_id != user.farm_id:
        raise ph.PharmacyError("Administration not found", 404)
    ph.reverse_administration(db, adm, reason=payload.reason, user_id=user.id)
    db.commit()
    return ph.administration_dict(db, adm)
