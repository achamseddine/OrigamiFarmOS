"""Contradictions a record must not be able to state (review of the whole
workflow on a fresh farm; handbook/03-Behavioral-Model.md §13–§14,
architecture/API-STANDARDS.md "Record consistency").

* A fact is not dated in the future — on the server, not only in the
  tablet's calendar.
* Milk belongs to an animal that is in milk; records stop when an animal
  leaves the farm.
* A raw ingredient is not fed directly; a mix does not contain feed that
  had not arrived yet.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from tests.conftest import auth_headers

API = "/api/v1"
FARM = "farm-origami"
BELLA, THUNDER, HERD, LAYERS = "cow-744", "horse-h07", "grp-dairy-herd", "flock-layer"
ALFALFA, BARLEY = "fp-alfalfa", "fp-barley"


def _h(client, email="rami@origami.farm"):
    return auth_headers(client, email)


def _at(days: float = 0) -> str:
    """ISO time [days] ago; negative is in the future."""
    return (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()


def _cow(client, name: str, **extra) -> dict:
    r = client.post(f"{API}/animals", json={"name": name, "species": "cow", "sex": "F", "life_stage": "adult", "management_profile": "dairy", **extra},
                    headers=_h(client))
    assert r.status_code == 201, r.text
    return r.json()


def _refused(r, *words: str, code: int = 422) -> None:
    assert r.status_code == code, r.text
    detail = str(r.json()["detail"]).lower()
    for w in words:
        assert w.lower() in detail, r.text


# ------------------------------------------------------------ nothing from the future
def test_no_record_is_dated_in_the_future(client):
    h = _h(client)
    future = _at(-2)
    _refused(client.post(f"{API}/animals", json={"name": "Tomorrow", "species": "cow", "sex": "F", "birth_date": future}, headers=h), "birth date", "future")
    _refused(client.put(f"{API}/animals/{BELLA}", json={"name": "Bella", "species": "cow", "birth_date": future}, headers=h), "birth date", "future")
    _refused(client.post(f"{API}/production/milk", json={"animal_id": BELLA, "session": "evening", "liters": 9, "recorded_at": future}, headers=h), "milk", "future")
    _refused(client.post(f"{API}/production/eggs", json={"flock_id": LAYERS, "total_eggs": 30, "sellable_eggs": 30, "recorded_at": future}, headers=h), "future")
    _refused(client.post(f"{API}/feeding-events", json={"subject_type": "animal", "subject_id": THUNDER, "occurred_at": future,
                                                        "components": [{"feed_product_id": ALFALFA, "quantity_offered": 3}]}, headers=h), "feeding", "future")
    _refused(client.post(f"{API}/feed-lots/receive", json={"feed_product_id": BARLEY, "quantity": 100, "received_at": future}, headers=h), "delivery", "future")
    _refused(client.post(f"{API}/feed-mixes", json={"new_product_name": "Tomorrow's mix", "produced_at": future,
                                                    "components": [{"feed_product_id": BARLEY, "actual_quantity": 50}]}, headers=h), "mix", "future")
    _refused(client.post(f"{API}/observations", json={"farm_id": FARM, "entity_type": "animal", "entity_id": BELLA, "observation_type": "limping",
                                                      "observer_id": "user-rami", "observed_at": future}, headers=h), "observation", "future")
    field = client.post(f"{API}/fields", json={"name": "South plot"}, headers=h).json()
    _refused(client.post(f"{API}/production/harvest", json={"field_id": field["id"], "product_name": "Tomato", "quantity": 80, "recorded_at": future}, headers=h),
             "harvest", "future")
    _refused(client.post(f"{API}/production/harvest", json={"field_id": field["id"], "product_name": "Tomato", "quantity": 80, "waste_qty": 90}, headers=h), "waste")


def test_an_animal_does_not_arrive_before_it_is_born(client):
    r = client.post(f"{API}/animals", json={"name": "Early", "species": "cow", "sex": "F", "birth_date": _at(100), "acquisition_date": _at(200)}, headers=_h(client))
    _refused(r, "acquisition", "birth")


# ------------------------------------------------------------ milk
def test_milk_needs_an_animal_in_milk_a_known_session_and_a_plausible_amount(client):
    h = _h(client)
    dry = _cow(client, "Dalia")
    r = client.post(f"{API}/production/milk", json={"animal_id": dry["id"], "session": "morning", "liters": 8}, headers=h)
    _refused(r, "not recorded as being milked", "start her milking", code=409)
    # Starting her milking is the one step that makes the milk record valid.
    assert client.post(f"{API}/animals/{dry['id']}/lactations", json={}, headers=h).status_code == 201
    assert client.post(f"{API}/production/milk", json={"animal_id": dry["id"], "session": "morning", "liters": 8}, headers=h).status_code == 201

    fresh = _cow(client, "Farah", lactating=True, lactation_started_at=_at(20))
    _refused(client.post(f"{API}/production/milk", json={"animal_id": fresh["id"], "session": "evening", "liters": 9, "recorded_at": _at(40)}, headers=h),
             "started this lactation", "calving date")
    _refused(client.post(f"{API}/production/milk", json={"animal_id": fresh["id"], "session": "noon", "liters": 9}, headers=h), "session")
    _refused(client.post(f"{API}/production/milk", json={"animal_id": fresh["id"], "session": "evening", "liters": 185}, headers=h), "check the amount")
    assert client.post(f"{API}/production/milk", json={"animal_id": fresh["id"], "session": "midday", "liters": 18.5}, headers=h).status_code == 201


# ------------------------------------------------------------ after an animal left
def test_nothing_is_recorded_on_an_animal_that_left_the_farm(client):
    h = _h(client)
    cow = _cow(client, "Salma", lactating=True)
    assert client.post(f"{API}/animals/{cow['id']}/exit", json={"exit_type": "sold", "reason": "market"}, headers=h).status_code == 200
    gone = "no longer on the farm"
    _refused(client.post(f"{API}/animals/{cow['id']}/weights", json={"weight_kg": 520}, headers=h), gone, code=409)
    _refused(client.post(f"{API}/health/cases", json={"subject_type": "animal", "subject_id": cow["id"]}, headers=h), gone, code=409)
    _refused(client.post(f"{API}/health/treatments", json={"entity_type": "animal", "entity_id": cow["id"], "medication": "Oxytetracycline", "dose": "10 ml",
                                                           "route": "IM", "responsible_user_id": "user-rami"}, headers=h), gone, code=409)
    _refused(client.post(f"{API}/observations", json={"farm_id": FARM, "entity_type": "animal", "entity_id": cow["id"], "observation_type": "limping",
                                                      "observer_id": "user-rami"}, headers=h), gone, code=409)
    _refused(client.post(f"{API}/production/milk", json={"animal_id": cow["id"], "session": "morning", "liters": 5}, headers=h), gone, code=409)
    _refused(client.post(f"{API}/animals/{cow['id']}/exit", json={"exit_type": "dead"}, headers=h), "already left", code=409)


# ------------------------------------------------------------ feed
def test_an_ingredient_is_not_fed_directly_and_a_cost_is_not_negative(client):
    h = _h(client)
    corn = client.post(f"{API}/feed-products", json={"name": "Corn grain", "unit": "kg", "is_ingredient": True, "is_feedable": False,
                                                    "category": "concentrate"}, headers=h).json()
    _refused(client.post(f"{API}/feed-lots/receive", json={"feed_product_id": corn["id"], "quantity": 500, "unit_cost": -1}, headers=h), "unit_cost")
    assert client.post(f"{API}/feed-lots/receive", json={"feed_product_id": corn["id"], "quantity": 500, "unit_cost": 0.3}, headers=h).status_code == 201
    r = client.post(f"{API}/feeding-events", json={"subject_type": "animal", "subject_id": BELLA, "event_type": "offered",
                                                   "components": [{"feed_product_id": corn["id"], "quantity_offered": 2}]}, headers=h)
    _refused(r, "ingredient", "mix")


def test_a_mix_cannot_use_feed_that_had_not_arrived_yet(client):
    h = _h(client)
    corn = client.post(f"{API}/feed-products", json={"name": "Corn grain", "unit": "kg", "is_ingredient": True, "is_feedable": False,
                                                    "category": "concentrate"}, headers=h).json()
    assert client.post(f"{API}/feed-lots/receive", json={"feed_product_id": corn["id"], "quantity": 800, "received_at": _at(3)}, headers=h).status_code == 201
    body = {"new_product_name": "Heifer mix", "components": [{"feed_product_id": corn["id"], "actual_quantity": 200}]}
    _refused(client.post(f"{API}/feed-mixes", json={**body, "produced_at": _at(10)}, headers=h), "had not arrived yet", "corn grain")
    # Nothing was drawn by the refused mix: the ledger is untouched.
    stock = next(p for p in client.get(f"{API}/feed-products", headers=h).json() if p["id"] == corn["id"])
    assert stock["availability"]["on_hand"] == 800
    ok = client.post(f"{API}/feed-mixes", json={**body, "produced_at": _at(1)}, headers=h)
    assert ok.status_code == 201, ok.text


# ------------------------------------------------------------ tasks and head counts
def test_a_task_needs_a_title_and_is_not_written_down_twice(client):
    h = _h(client)
    _refused(client.post(f"{API}/tasks", json={"farm_id": FARM, "title": "   "}, headers=h), "title")
    task = {"farm_id": FARM, "title": "Mend the north fence"}
    assert client.post(f"{API}/tasks", json=task, headers=h).status_code == 201
    again = client.post(f"{API}/tasks", json={**task, "title": "mend the North fence"}, headers=h)
    assert again.status_code == 409 and again.json()["detail"].startswith("Possible duplicate:"), again.text
    assert client.post(f"{API}/tasks", json={**task, "confirm_duplicate": True}, headers=h).status_code == 201


def test_the_same_flock_loss_counted_twice_is_asked(client):
    h = _h(client)
    before = next(g for g in client.get(f"{API}/animal-groups", headers=h).json() if g["id"] == LAYERS)["count"]
    loss = {"event_type": "DEATH", "quantity_delta": -2}
    assert client.post(f"{API}/animal-groups/{LAYERS}/quantity-events", json=loss, headers=h).status_code == 201
    again = client.post(f"{API}/animal-groups/{LAYERS}/quantity-events", json=loss, headers=h)
    assert again.status_code == 409 and again.json()["detail"].startswith("Possible duplicate:"), again.text
    assert next(g for g in client.get(f"{API}/animal-groups", headers=h).json() if g["id"] == LAYERS)["count"] == before - 2


# ------------------------------------------------------------ one key, asked then confirmed
def test_a_confirmed_resend_reuses_the_key_of_the_refused_write(client):
    """The tablet resends a refused "Possible duplicate" with the same
    Idempotency-Key: the refusal was not remembered, the confirmed write is,
    and a replay of it records nothing more."""
    h = {**_h(client), "Idempotency-Key": "review-confirm-1"}
    body = {"animal_id": BELLA, "session": "evening", "liters": 6.5}
    assert client.post(f"{API}/production/milk", json={**body, "confirm_duplicate": True}, headers=_h(client)).status_code == 201
    asked = client.post(f"{API}/production/milk", json=body, headers=h)
    assert asked.status_code == 409
    confirmed = client.post(f"{API}/production/milk", json={**body, "confirm_duplicate": True}, headers=h)
    assert confirmed.status_code == 201 and confirmed.headers.get("Idempotency-Replayed") is None
    replay = client.post(f"{API}/production/milk", json={**body, "confirm_duplicate": True}, headers=h)
    assert replay.headers.get("Idempotency-Replayed") == "true" and replay.json()["id"] == confirmed.json()["id"]
