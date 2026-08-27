"""A queued write replayed from a tablet must not record the work twice.

These exercise the scenario the outbox creates: the tablet sends a write,
the response is lost, and the tablet — unable to tell "never arrived"
from "arrived, answer lost" — sends the identical request again with the
same `Idempotency-Key`.
"""
from __future__ import annotations

from sqlalchemy import select

from app.core.idempotency import HEADER, REPLAYED_HEADER
from app.domain import models

from .conftest import auth_headers


def _farm_id(session) -> str:
    return session.scalars(select(models.Farm)).first().id


def _first_cow(session) -> models.Animal:
    return session.scalars(select(models.Animal).where(models.Animal.species == "cow")).first()


def test_replayed_write_returns_the_original_response_and_records_once(client, db_session):
    session, _ = db_session
    headers = auth_headers(client)
    animal = _first_cow(session)
    body = {"animal_id": animal.id, "session": "morning", "liters": 12.5, "destination": "stored"}
    key = {HEADER: "outbox-milk-0001"}

    first = client.post("/api/v1/production/milk", json=body, headers={**headers, **key})
    assert first.status_code in (200, 201), first.text

    second = client.post("/api/v1/production/milk", json=body, headers={**headers, **key})
    assert second.status_code == first.status_code
    assert second.headers.get(REPLAYED_HEADER) == "true"
    assert second.json() == first.json()

    session.expire_all()
    records = session.scalars(
        select(models.MilkRecord).where(models.MilkRecord.animal_id == animal.id)
    ).all()
    assert len([r for r in records if r.liters == 12.5]) == 1


def test_a_different_key_records_a_second_entry(client, db_session):
    """Two genuine milkings must still both land — the guard keys on the
    tablet's key, not on the payload looking familiar."""
    session, _ = db_session
    headers = auth_headers(client)
    animal = _first_cow(session)
    body = {"animal_id": animal.id, "session": "evening", "liters": 9.25, "destination": "stored"}

    client.post("/api/v1/production/milk", json=body, headers={**headers, HEADER: "outbox-a"})
    client.post("/api/v1/production/milk", json=body, headers={**headers, HEADER: "outbox-b"})

    session.expire_all()
    records = session.scalars(
        select(models.MilkRecord).where(models.MilkRecord.animal_id == animal.id)
    ).all()
    assert len([r for r in records if r.liters == 9.25]) == 2


def test_writes_without_a_key_are_untouched(client, db_session):
    session, _ = db_session
    headers = auth_headers(client)
    animal = _first_cow(session)
    body = {"animal_id": animal.id, "session": "morning", "liters": 3.5, "destination": "consumed"}

    client.post("/api/v1/production/milk", json=body, headers=headers)
    client.post("/api/v1/production/milk", json=body, headers=headers)

    session.expire_all()
    records = session.scalars(
        select(models.MilkRecord).where(models.MilkRecord.animal_id == animal.id)
    ).all()
    assert len([r for r in records if r.liters == 3.5]) == 2


def test_rejected_writes_are_not_remembered(client, db_session):
    """A 4xx must stay retryable: the tablet may be replaying a write that
    was refused because a permission had not been granted yet, and the
    manager may have granted it since."""
    session, _ = db_session
    headers = auth_headers(client)
    key = {HEADER: "outbox-bad-animal"}
    body = {"animal_id": "no-such-animal", "session": "morning", "liters": 1.0, "destination": "stored"}

    first = client.post("/api/v1/production/milk", json=body, headers={**headers, **key})
    assert first.status_code >= 400

    stored = session.scalars(
        select(models.IdempotencyRecord).where(models.IdempotencyRecord.idempotency_key == "outbox-bad-animal")
    ).all()
    assert stored == []

    second = client.post("/api/v1/production/milk", json=body, headers={**headers, **key})
    assert second.headers.get(REPLAYED_HEADER) is None


def test_a_key_is_scoped_to_the_user_who_sent_it(client, db_session):
    """Two tablets picking the same key must not read each other's
    responses — the key alone is not a capability."""
    session, _ = db_session
    manager = auth_headers(client)
    animal = _first_cow(session)
    key = {HEADER: "shared-key"}

    first = client.post(
        "/api/v1/production/milk",
        json={"animal_id": animal.id, "session": "morning", "liters": 7.0, "destination": "stored"},
        headers={**manager, **key},
    )
    assert first.status_code in (200, 201), first.text

    other = auth_headers(client, email="karim.worker@origami.farm", password="farmos123")
    second = client.post(
        "/api/v1/production/milk",
        json={"animal_id": animal.id, "session": "evening", "liters": 8.0, "destination": "stored"},
        headers={**other, **key},
    )
    assert second.headers.get(REPLAYED_HEADER) is None
    assert second.status_code in (200, 201, 403), second.text
