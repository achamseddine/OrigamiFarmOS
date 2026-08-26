"""Application settings.

Reads from environment variables so the same code runs against SQLite in
local development and PostgreSQL in pilot/staging/production
(tech spec §21 "Deployment and Environments").
"""
from __future__ import annotations

import os
from functools import lru_cache


class Settings:
    app_name: str = "Origami FarmOS API"
    api_v1_prefix: str = "/api/v1"

    database_url: str = os.environ.get("DATABASE_URL", "sqlite:///./origami_farmos.db")

    secret_key: str = os.environ.get("FARMOS_SECRET_KEY", "dev-secret-change-me")
    access_token_expire_minutes: int = int(os.environ.get("FARMOS_ACCESS_TOKEN_MINUTES", "480"))
    algorithm: str = "HS256"

@lru_cache
def get_settings() -> Settings:
    return Settings()
