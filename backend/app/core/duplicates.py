"""Duplicate-entry guards (handbook/03-Behavioral-Model.md §5, §13; API
standards: "Retryable writes use an Idempotency-Key").

Two different duplicates, two different defences:

* **the same request sent twice** — a retry, an offline replay, a double
  tap that got through — is answered from the stored response by the
  `Idempotency-Key` middleware (app/core/idempotency.py). Nothing here.
* **the same fact entered twice by people** — two workers milking-recording
  the same cow, a delivery note typed in again, a mix saved twice — is a
  new request with a new key. Each record workflow therefore looks for an
  existing record that says the same thing (same subject, same day or the
  same half-hour, same quantities) and refuses with 409 and a sentence
  starting "Possible duplicate:", naming what is already there.

A real second entry is legitimate (a second milking, a second insemination
the same heat, two deliveries on one invoice): the client resends with
`confirm_duplicate: true` after the person has said so, and the confirmed
duplicate is written to the event log with the record it resembles — an
exception that stays auditable. Where a repeat can never be right (a group
or a feed with the same name, a lot code already used) the refusal is a
plain 409 with no override.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi import HTTPException, status
from sqlalchemy.orm import Session

from app.repositories.base import ensure_utc, write_event

PREFIX = "Possible duplicate:"
# Two identical entries this close together are taken for the same fact.
WINDOW = timedelta(minutes=30)
# A dose of the same medicine to the same animal this close is checked.
DOSE_WINDOW = timedelta(hours=12)


class PossibleDuplicate(HTTPException):
    def __init__(self, message: str):
        super().__init__(status.HTTP_409_CONFLICT, detail=f"{PREFIX} {message}")


def guard(match, message: str, *, confirm: bool):
    """Refuses when [match] exists and the person has not confirmed. Returns
    the match (None when there is none) so a confirmed duplicate can be
    logged against it."""
    if match is not None and not confirm:
        raise PossibleDuplicate(message)
    return match


def near(at: datetime | None, window: timedelta = WINDOW) -> tuple[datetime, datetime]:
    t = ensure_utc(at) if at else datetime.now(timezone.utc)
    return t - window, t + window


def farm_day(db: Session, farm_id: str, at: datetime | None) -> tuple[datetime, datetime]:
    """The farm's local calendar day around [at], as UTC bounds — a morning
    milking in Beirut is "today" in Beirut, not in UTC."""
    from app.domain import models

    farm = db.get(models.Farm, farm_id)
    try:
        tz = ZoneInfo(farm.timezone if farm and farm.timezone else "UTC")
    except Exception:  # noqa: BLE001 - an unknown zone name falls back to UTC
        tz = ZoneInfo("UTC")
    t = (ensure_utc(at) if at else datetime.now(timezone.utc)).astimezone(tz)
    start = t.replace(hour=0, minute=0, second=0, microsecond=0)
    return start.astimezone(timezone.utc), (start + timedelta(days=1)).astimezone(timezone.utc)


def log_confirmed(db: Session, *, farm_id: str, entity_type: str, entity_id: str, match_id: str | None, what: str, user_id: str) -> None:
    """A duplicate the person confirmed: written down with what it resembles."""
    if match_id is None:
        return
    write_event(db, farm_id=farm_id, entity_type=entity_type, entity_id=entity_id, event_type="duplicate_confirmed",
                payload={"record": what, "resembles": match_id}, created_by=user_id)
