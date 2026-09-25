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

_bearer_scheme = HTTPBearer(auto_error=False)

DIAGNOSTIC_ROLES = {"owner", "manager", "veterinarian"}
FINANCE_ROLES = {"owner", "accountant", "manager"}


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
