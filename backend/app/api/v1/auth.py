from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.core.config import get_settings
from app.core.security import create_access_token, verify_password
from app.db.base import get_db
from app.domain import models
from app.schemas.auth import LoginRequest, LoginResponse
from app.schemas.users import UserProfileOut

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/login", response_model=LoginResponse)
def login(payload: LoginRequest, db: Session = Depends(get_db)) -> LoginResponse:
    user = db.scalar(select(models.User).where(models.User.email == payload.email))
    if user is None or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid email or password")
    if not user.active:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "User is deactivated")

    token = create_access_token(subject=user.id, role=user.role, farm_id=user.farm_id)
    settings = get_settings()
    return LoginResponse(
        access_token=token,
        expires_in_minutes=settings.access_token_expire_minutes,
        user=UserProfileOut.model_validate(user),
    )


@router.get("/me", response_model=UserProfileOut)
def me(current_user: models.User = Depends(get_current_user)) -> models.User:
    """Lets the mobile app restore a session from its stored token on
    relaunch ("log in once, stay logged in") without re-sending a
    password — it just re-validates the bearer token and returns the
    current profile.
    """
    return current_user
