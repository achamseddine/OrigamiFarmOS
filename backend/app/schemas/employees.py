"""Employee records and module responsibilities (tech spec §8/§9/§11)."""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, field_validator

from app.core import permissions as perms
from app.schemas.common import ORMModel

ASSIGNABLE_ROLES = {
    "owner",
    "manager",
    "worker",
    "veterinarian",
    "accountant",
    "read_only",
    "visitor_coordinator",
    "activity_staff",
    "cashier",
    "mouneh_operator",
}

EMPLOYMENT_STATUSES = {"active", "on_leave", "seasonal", "suspended", "ended"}


class ModulePermissionIn(BaseModel):
    module_code: str
    can_view: bool = True
    can_create: bool = False
    can_edit: bool = False
    can_delete: bool = False
    can_approve: bool = False
    can_export: bool = False
    can_assign: bool = False
    can_configure: bool = False

    @field_validator("module_code")
    @classmethod
    def module_known(cls, v: str) -> str:
        if v not in perms.MODULES_BY_CODE:
            raise ValueError(f"Unknown module '{v}'. Valid modules: {sorted(perms.MODULE_CODES)}")
        return v


class ModulePermissionOut(ORMModel):
    module_code: str
    can_view: bool
    can_create: bool
    can_edit: bool
    can_delete: bool
    can_approve: bool
    can_export: bool
    can_assign: bool
    can_configure: bool


class EmployeeBase(BaseModel):
    name: str
    email: str | None = None
    phone: str | None = None
    role: str = "worker"
    department: str | None = None
    language: str = "en"
    job_title: str | None = None
    employment_status: str = "active"
    start_date: datetime | None = None
    photo_path: str | None = None
    working_days: list[str] | None = None
    working_hours: str | None = None
    notes: str | None = None

    @field_validator("name")
    @classmethod
    def name_non_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("name cannot be empty")
        return v.strip()

    @field_validator("role")
    @classmethod
    def role_known(cls, v: str) -> str:
        if v not in ASSIGNABLE_ROLES:
            raise ValueError(f"role must be one of {sorted(ASSIGNABLE_ROLES)}")
        return v

    @field_validator("employment_status")
    @classmethod
    def status_known(cls, v: str) -> str:
        if v not in EMPLOYMENT_STATUSES:
            raise ValueError(f"employment_status must be one of {sorted(EMPLOYMENT_STATUSES)}")
        return v


class EmployeeCreate(EmployeeBase):
    password: str
    permissions: list[ModulePermissionIn] = []

    @field_validator("password")
    @classmethod
    def password_strong_enough(cls, v: str) -> str:
        if len(v) < 8:
            raise ValueError("password must be at least 8 characters")
        return v


class EmployeeUpdate(BaseModel):
    """Every field optional — a PATCH only changes what it names."""

    name: str | None = None
    email: str | None = None
    phone: str | None = None
    role: str | None = None
    department: str | None = None
    language: str | None = None
    job_title: str | None = None
    employment_status: str | None = None
    start_date: datetime | None = None
    photo_path: str | None = None
    working_days: list[str] | None = None
    working_hours: str | None = None
    notes: str | None = None
    active: bool | None = None
    password: str | None = None

    @field_validator("role")
    @classmethod
    def role_known(cls, v: str | None) -> str | None:
        if v is not None and v not in ASSIGNABLE_ROLES:
            raise ValueError(f"role must be one of {sorted(ASSIGNABLE_ROLES)}")
        return v

    @field_validator("employment_status")
    @classmethod
    def status_known(cls, v: str | None) -> str | None:
        if v is not None and v not in EMPLOYMENT_STATUSES:
            raise ValueError(f"employment_status must be one of {sorted(EMPLOYMENT_STATUSES)}")
        return v

    @field_validator("password")
    @classmethod
    def password_strong_enough(cls, v: str | None) -> str | None:
        if v is not None and len(v) < 8:
            raise ValueError("password must be at least 8 characters")
        return v


class EmployeeOut(ORMModel):
    id: str
    farm_id: str
    name: str
    email: str | None = None
    phone: str | None = None
    role: str
    department: str | None = None
    language: str
    active: bool
    job_title: str | None = None
    employment_status: str
    start_date: datetime | None = None
    photo_path: str | None = None
    working_days: list[str] | None = None
    working_hours: str | None = None
    notes: str | None = None


class EmployeeDetailOut(EmployeeOut):
    permissions: list[ModulePermissionOut] = []
    full_access: bool = False


class PermissionSet(BaseModel):
    """Replaces an employee's whole responsibility set in one call, so the
    tablet's permission matrix can save exactly what it shows."""

    permissions: list[ModulePermissionIn]


class ModuleCatalogEntry(BaseModel):
    code: str
    label_en: str
    label_ar: str
    group: str
    license_code: str | None = None
    licensed_active: bool = True


class MyAccessOut(BaseModel):
    """What the signed-in user may do — the tablet builds its navigation
    and hides its action buttons from this."""

    user_id: str
    role: str
    full_access: bool
    modules: dict[str, dict[str, bool]]
