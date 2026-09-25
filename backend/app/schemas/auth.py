from __future__ import annotations

from pydantic import BaseModel, Field


class LoginRequest(BaseModel):
    email: str
    password: str
    device_id: str | None = None


class UserOut(BaseModel):
    id: str
    farm_id: str
    name: str
    role: str
    language: str


class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in_minutes: int
    user: UserOut


class BootstrapResponse(BaseModel):
    """GET /farms/{farm_id}/bootstrap — initial local-cache payload
    (tech spec §12). The tablet stores this verbatim into SQLite on first
    login / demo activation.
    """

    farm: dict
    users: list[dict]
    locations: list[dict]
    animals: list[dict]
    flocks: list[dict]
    fields: list[dict]
    inventory_items: list[dict]
    tasks: list[dict]
    recommendations: list[dict]
    server_time: str
    sync_cursor: str = Field(description="Opaque cursor for the first GET /sync/pull call")
