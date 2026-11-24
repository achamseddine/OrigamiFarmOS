"""Each cow's number in the milking queue (v0.8.2).

The farm milks its cows in the same order every time. The manager gives
each animal in milk her number in that line; the queue on the tablet and
the web follows it, and the manual milk entry opens the next number after
each save.

* Only an animal on the farm that can be milked gets a number.
* No two animals on the farm hold the same number.
* Animals not named keep theirs; sending the same numbers again changes
  nothing (safe to retry from the offline queue).
* Each change is audited and is an event.
"""
from __future__ import annotations

from datetime import date, timedelta

from sqlalchemy import select

from app.domain import models
from tests.conftest import auth_headers

API = "/api/v1"


def _put(client, headers, *pairs):
    return client.put(f"{API}/animals/milking-queue", json={"numbers": [{"animal_id": a, "number": n} for a, n in pairs]}, headers=headers)


def _numbers(client, headers):
    return {a["id"]: a["milking_queue_number"] for a in client.get(f"{API}/animals?farm_id=farm-origami", headers=headers).json()}


def test_the_manager_numbers_the_cows_and_the_herd_list_carries_them(client):
    manager = auth_headers(client)
    r = _put(client, manager, ("cow-744", 1), ("cow-214", 2), ("cow-clover", 3), ("goat-gigi", 4))
    assert r.status_code == 200, r.text
    assert {a["id"]: a["milking_queue_number"] for a in r.json()} == {"cow-744": 1, "cow-214": 2, "cow-clover": 3, "goat-gigi": 4}
    numbers = _numbers(client, manager)
    assert (numbers["cow-744"], numbers["cow-214"], numbers["cow-clover"], numbers["goat-gigi"]) == (1, 2, 3, 4)
    assert numbers["horse-h07"] is None, "an animal not named has no number"


def test_numbers_are_unique_on_the_farm(client):
    manager = auth_headers(client)
    assert _put(client, manager, ("cow-744", 1), ("cow-214", 2)).status_code == 200
    r = _put(client, manager, ("cow-clover", 2))
    assert r.status_code == 409
    assert "Luna" in r.json()["detail"] and "Clover" in r.json()["detail"]
    # Swapping two cows in one go is fine: the numbers are checked once applied.
    r = _put(client, manager, ("cow-744", 2), ("cow-214", 1))
    assert r.status_code == 200, r.text
    numbers = _numbers(client, manager)
    assert (numbers["cow-744"], numbers["cow-214"]) == (2, 1)


def test_taking_a_number_away_and_sending_the_same_numbers_again(client, db_session):
    session, _ = db_session
    manager = auth_headers(client)
    assert _put(client, manager, ("cow-744", 1), ("cow-214", 2)).status_code == 200
    again = _put(client, manager, ("cow-744", 1), ("cow-214", 2))
    assert again.status_code == 200 and again.json() == [], "nothing changed: a retry is harmless"
    r = _put(client, manager, ("cow-214", None))
    assert r.status_code == 200 and [a["id"] for a in r.json()] == ["cow-214"]
    assert _numbers(client, manager)["cow-214"] is None
    events = session.scalars(select(models.Event).where(models.Event.event_type == "milking_queue_number_set", models.Event.entity_id == "cow-214")).all()
    assert [e.payload_json for e in sorted(events, key=lambda e: e.created_at)] == [{"from": None, "to": 2}, {"from": 2, "to": None}]
    audits = session.scalars(select(models.AuditLog).where(models.AuditLog.action == "milking_queue_number_set", models.AuditLog.entity_id == "cow-214")).all()
    assert len(audits) == 2


def test_only_an_animal_that_is_milked_gets_a_number(client):
    manager = auth_headers(client)
    r = _put(client, manager, ("horse-h07", 5))
    assert r.status_code == 422
    assert "Thunder" in r.json()["detail"]
    assert _put(client, manager, ("hen-247", 6)).status_code == 422
    assert _put(client, manager, ("not-an-animal", 1)).status_code == 404


def test_bad_numbers_are_refused(client):
    manager = auth_headers(client)
    assert _put(client, manager, ("cow-744", 0)).status_code == 422
    assert _put(client, manager, ("cow-744", 1000)).status_code == 422
    assert _put(client, manager, ("cow-744", 1), ("cow-744", 2)).status_code == 422, "each animal once"
    assert client.put(f"{API}/animals/milking-queue", json={"numbers": []}, headers=manager).status_code == 422


def test_an_animal_that_left_the_farm_holds_no_number(client, db_session):
    session, _ = db_session
    manager = auth_headers(client)
    assert _put(client, manager, ("cow-clover", 3)).status_code == 200
    clover = session.get(models.Animal, "cow-clover")
    clover.active = False
    clover.lifecycle_status = "sold"
    session.commit()
    # Her old number is free for another cow; she cannot be given one.
    assert _put(client, manager, ("cow-214", 3)).status_code == 200
    assert _put(client, manager, ("cow-clover", 4)).status_code == 409


def test_the_order_is_the_managers(client, db_session):
    session, _ = db_session
    # A worker who milks but may neither edit the animals nor approve in Milk.
    for row in session.scalars(select(models.UserModulePermission).where(models.UserModulePermission.user_id == "user-worker-1")):
        if row.module_code == "animals":
            row.can_edit = False
        if row.module_code == "milk_production":
            row.can_approve = False
    session.commit()
    r = _put(client, auth_headers(client, "karim.worker@origami.farm"), ("cow-744", 1))
    assert r.status_code == 403


# ------------------------------------------------- the milk report per cow
def _milk(client, headers, animal_id, session, liters):
    r = client.post(f"{API}/production/milk", json={"animal_id": animal_id, "session": session, "liters": liters, "destination": "stored",
                                                         "confirm_duplicate": True}, headers=headers)
    assert r.status_code == 201, r.text


def test_the_milk_report_shows_each_cow_morning_and_afternoon(client):
    manager = auth_headers(client)
    today = client.get(f"{API}/reports/milk", headers=manager).json()["end"]
    before = {a["animal_id"]: a for a in client.get(f"{API}/reports/milk?start={today}&end={today}", headers=manager).json()["by_animal"]}
    _milk(client, manager, "cow-214", "morning", 11)
    _milk(client, manager, "cow-214", "evening", 9)
    _milk(client, manager, "cow-clover", "morning", 14)
    assert _put(client, manager, ("cow-clover", 1), ("cow-214", 2)).status_code == 200
    report = client.get(f"{API}/reports/milk?start={today}&end={today}", headers=manager).json()
    luna = next(a for a in report["by_animal"] if a["animal_id"] == "cow-214")
    base = before.get("cow-214", {"morning_l": 0, "evening_l": 0})
    assert (luna["morning_l"] - base["morning_l"], luna["evening_l"] - base["evening_l"]) == (11, 9)
    assert luna["queue_number"] == 2
    # The day's sheet: each cow's morning and afternoon, in queue order.
    sheet = [r for r in report["by_animal_day"] if r["date"] == today]
    ids = [r["animal_id"] for r in sheet]
    assert ids.index("cow-clover") < ids.index("cow-214"), "number 1 before number 2"
    clover = next(r for r in sheet if r["animal_id"] == "cow-clover")
    assert clover["morning_l"] >= 14 and clover["total_l"] == round(clover["morning_l"] + clover["midday_l"] + clover["evening_l"], 1)
    # A long period keeps the totals per cow, without the day-by-day sheet.
    start = (date.fromisoformat(today) - timedelta(days=59)).isoformat()
    long = client.get(f"{API}/reports/milk?start={start}&end={today}", headers=manager).json()
    assert long["by_animal_day"] is None
    assert all("morning_l" in a and "evening_l" in a for a in long["by_animal"])
