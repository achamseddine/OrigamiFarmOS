"""A write a tablet recorded while it could not reach the farm server
(audit I-11, ADR-008).

The tablet's outbox replays each queued write with the header
`X-Offline-Recorded-At`: when the person recorded it on the tablet. The
server never trusts a tablet's view of the farm — it judges every write
against its own records, as for a live one. The header only tells it that
the person did not see the server's answer at the time, so a rule that a
live entry meets by refusing ("record this milk as withheld") is met by
keeping the record, holding it and telling the people who decide. It
cannot make anything saleable or allowed that a live entry is not.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from fastapi import Request

from app.repositories.base import ensure_utc, now

HEADER = "X-Offline-Recorded-At"

# A tablet's clock may run a little ahead of the server's.
_CLOCK_SLACK = timedelta(minutes=10)


def recorded_offline_at(request: Request | None) -> datetime | None:
    """When the write was recorded offline, or None for a live write (no
    header, or one that is not a time up to now)."""
    raw = request.headers.get(HEADER) if request is not None else None
    if not raw:
        return None
    try:
        at = ensure_utc(datetime.fromisoformat(raw.strip().replace("Z", "+00:00")))
    except ValueError:
        return None
    if at > now() + _CLOCK_SLACK:
        return None
    return at
