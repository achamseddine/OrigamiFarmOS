"""Module license administration (tech spec v0.5 REQ-MOU-001): "License-
controlled module activated by a super user per farm." Deliberately kept
separate from app/api/v1/mouneh.py — checking/activating a license must
never itself require the license to already be active.
"""
from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from fastapi import APIRouter, Depends, HTTPException, status

from app.api.deps import get_current_user, require_super_user
from app.db.base import get_db
from app.domain import models, mouneh_models
from app.repositories.base import new_id, now, write_audit_log
from app.schemas.mouneh import ModuleLicenseOut, ModuleLicenseUpdate

router = APIRouter(prefix="/modules", tags=["modules"])


@router.get("", response_model=list[ModuleLicenseOut])
def list_modules(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[mouneh_models.ModuleLicense]:
    return list(
        db.scalars(select(mouneh_models.ModuleLicense).where(mouneh_models.ModuleLicense.farm_id == current_user.farm_id))
    )


def _get_or_create(db: Session, farm_id: str, module_code: str) -> mouneh_models.ModuleLicense:
    license_row = db.scalars(
        select(mouneh_models.ModuleLicense).where(
            mouneh_models.ModuleLicense.farm_id == farm_id, mouneh_models.ModuleLicense.module_code == module_code
        )
    ).one_or_none()
    if license_row is None:
        license_row = mouneh_models.ModuleLicense(id=new_id(), farm_id=farm_id, module_code=module_code, status="inactive")
        db.add(license_row)
        db.flush()
    return license_row


@router.post("/{module_code}/activate", response_model=ModuleLicenseOut)
def activate_module(
    module_code: str,
    payload: ModuleLicenseUpdate = ModuleLicenseUpdate(status="active"),
    farm_id: str | None = None,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_super_user),
) -> mouneh_models.ModuleLicense:
    """A super user is not necessarily scoped to one farm, so the target
    farm is explicit (defaults to the super user's own farm record for
    convenience in the single-farm MVP deployment)."""
    target_farm_id = farm_id or current_user.farm_id
    license_row = _get_or_create(db, target_farm_id, module_code)
    license_row.status = "active"
    license_row.plan = payload.plan
    license_row.starts_at = now()
    license_row.expires_at = payload.expires_at
    license_row.max_users = payload.max_users
    license_row.max_products = payload.max_products
    license_row.activated_by = current_user.id
    write_audit_log(
        db,
        farm_id=target_farm_id,
        user_id=current_user.id,
        action="module_activated",
        entity_type="module_license",
        entity_id=license_row.id,
        metadata={"module_code": module_code, "plan": payload.plan},
    )
    db.commit()
    db.refresh(license_row)
    return license_row


@router.post("/{module_code}/deactivate", response_model=ModuleLicenseOut)
def deactivate_module(
    module_code: str,
    farm_id: str | None = None,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_super_user),
) -> mouneh_models.ModuleLicense:
    target_farm_id = farm_id or current_user.farm_id
    license_row = _get_or_create(db, target_farm_id, module_code)
    license_row.status = "inactive"
    write_audit_log(
        db,
        farm_id=target_farm_id,
        user_id=current_user.id,
        action="module_deactivated",
        entity_type="module_license",
        entity_id=license_row.id,
        metadata={"module_code": module_code},
    )
    db.commit()
    db.refresh(license_row)
    return license_row


@router.get("/{module_code}", response_model=ModuleLicenseOut)
def get_module(
    module_code: str, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)
) -> mouneh_models.ModuleLicense:
    license_row = db.scalars(
        select(mouneh_models.ModuleLicense).where(
            mouneh_models.ModuleLicense.farm_id == current_user.farm_id, mouneh_models.ModuleLicense.module_code == module_code
        )
    ).one_or_none()
    if license_row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No license record for this module on this farm")
    return license_row
