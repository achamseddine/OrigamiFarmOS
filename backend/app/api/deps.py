"""Shared FastAPI dependencies: DB session, current user, and role checks
(tech spec §17 "Security and Access Control" — role checks on every
protected endpoint).
"""
from __future__ import annotations

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.core.security import decode_access_token
from app.db.base import get_db
from app.domain import models
from app.domain import mouneh_models

_bearer_scheme = HTTPBearer(auto_error=False)

DIAGNOSTIC_ROLES = {"owner", "manager", "veterinarian"}
FINANCE_ROLES = {"owner", "accountant", "manager"}
SUPER_USER_ROLES = {"super_user"}


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer_scheme),
    db: Session = Depends(get_db),
) -> models.User:
    if credentials is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Missing bearer token")
    payload = decode_access_token(credentials.credentials)
    if payload is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired token")
    user = db.get(models.User, payload.get("sub"))
    if user is None or not user.active:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "User not found or inactive")
    return user


def require_roles(*allowed_roles: str):
    """Constitution: "Farm managers decide. Veterinarians diagnose and
    prescribe." — this is the enforcement point for that separation.
    """

    def _check(current_user: models.User = Depends(get_current_user)) -> models.User:
        if current_user.role not in allowed_roles:
            raise HTTPException(
                status.HTTP_403_FORBIDDEN,
                f"Role '{current_user.role}' is not permitted to perform this action. "
                f"Required one of: {sorted(allowed_roles)}.",
            )
        return current_user

    return _check


require_diagnostic_role = require_roles(*DIAGNOSTIC_ROLES)
require_finance_role = require_roles(*FINANCE_ROLES)
require_manager_role = require_roles("owner", "manager")

# Tech spec v0.5 REQ-MOU-001: "License-controlled module activated by a
# super user per farm" — a super_user is a platform-level role, distinct
# from the farm-scoped owner/manager/worker/vet/accountant roles above.
# Only a super_user may flip a farm's module license on or off; once
# active, ordinary farm roles (manager/owner) operate the module.
require_super_user = require_roles(*SUPER_USER_ROLES)


def require_module_license(module_code: str):
    """Tech spec v0.5 REQ-MOU-001/008: every Mouneh read/write endpoint is
    gated on the farm's module_licenses row being 'active' — deactivating
    the module (super user only) immediately locks out the rest of the
    module without deleting any data.
    """

    def _check(
        current_user: models.User = Depends(get_current_user),
        db: Session = Depends(get_db),
    ) -> models.User:
        license_row = (
            db.query(mouneh_models.ModuleLicense)
            .filter(
                mouneh_models.ModuleLicense.farm_id == current_user.farm_id,
                mouneh_models.ModuleLicense.module_code == module_code,
            )
            .one_or_none()
        )
        if license_row is None or license_row.status != "active":
            raise HTTPException(
                status.HTTP_403_FORBIDDEN,
                f"The '{module_code}' module is not active for this farm. Ask a super user to activate it.",
            )
        return current_user

    return _check
