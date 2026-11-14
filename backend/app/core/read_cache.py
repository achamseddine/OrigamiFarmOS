"""A per-session read cache for the farm-wide computations a single request
repeats many times — the active feeding-program versions with their rules,
the assignments of every subject, the week's milk per animal.

Lives in `Session.info`, so it never outlives one request's session, and is
dropped the moment anything is written (after a flush that wrote rows,
after a commit or a rollback): a cached value is only ever read back within
the same unchanged state of the database. Reads that cannot be cached
safely simply do not use it.
"""
from __future__ import annotations

from collections.abc import Callable
from typing import TypeVar

from sqlalchemy import event
from sqlalchemy.orm import Session

_KEY = "_read_cache"
T = TypeVar("T")


def cached(db: Session, key: tuple, loader: Callable[[], T]) -> T:
    cache = db.info.setdefault(_KEY, {})
    if key not in cache:
        cache[key] = loader()
    return cache[key]


def peek(db: Session, key: tuple):
    """The cached value, or None (no load)."""
    return db.info.get(_KEY, {}).get(key)


def put(db: Session, key: tuple, value) -> None:
    db.info.setdefault(_KEY, {})[key] = value


def clear(db: Session) -> None:
    db.info.pop(_KEY, None)


@event.listens_for(Session, "after_flush")
def _after_flush(session: Session, _flush_context) -> None:
    clear(session)


@event.listens_for(Session, "after_commit")
def _after_commit(session: Session) -> None:
    clear(session)


@event.listens_for(Session, "after_rollback")
def _after_rollback(session: Session) -> None:
    clear(session)
