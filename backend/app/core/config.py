"""Application settings.

Reads from environment variables so the same code runs against SQLite in
`local`/`demo` mode and PostgreSQL in `pilot`/`staging`/`production`
(tech spec §21 "Deployment and Environments").
"""
from __future__ import annotations

import os
from functools import lru_cache


def normalize_database_url(url: str) -> str:
    """Pin the PostgreSQL driver this backend ships with.

    `postgresql://` without a driver means "SQLAlchemy's default", and that
    default moved from psycopg2 to psycopg 3 in SQLAlchemy 2.1 — a plain
    connection string that worked one week fails the next with "No module
    named 'psycopg'" once the dependency resolver picks the newer release.
    requirements.txt installs psycopg2, so every bare PostgreSQL URL (and
    the `postgres://` spelling some hosts hand out) is routed to it here,
    for the API, Alembic and the workflows alike.
    """
    for prefix in ("postgresql://", "postgres://"):
        if url.startswith(prefix):
            return "postgresql+psycopg2://" + url[len(prefix):]
    return url


class Settings:
    app_name: str = "Origami FarmOS API"
    api_v1_prefix: str = "/api/v1"

    database_url: str = normalize_database_url(os.environ.get("DATABASE_URL", "sqlite:///./origami_farmos.db"))

    secret_key: str = os.environ.get("FARMOS_SECRET_KEY", "dev-secret-change-me")
    access_token_expire_minutes: int = int(os.environ.get("FARMOS_ACCESS_TOKEN_MINUTES", "480"))
    algorithm: str = "HS256"

    default_farm_id: str = "farm-origami"
    demo_mode: bool = os.environ.get("FARMOS_DEMO_MODE", "true").lower() == "true"

    # The background analytical cycles (app/core/scheduler.py): how often
    # the loop wakes to run whatever is due. 0 or FARMOS_SCHEDULER=false
    # disables the loop; POST /scheduler/run still runs the jobs on demand.
    scheduler_enabled: bool = os.environ.get("FARMOS_SCHEDULER", "true").lower() == "true"
    scheduler_interval_minutes: int = int(os.environ.get("FARMOS_SCHEDULER_INTERVAL_MINUTES", "15"))


@lru_cache
def get_settings() -> Settings:
    return Settings()
