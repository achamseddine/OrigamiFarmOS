"""SQLAlchemy engine/session setup.

Engine-agnostic on purpose: the same ORM models create a SQLite file for
local development/tests and a PostgreSQL schema for pilot/staging/
`production` (tech spec §21). The PostgreSQL-specific DDL (UUID types,
JSONB, etc.) lives separately in `database/schema.sql` and
`database/migrations/` as the deployment source of truth.
"""
from __future__ import annotations

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from app.core.config import get_settings

settings = get_settings()

connect_args = {"check_same_thread": False} if settings.database_url.startswith("sqlite") else {}
engine = create_engine(settings.database_url, connect_args=connect_args)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


class Base(DeclarativeBase):
    pass


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
