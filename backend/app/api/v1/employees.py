"""Employees & Responsibilities (tech spec §8/§9/§11).

A farm manager creates staff accounts here and decides, per employee and
per module, exactly what they may do. Everything in this router is
manager-only except `/me/access`, which is how any signed-in user asks
"what am I allowed to do?" so the tablet can build itself accordingly.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, load_permission_map, require_permission
from app.core import permissions as perms
from app.core.security import hash_password
from app.db.base import get_db
from app.domain import models, mouneh_models
from app.repositories.base import diff_changes, new_id, now, snapshot, write_audit_log
from app.schemas.employees import (
    EmployeeCreate,
    EmployeeDetailOut,
    EmployeeOut,
    EmployeeUpdate,
    ModuleCatalogEntry,
    ModulePermissionIn,
    ModulePermissionOut,
    MyAccessOut,
    PermissionSet,
)

router = APIRouter(tags=["employees"])

_AUDITED_EMPLOYEE_FIELDS = [
    "name", "email", "phone", "role", "department", "language", "active",
    "job_title", "employment_status", "photo_path", "working_hours", "notes",
]


# ---------------------------------------------------------------------------
# Module catalog + my own access
# ---------------------------------------------------------------------------
@router.get("/modules/catalog", response_model=list[ModuleCatalogEntry])
def module_catalog(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> list[dict]:
    """Every module the product has, with whether this farm's licence for
    it is active (tech spec §10 — modules can be switched off per farm's
    subscription). Any signed-in user may read it; it describes the
    product, not the farm's data.
    """
    licences = {
        row.module_code: row.status
        for row in db.scalars(
            select(mouneh_models.ModuleLicense).where(mouneh_models.ModuleLicense.farm_id == current_user.farm_id)
        )
    }
    out = []
    for module in perms.MODULE_CATALOG:
        entry = module.as_dict()
        entry["licensed_active"] = (
            True if module.licensed is None else licences.get(module.licensed) in {"active", "trial"}
        )
        out.append(entry)
    return out


@router.get("/me/access", response_model=MyAccessOut)
def my_access(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> dict:
    return {
        "user_id": current_user.id,
        "role": current_user.role,
        "full_access": perms.is_full_access(current_user.role),
        "modules": load_permission_map(db, current_user),
    }


# ---------------------------------------------------------------------------
# Employees
# ---------------------------------------------------------------------------
def _employee_or_404(db: Session, employee_id: str, farm_id: str) -> models.User:
    employee = db.get(models.User, employee_id)
    if employee is None or employee.farm_id != farm_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Employee not found")
    return employee


def _permissions_for(db: Session, user: models.User) -> list[models.UserModulePermission]:
    return list(
        db.scalars(
            select(models.UserModulePermission)
            .where(models.UserModulePermission.user_id == user.id)
            .order_by(models.UserModulePermission.module_code)
        )
    )


def _detail(db: Session, employee: models.User) -> dict:
    base = EmployeeOut.model_validate(employee).model_dump()
    base["permissions"] = [ModulePermissionOut.model_validate(p).model_dump() for p in _permissions_for(db, employee)]
    base["full_access"] = perms.is_full_access(employee.role)
    return base


@router.get("/employees", response_model=list[EmployeeDetailOut])
def list_employees(
    include_inactive: bool = False,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.EMPLOYEES, perms.VIEW)),
) -> list[dict]:
    stmt = select(models.User).where(models.User.farm_id == current_user.farm_id)
    if not include_inactive:
        stmt = stmt.where(models.User.active.is_(True))
    return [_detail(db, e) for e in db.scalars(stmt.order_by(models.User.name))]


@router.get("/employees/{employee_id}", response_model=EmployeeDetailOut)
def get_employee(
    employee_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.EMPLOYEES, perms.VIEW)),
) -> dict:
    return _detail(db, _employee_or_404(db, employee_id, current_user.farm_id))


@router.post("/employees", response_model=EmployeeDetailOut, status_code=status.HTTP_201_CREATED)
def create_employee(
    payload: EmployeeCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.EMPLOYEES, perms.CREATE)),
) -> dict:
    if payload.email:
        existing = db.scalars(select(models.User).where(models.User.email == payload.email)).one_or_none()
        if existing is not None:
            raise HTTPException(status.HTTP_409_CONFLICT, f"An account already uses {payload.email}.")

    data = payload.model_dump(exclude={"password", "permissions"})
    employee = models.User(
        id=new_id(),
        farm_id=current_user.farm_id,
        password_hash=hash_password(payload.password),
        active=True,
        **data,
    )
    db.add(employee)
    db.flush()

    granted = payload.permissions or _preset_permissions(payload.department)
    _replace_permissions(db, employee, granted, granted_by=current_user.id)

    write_audit_log(
        db,
        farm_id=current_user.farm_id,
        user_id=current_user.id,
        action="employee_created",
        entity_type="employee",
        entity_id=employee.id,
        module_code=perms.EMPLOYEES,
        summary=f"{current_user.name} created employee {employee.name}",
        metadata={"role": employee.role, "modules": [p.module_code for p in granted]},
    )
    db.commit()
    db.refresh(employee)
    return _detail(db, employee)


@router.patch("/employees/{employee_id}", response_model=EmployeeDetailOut)
def update_employee(
    employee_id: str,
    payload: EmployeeUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.EMPLOYEES, perms.EDIT)),
) -> dict:
    employee = _employee_or_404(db, employee_id, current_user.farm_id)
    changes = payload.model_dump(exclude_unset=True, exclude={"password"})

    if employee.id == current_user.id and changes.get("active") is False:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "You cannot deactivate your own account.")
    if "email" in changes and changes["email"]:
        clash = db.scalars(
            select(models.User).where(models.User.email == changes["email"], models.User.id != employee.id)
        ).one_or_none()
        if clash is not None:
            raise HTTPException(status.HTTP_409_CONFLICT, f"An account already uses {changes['email']}.")

    before = snapshot(employee, _AUDITED_EMPLOYEE_FIELDS)
    for field, value in changes.items():
        setattr(employee, field, value)
    if payload.password:
        employee.password_hash = hash_password(payload.password)

    diff = diff_changes(before, employee, _AUDITED_EMPLOYEE_FIELDS)
    if payload.password:
        diff["password"] = {"from": "********", "to": "********"}
    write_audit_log(
        db,
        farm_id=current_user.farm_id,
        user_id=current_user.id,
        action="employee_updated",
        entity_type="employee",
        entity_id=employee.id,
        module_code=perms.EMPLOYEES,
        summary=f"{current_user.name} updated employee {employee.name}",
        changes=diff,
    )
    db.commit()
    db.refresh(employee)
    return _detail(db, employee)


@router.delete("/employees/{employee_id}", status_code=status.HTTP_204_NO_CONTENT)
def deactivate_employee(
    employee_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.EMPLOYEES, perms.DELETE)),
) -> None:
    """Deactivates rather than deletes: an employee's name is attached to
    every record they ever entered, and the Constitution's "history is
    never silently deleted" applies to who did the work too.
    """
    employee = _employee_or_404(db, employee_id, current_user.farm_id)
    if employee.id == current_user.id:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "You cannot deactivate your own account.")
    employee.active = False
    employee.employment_status = "ended"
    write_audit_log(
        db,
        farm_id=current_user.farm_id,
        user_id=current_user.id,
        action="employee_deactivated",
        entity_type="employee",
        entity_id=employee.id,
        module_code=perms.EMPLOYEES,
        summary=f"{current_user.name} deactivated employee {employee.name}",
    )
    db.commit()


# ---------------------------------------------------------------------------
# Responsibilities
# ---------------------------------------------------------------------------
def _preset_permissions(department: str | None) -> list[ModulePermissionIn]:
    """Starting grants for a new employee, from their department preset
    plus the baseline every employee needs. Only ever a starting point —
    the manager can change any of it immediately afterwards.
    """
    codes = list(perms.BASELINE_EMPLOYEE_MODULES)
    codes += [c for c in perms.DEPARTMENT_MODULE_PRESETS.get(department or "", ()) if c not in codes]
    return [
        ModulePermissionIn(module_code=code, **{f"can_{a}": v for a, v in perms.DEFAULT_RESPONSIBILITY_GRANT.items()})
        for code in codes
    ]


def _replace_permissions(
    db: Session, employee: models.User, granted: list[ModulePermissionIn], *, granted_by: str
) -> None:
    for existing in _permissions_for(db, employee):
        db.delete(existing)
    db.flush()
    for item in granted:
        db.add(
            models.UserModulePermission(
                id=new_id(),
                farm_id=employee.farm_id,
                user_id=employee.id,
                module_code=item.module_code,
                can_view=item.can_view,
                can_create=item.can_create,
                can_edit=item.can_edit,
                can_delete=item.can_delete,
                can_approve=item.can_approve,
                can_export=item.can_export,
                can_assign=item.can_assign,
                can_configure=item.can_configure,
                granted_by=granted_by,
                granted_at=now(),
            )
        )


@router.put("/employees/{employee_id}/permissions", response_model=EmployeeDetailOut)
def set_employee_permissions(
    employee_id: str,
    payload: PermissionSet,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.EMPLOYEES, perms.ASSIGN)),
) -> dict:
    """Replaces the employee's whole responsibility set — send every module
    they should hold, and anything omitted is revoked.
    """
    employee = _employee_or_404(db, employee_id, current_user.farm_id)
    if perms.is_full_access(employee.role):
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"A {employee.role} already has full access to every module. Change their role first to limit it.",
        )

    seen: set[str] = set()
    for item in payload.permissions:
        if item.module_code in seen:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"Module '{item.module_code}' listed twice.")
        seen.add(item.module_code)

    before = sorted(p.module_code for p in _permissions_for(db, employee))
    _replace_permissions(db, employee, payload.permissions, granted_by=current_user.id)
    after = sorted(item.module_code for item in payload.permissions)

    write_audit_log(
        db,
        farm_id=current_user.farm_id,
        user_id=current_user.id,
        action="permissions_changed",
        entity_type="employee",
        entity_id=employee.id,
        module_code=perms.EMPLOYEES,
        summary=f"{current_user.name} updated {employee.name}'s module responsibilities",
        changes={"modules": {"from": before, "to": after}},
    )
    db.commit()
    db.refresh(employee)
    return _detail(db, employee)
