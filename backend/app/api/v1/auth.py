from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.core.security import create_access_token, verify_password
from app.db.base import get_db
from app.domain import models
from app.schemas.auth import LoginRequest, LoginResponse, UserOut

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
        user=UserOut(id=user.id, farm_id=user.farm_id, name=user.name, role=user.role, language=user.language),
    )
