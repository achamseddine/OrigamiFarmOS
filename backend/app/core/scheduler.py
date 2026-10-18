"""The scheduled analytical cycles (FEED-PERFORMANCE-INTELLIGENCE §12 "daily
scheduled feed-performance cycle", MEDICINE-NOTIFICATION-RULES §Scheduled
expiry scan, CLINICAL-DECISION-SUPPORT §12 "schedule reassessment").

Event hooks keep the alerts current between runs; the scheduled cycle is
what guarantees a farm is evaluated at least daily even on a quiet day:
baselines refreshed, persistence checked, recovered conditions resolved,
expiry boundaries crossed, overdue reassessments surfaced.

Mechanics, deliberately plain for a modular monolith: an asyncio task
started by the API's lifespan wakes every `scheduler_interval_minutes`,
and for every farm runs each job whose cadence has elapsed since its last
successful run, in a worker thread with its own session. Every run is a
`scheduled_job_runs` row — when, how triggered, what it did, or why it
failed — and `POST /scheduler/run` runs the same code on demand. A job
that fails is logged and does not stop the others.
"""
from __future__ import annotations

import asyncio
import logging
import traceback
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.domain import models
from app.domain import platform_models as plm
from app.repositories.base import ensure_utc, new_id, now

log = logging.getLogger("origami.scheduler")
SYSTEM_USER = "system"


def _feed_performance_cycle(db: Session, farm_id: str) -> dict:
    from app.services import feed_performance_service as perf

    out = perf.run_cycle(db, farm_id, user_id=SYSTEM_USER)
    return {k: v for k, v in out.items() if k != "assessments"}


def _pharmacy_scan(db: Session, farm_id: str) -> dict:
    from app.services import pharmacy_service as ph

    return ph.evaluate_farm(db, farm_id, user_id=SYSTEM_USER)


def _emergency_reassessment_check(db: Session, farm_id: str) -> dict:
    from app.services import emergency_service as es

    return es.check_overdue_reassessments(db, farm_id, user_id=SYSTEM_USER)


# job code -> (cadence, runner)
JOBS: dict[str, tuple[timedelta, callable]] = {
    "feed_performance_cycle": (timedelta(hours=24), _feed_performance_cycle),
    "pharmacy_scan": (timedelta(hours=24), _pharmacy_scan),
    "emergency_reassessment_check": (timedelta(minutes=15), _emergency_reassessment_check),
}


def last_run(db: Session, farm_id: str, job_code: str, *, successful: bool = True) -> plm.ScheduledJobRun | None:
    stmt = select(plm.ScheduledJobRun).where(plm.ScheduledJobRun.farm_id == farm_id, plm.ScheduledJobRun.job_code == job_code)
    if successful:
        stmt = stmt.where(plm.ScheduledJobRun.status == "succeeded")
    return db.scalar(stmt.order_by(plm.ScheduledJobRun.started_at.desc()))


def next_due(db: Session, farm_id: str, job_code: str) -> datetime:
    last = last_run(db, farm_id, job_code)
    if last is None:
        return now()
    return ensure_utc(last.started_at) + JOBS[job_code][0]


def is_due(db: Session, farm_id: str, job_code: str, at: datetime | None = None) -> bool:
    return next_due(db, farm_id, job_code) <= (at or now())


def run_job(db: Session, farm_id: str, job_code: str, *, trigger: str = "scheduler") -> plm.ScheduledJobRun:
    """Runs one job for one farm and records it. The job's own writes and
    the run row commit together; a failure rolls the job back and commits
    only the failed run row."""
    if job_code not in JOBS:
        raise ValueError(f"Unknown job {job_code}")
    row = plm.ScheduledJobRun(id=new_id(), farm_id=farm_id, job_code=job_code, trigger=trigger, started_at=now(), status="running", summary_json={})
    try:
        summary = JOBS[job_code][1](db, farm_id)
        row.status = "succeeded"
        row.summary_json = _jsonable(summary)
        row.finished_at = now()
        db.add(row)
        db.commit()
    except Exception as exc:  # noqa: BLE001 - every failure is recorded, none stops the others
        db.rollback()
        row.status = "failed"
        row.error = f"{exc.__class__.__name__}: {exc}\n{traceback.format_exc()[-1500:]}"
        row.finished_at = now()
        db.add(row)
        db.commit()
        log.warning("scheduled job %s failed for farm %s: %s", job_code, farm_id, exc)
    return row


def run_due(db: Session, *, farm_id: str | None = None, job_codes: list[str] | None = None, force: bool = False, trigger: str = "scheduler") -> list[plm.ScheduledJobRun]:
    farms = [farm_id] if farm_id else list(db.scalars(select(models.Farm.id)))
    codes = job_codes or list(JOBS)
    runs = []
    for fid in farms:
        for code in codes:
            if force or is_due(db, fid, code):
                runs.append(run_job(db, fid, code, trigger=trigger))
    return runs


def status(db: Session, farm_id: str) -> list[dict]:
    out = []
    for code, (cadence, _) in JOBS.items():
        latest = last_run(db, farm_id, code, successful=False)
        success = last_run(db, farm_id, code)
        out.append({
            "job_code": code, "cadence_minutes": int(cadence.total_seconds() // 60),
            "last_run_at": latest.started_at if latest else None, "last_status": latest.status if latest else None, "last_error": latest.error if latest else None,
            "last_success_at": success.started_at if success else None, "last_summary": success.summary_json if success else {},
            "next_due_at": next_due(db, farm_id, code), "due": is_due(db, farm_id, code),
        })
    return out


def _jsonable(value):
    if isinstance(value, dict):
        return {k: _jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(v) for v in value]
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


# ---------------------------------------------------------------- loop
def _tick() -> int:
    from app.db.base import SessionLocal

    with SessionLocal() as db:
        return len(run_due(db))


async def loop(interval_seconds: float) -> None:
    """Sleeps first: the API starts without a burst of analytics, and a
    short-lived process (a test client) never runs a cycle."""
    while True:
        await asyncio.sleep(interval_seconds)
        try:
            ran = await asyncio.to_thread(_tick)
            if ran:
                log.info("scheduler ran %d job(s)", ran)
        except Exception:  # noqa: BLE001
            log.exception("scheduler tick failed")


def start() -> asyncio.Task | None:
    settings = get_settings()
    if not settings.scheduler_enabled or settings.scheduler_interval_minutes <= 0:
        return None
    return asyncio.get_event_loop().create_task(loop(settings.scheduler_interval_minutes * 60))
