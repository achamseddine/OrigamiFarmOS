"""Origami FarmOS API — FastAPI application entry point.

Run locally with:  uvicorn app.main:app --reload
See backend/README.md for full setup instructions.
"""
from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1 import animals, auth, farms, feed, health, observations, production, recommendations, reports, sync, tasks
from app.core.config import get_settings
from app.db.base import Base, engine

settings = get_settings()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Local-development convenience: create tables if they don't exist yet. Real
    # deployments use the Alembic migrations in database/migrations/.
    Base.metadata.create_all(bind=engine)
    yield


app = FastAPI(
    title=settings.app_name,
    version="0.1.0",
    description=(
        "Offline-first, tablet-first farm operating system API for Origami Farms. "
        "See CONSTITUTION.md and product/MVP_SCOPE.md in the repository root for the "
        "product principles this API enforces (evidence-based recommendations, "
        "worker-observes/manager-decides separation, event-sourced history)."
    ),
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/", tags=["meta"])
def root() -> dict:
    return {"name": settings.app_name, "status": "ok", "docs": "/docs"}


@app.get("/health", tags=["meta"])
def health_check() -> dict:
    return {"status": "ok"}


api_prefix = settings.api_v1_prefix
app.include_router(auth.router, prefix=api_prefix)
app.include_router(farms.router, prefix=api_prefix)
app.include_router(sync.router, prefix=api_prefix)
app.include_router(animals.router, prefix=api_prefix)
app.include_router(observations.router, prefix=api_prefix)
app.include_router(tasks.router, prefix=api_prefix)
app.include_router(feed.router, prefix=api_prefix)
app.include_router(production.router, prefix=api_prefix)
app.include_router(health.router, prefix=api_prefix)
app.include_router(recommendations.router, prefix=api_prefix)
app.include_router(reports.router, prefix=api_prefix)
