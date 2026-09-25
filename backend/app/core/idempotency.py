"""Replay protection for writes queued on an offline tablet.

A field tablet that loses the farm network queues the write it was making
and sends it again later. Two things can then go wrong, and this module
handles both:

* the request never arrived, so the replay must be *performed* — the
  normal case, and nothing here interferes with it;
* the request arrived and committed, but the response never made it back
  (the connection dropped at exactly the wrong moment, or the tablet
  slept mid-request). The tablet cannot tell those apart, so it replays,
  and without this the farm would have two milk records for one milking.

The tablet sends the same `Idempotency-Key` on the first attempt and on
every replay of the same logical write. The first completed attempt is
recorded here with its response; any later request carrying that key is
answered with the stored response instead of touching the database.

Implemented as middleware rather than a per-endpoint dependency
deliberately: it must hold for every write the tablet can queue, present
and future, without each new endpoint having to remember to opt in.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone

from fastapi import Request, Response
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse

from app.core.security import decode_access_token
from app.db.base import SessionLocal
from app.domain import models

HEADER = "Idempotency-Key"
REPLAYED_HEADER = "Idempotency-Replayed"

MUTATING_METHODS = frozenset({"POST", "PUT", "PATCH", "DELETE"})

# Big enough for any response this API returns to a single write, small
# enough that a runaway body can't fill the table. A response over this
# is still *executed* once — only the stored copy is skipped, so a replay
# of it re-runs rather than silently returning nothing.
MAX_STORED_BODY = 256_000


class IdempotencyMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        key = request.headers.get(HEADER)
        if not key or request.method not in MUTATING_METHODS:
            return await call_next(request)

        user_id = _user_id_from(request)
        if user_id is None:
            # Unauthenticated writes (login) are never queued by the
            # tablet, and keying them by user is impossible anyway.
            return await call_next(request)

        session_factory = _session_factory_for(request)

        stored = _load(session_factory, key, user_id)
        if stored is not None:
            return _replayed_response(stored)

        response = await call_next(request)

        # Only successful writes are remembered. A 4xx/5xx replay should
        # get a fresh attempt — the permission may have been granted, or
        # the server may have recovered, since the tablet gave up.
        if 200 <= response.status_code < 300:
            body = await _read_body(response)
            _remember(session_factory, key, user_id, request, response.status_code, body)
            return _rebuilt_response(response, body)

        return response


def _session_factory_for(request: Request):
    """The middleware runs outside the request's dependency graph, so it
    opens its own session. Tests point it at their throwaway database by
    setting `app.state.idempotency_session_factory`."""
    return getattr(request.app.state, "idempotency_session_factory", None) or SessionLocal


def _user_id_from(request: Request) -> str | None:
    header = request.headers.get("Authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token:
        return None
    payload = decode_access_token(token)
    if payload is None:
        return None
    subject = payload.get("sub")
    return str(subject) if subject else None


def _load(session_factory, key: str, user_id: str) -> models.IdempotencyRecord | None:
    db = session_factory()
    try:
        return db.scalar(
            select(models.IdempotencyRecord).where(
                models.IdempotencyRecord.idempotency_key == key,
                models.IdempotencyRecord.user_id == user_id,
            )
        )
    except Exception:  # noqa: BLE001 - never let bookkeeping break a write
        return None
    finally:
        db.close()


def _remember(session_factory, key: str, user_id: str, request: Request, status_code: int, body: bytes) -> None:
    if len(body) > MAX_STORED_BODY:
        return
    db = session_factory()
    try:
        db.add(
            models.IdempotencyRecord(
                idempotency_key=key,
                user_id=user_id,
                method=request.method,
                path=request.url.path,
                status_code=status_code,
                response_body=body.decode("utf-8", errors="replace"),
                created_at=datetime.now(timezone.utc),
            )
        )
        db.commit()
    except IntegrityError:
        # Two replays of the same key raced. Whichever inserted first
        # wins; the write itself already ran once per the unique
        # constraint's protection on the *next* attempt.
        db.rollback()
    except Exception:  # noqa: BLE001
        db.rollback()
    finally:
        db.close()


def _replayed_response(record: models.IdempotencyRecord) -> Response:
    raw = record.response_body or ""
    headers = {REPLAYED_HEADER: "true"}
    if not raw:
        return Response(status_code=record.status_code, headers=headers)
    try:
        return JSONResponse(content=json.loads(raw), status_code=record.status_code, headers=headers)
    except json.JSONDecodeError:
        return Response(content=raw, status_code=record.status_code, headers=headers)


async def _read_body(response: Response) -> bytes:
    chunks = [chunk async for chunk in response.body_iterator]  # type: ignore[attr-defined]
    return b"".join(chunk if isinstance(chunk, bytes) else chunk.encode("utf-8") for chunk in chunks)


def _rebuilt_response(response: Response, body: bytes) -> Response:
    """The streaming body was consumed to store it, so hand back a plain
    response carrying the same bytes, status and headers."""
    headers = dict(response.headers)
    headers.pop("content-length", None)
    return Response(
        content=body,
        status_code=response.status_code,
        headers=headers,
        media_type=response.media_type,
    )
