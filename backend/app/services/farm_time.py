"""The farm's calendar (v0.8.6; audit 2026-11-25 I-6).

Every "today", "yesterday", "this week" and day-by-day figure is a day of
the farm's own calendar, in its time zone (farms.timezone — Asia/Beirut on
Origami), never the UTC calendar. A feeding at 00:30 in Beirut belongs to
that Beirut day although it is still the evening before in UTC.

Bounds are UTC instants [lo, hi): local midnight to the next local
midnight. Built from the date in the zone, not by adding 24 hours, so a day
across a daylight-saving change is 23 or 25 hours long, as the farm lives it
(Lebanon moves its clocks at midnight: 2026-03-29 starts at 01:00 and
2026-10-24 ends at the second 23:59).
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from sqlalchemy.orm import Session

from app.domain import models
from app.repositories.base import ensure_utc


def farm_tz(db: Session, farm_id: str) -> ZoneInfo:
    farm = db.get(models.Farm, farm_id)
    try:
        return ZoneInfo(farm.timezone if farm and farm.timezone else "UTC")
    except Exception:  # noqa: BLE001 - an unknown zone name falls back to UTC
        return ZoneInfo("UTC")


def day_bounds(tz: ZoneInfo, day: date) -> tuple[datetime, datetime]:
    """[local midnight of [day], local midnight of the next day) in UTC."""
    nxt = day + timedelta(days=1)
    lo = datetime(day.year, day.month, day.day, tzinfo=tz).astimezone(timezone.utc)
    hi = datetime(nxt.year, nxt.month, nxt.day, tzinfo=tz).astimezone(timezone.utc)
    return lo, hi


def local_day(tz: ZoneInfo, at: datetime | None = None) -> date:
    """The farm day an instant falls on (now when not given)."""
    return (ensure_utc(at) if at is not None else datetime.now(timezone.utc)).astimezone(tz).date()


def today(db: Session, farm_id: str) -> date:
    return local_day(farm_tz(db, farm_id))


def farm_day(db: Session, farm_id: str, day: date | None = None) -> tuple[date, datetime, datetime]:
    """(the day, lo, hi) — today by default."""
    tz = farm_tz(db, farm_id)
    day = day or local_day(tz)
    lo, hi = day_bounds(tz, day)
    return day, lo, hi


def last_days(db: Session, farm_id: str, days: int, *, end: date | None = None) -> tuple[date, date, datetime, datetime]:
    """The last [days] farm days ending on [end] (today), both included:
    (first day, last day, lo, hi)."""
    tz = farm_tz(db, farm_id)
    end = end or local_day(tz)
    start = end - timedelta(days=max(days, 1) - 1)
    lo, _ = day_bounds(tz, start)
    _, hi = day_bounds(tz, end)
    return start, end, lo, hi


def complete_days(db: Session, farm_id: str, days: int) -> tuple[date, date, datetime, datetime]:
    """The last [days] whole farm days before today (yesterday and back):
    a daily average that a half-finished today would pull down."""
    end = today(db, farm_id) - timedelta(days=1)
    return last_days(db, farm_id, days, end=end)


# The farm's clock on a tablet (audit I-16, ADR-008): a tablet set to
# another zone, or offline for months, reads the farm's hour from these.
_CLOCK_DAYS_BACK = 2
_CLOCK_DAYS_AHEAD = 400


def _offset_minutes(tz: ZoneInfo, at: datetime) -> int:
    off = at.astimezone(tz).utcoffset()
    return int(off.total_seconds() // 60) if off is not None else 0


def clock(tz: ZoneInfo, *, at: datetime | None = None) -> dict:
    """The farm's time zone and its offset from UTC from two days ago to
    400 days ahead: the offset then, and one entry for each change
    (daylight saving), from the UTC minute it takes effect."""
    start = (ensure_utc(at) if at is not None else datetime.now(timezone.utc)).replace(second=0, microsecond=0) - timedelta(days=_CLOCK_DAYS_BACK)
    current = _offset_minutes(tz, start)
    offsets = [{"from": start.isoformat(), "offset_minutes": current}]
    day = start
    end = start + timedelta(days=_CLOCK_DAYS_BACK + _CLOCK_DAYS_AHEAD)
    while day < end:
        nxt = day + timedelta(days=1)
        if _offset_minutes(tz, nxt) != current:
            lo, hi = day, nxt  # lo has the old offset, hi the new: the first minute of the new one
            while hi - lo > timedelta(minutes=1):
                mid = lo + timedelta(minutes=((hi - lo) // timedelta(minutes=1)) // 2)
                if _offset_minutes(tz, mid) == current:
                    lo = mid
                else:
                    hi = mid
            current = _offset_minutes(tz, hi)
            offsets.append({"from": hi.isoformat(), "offset_minutes": current})
        day = nxt
    return {"timezone": tz.key, "offsets": offsets}
