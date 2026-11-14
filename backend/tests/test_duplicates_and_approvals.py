"""The same fact entered twice, and who may approve an exception
(app/core/duplicates.py; architecture/API-STANDARDS.md "Duplicate entries";
handbook/03-Behavioral-Model.md §5, §13).

* A record that says what an existing one already says is refused with 409
  "Possible duplicate: …"; resent with `confirm_duplicate: true` it is
  recorded, and the event log says what it resembles.
* A repeat that can never be right (a group, field, feed or raw material
  of the same name; a lot code already used) is a plain 409 — no override.
* Taking stock below the ledger, activating a recipe and changing the farm
  calendar need *approve* / *configure*, not just *create*.
"""
from __future__ import annotations

from sqlalchemy import select

from app.core.duplicates import PREFIX
from app.domain import models
from tests.conftest import auth_headers

API = "/api/v1"
FARM = "farm-origami"
BELLA, LUNA, THUNDER = "cow-744", "cow-214", "horse-h07"
ALFALFA, BARLEY = "fp-alfalfa", "fp-barley"
WORKER = "karim.worker@origami.farm"


def _h(client, email="rami@origami.farm"):
    return auth_headers(client, email)


def _is_possible_duplicate(r) -> bool:
    return r.status_code == 409 and r.json()["detail"].startswith(PREFIX)


def _confirmed(session, entity_id: str) -> list[models.Event]:
    session.expire_all()
    return list(session.scalars(select(models.Event).where(models.Event.entity_id == entity_id,
                                                           models.Event.event_type == "duplicate_confirmed")))


# ------------------------------------------------------------ possible duplicates
def test_the_same_milking_twice_in_a_day_is_asked_then_recorded_and_logged(client, db_session):
    session, _ = db_session
    h = _h(client)
    body = {"animal_id": LUNA, "session": "evening", "liters": 7.5, "destination": "stored", "confirm_duplicate": True}
    assert client.post(f"{API}/production/milk", json=body, headers=h).status_code == 201

    again = client.post(f"{API}/production/milk", json={**body, "confirm_duplicate": False, "liters": 7.0}, headers=h)
    assert _is_possible_duplicate(again), again.text
    assert "evening" in again.json()["detail"]

    confirmed = client.post(f"{API}/production/milk", json={**body, "liters": 7.0}, headers=h)
    assert confirmed.status_code == 201, confirmed.text
    assert any(e.payload_json.get("resembles") for e in _confirmed(session, LUNA))


def test_the_same_feeding_round_twice_is_asked(client):
    h = _h(client)
    body = {"subject_type": "animal", "subject_id": THUNDER, "event_type": "offered",
            "components": [{"feed_product_id": ALFALFA, "quantity_offered": 4.5}]}
    assert client.post(f"{API}/feeding-events", json=body, headers=h).status_code == 201
    again = client.post(f"{API}/feeding-events", json=body, headers=h)
    assert _is_possible_duplicate(again), again.text
    # A different quantity is a different round.
    assert client.post(f"{API}/feeding-events", json={**body, "components": [{"feed_product_id": ALFALFA, "quantity_offered": 2}]},
                       headers=h).status_code == 201
    assert client.post(f"{API}/feeding-events", json={**body, "confirm_duplicate": True}, headers=h).status_code == 201


def test_a_delivery_note_typed_in_twice_is_asked_and_a_used_lot_code_is_refused(client):
    h = _h(client)
    body = {"feed_product_id": BARLEY, "quantity": 250, "unit_cost": 0.35, "supplier_label": "Bekaa Grain Co.", "reference": "DN-7781"}
    assert client.post(f"{API}/feed-lots/receive", json=body, headers=h).status_code == 201
    again = client.post(f"{API}/feed-lots/receive", json={**body, "quantity": 260}, headers=h)
    assert _is_possible_duplicate(again) and "DN-7781" in again.json()["detail"], again.text
    assert client.post(f"{API}/feed-lots/receive", json={**body, "confirm_duplicate": True}, headers=h).status_code == 201

    coded = {"feed_product_id": BARLEY, "quantity": 100, "lot_code": "BAR-DUP-01"}
    assert client.post(f"{API}/feed-lots/receive", json=coded, headers=h).status_code == 201
    reused = client.post(f"{API}/feed-lots/receive", json={**coded, "confirm_duplicate": True}, headers=h)
    assert reused.status_code == 409 and not reused.json()["detail"].startswith(PREFIX), "a lot code is never confirmed twice"


def test_a_mix_saved_twice_is_asked(client):
    h = _h(client)
    body = {"new_product_name": "Heifer mix", "components": [{"feed_product_id": BARLEY, "actual_quantity": 120}]}
    first = client.post(f"{API}/feed-mixes", json=body, headers=h)
    assert first.status_code == 201, first.text
    product_id = first.json()["feed_product_id"]
    again = client.post(f"{API}/feed-mixes", json={"feed_product_id": product_id, "components": body["components"]}, headers=h)
    assert _is_possible_duplicate(again), again.text
    confirmed = client.post(f"{API}/feed-mixes", json={"feed_product_id": product_id, "components": body["components"], "confirm_duplicate": True}, headers=h)
    assert confirmed.status_code == 201 and confirmed.json()["mix_number"] == first.json()["mix_number"] + 1
    # Typing the new feed's name again reuses it rather than making a second "Heifer mix".
    by_name = client.post(f"{API}/feed-mixes", json={**body, "components": [{"feed_product_id": BARLEY, "actual_quantity": 80}]}, headers=h)
    assert by_name.status_code == 201 and by_name.json()["feed_product_id"] == product_id


def test_names_that_must_stay_unique(client):
    h = _h(client)
    feed = {"name": "Corn grain", "unit": "kg", "is_ingredient": True, "is_feedable": False, "category": "concentrate"}
    assert client.post(f"{API}/feed-products", json=feed, headers=h).status_code == 201
    assert client.post(f"{API}/feed-products", json={**feed, "name": "corn GRAIN "}, headers=h).status_code == 409

    group = {"name": "Show heifers", "species": "cow"}
    first = client.post(f"{API}/animal-groups", json=group, headers=h)
    assert first.status_code == 201, first.text
    assert client.post(f"{API}/animal-groups", json={**group, "name": "show HEIFERS"}, headers=h).status_code == 409

    field = {"name": "North terrace", "area_value": 2, "area_unit": "dunum"}
    assert client.post(f"{API}/fields", json=field, headers=h).status_code == 201
    assert client.post(f"{API}/fields", json=field, headers=h).status_code == 409


def test_an_animal_with_the_same_name_is_asked(client):
    h = _h(client)
    body = {"name": "Noor", "species": "cow", "sex": "F", "management_profile": "dairy"}
    first = client.post(f"{API}/animals", json=body, headers=h)
    assert first.status_code == 201, first.text
    again = client.post(f"{API}/animals", json=body, headers=h)
    assert _is_possible_duplicate(again) and "Noor" in again.json()["detail"], again.text
    assert client.post(f"{API}/animals", json={**body, "confirm_duplicate": True}, headers=h).status_code == 201


def test_reproduction_health_and_observation_repeats_are_asked(client):
    h = _h(client)
    cow = client.post(f"{API}/animals", json={"name": "Rima", "species": "cow", "sex": "F", "management_profile": "dairy"}, headers=h).json()
    service = {"event_type": "ARTIFICIAL_INSEMINATION"}
    assert client.post(f"{API}/animals/{cow['id']}/breedings", json=service, headers=h).status_code == 201
    assert _is_possible_duplicate(client.post(f"{API}/animals/{cow['id']}/breedings", json=service, headers=h))
    assert client.post(f"{API}/animals/{cow['id']}/breedings", json={**service, "confirm_duplicate": True}, headers=h).status_code == 201

    weight = {"weight_kg": 512, "method": "scale"}
    assert client.post(f"{API}/animals/{cow['id']}/weights", json=weight, headers=h).status_code == 201
    assert _is_possible_duplicate(client.post(f"{API}/animals/{cow['id']}/weights", json=weight, headers=h))

    case = {"subject_type": "animal", "subject_id": cow["id"], "primary_problem_code": "LAMENESS"}
    assert client.post(f"{API}/health/cases", json=case, headers=h).status_code == 201
    dup_case = client.post(f"{API}/health/cases", json=case, headers=h)
    assert _is_possible_duplicate(dup_case) and "already open" in dup_case.json()["detail"]
    assert client.post(f"{API}/health/cases", json={**case, "primary_problem_code": "MASTITIS"}, headers=h).status_code == 201

    seen = {"farm_id": FARM, "entity_type": "animal", "entity_id": cow["id"], "observation_type": "limping", "severity": "mild",
            "observer_id": "user-worker-1"}
    worker = _h(client, WORKER)
    assert client.post(f"{API}/observations", json=seen, headers=worker).status_code == 201
    assert _is_possible_duplicate(client.post(f"{API}/observations", json=seen, headers=worker))


def test_a_mouneh_sale_typed_in_twice_is_asked(client):
    h = _h(client)
    sale = {"product_id": "prod-makdous", "quantity": 2, "unit_price": 6.5, "channel": "retail"}
    assert client.post(f"{API}/mouneh/sales", json=sale, headers=h).status_code == 201
    assert _is_possible_duplicate(client.post(f"{API}/mouneh/sales", json=sale, headers=h))
    assert client.post(f"{API}/mouneh/sales", json={**sale, "confirm_duplicate": True}, headers=h).status_code == 201


# ------------------------------------------------------------ approval levels
def test_only_an_approver_records_more_than_the_stock_on_record(client):
    worker, manager = _h(client, WORKER), _h(client)
    body = {"subject_type": "animal", "subject_id": THUNDER, "event_type": "offered", "allow_negative": True,
            "components": [{"feed_product_id": ALFALFA, "quantity_offered": 99999}]}
    refused = client.post(f"{API}/feeding-events", json=body, headers=worker)
    assert refused.status_code == 403 and "approval" in refused.json()["detail"], refused.text
    assert client.post(f"{API}/feeding-events", json=body, headers=manager).status_code == 201

    legacy = client.post(f"{API}/feed/transactions", json={"item_id": "inv-alfalfa", "direction": "out", "quantity": 99999, "unit": "kg",
                                                           "allow_negative": True}, headers=worker)
    assert legacy.status_code in (403, 404), legacy.text


def test_a_workers_recipe_is_a_draft_until_approved(client):
    worker = _h(client, WORKER)
    starter = client.post(f"{API}/feed-products", json={"name": "Calf starter", "unit": "kg", "source_type": "farm_produced",
                                                       "category": "concentrate"}, headers=_h(client)).json()
    body = {"name": "Calf starter", "feed_product_id": starter["id"], "batch_size": 100,
            "components": [{"feed_product_id": BARLEY, "target_quantity": 100}]}
    r = client.post(f"{API}/feed-formulas", json=body, headers=worker)
    assert r.status_code == 201, r.text
    assert r.json()["active_version"] is None and r.json()["versions"][0]["status"] != "active"


def test_a_worker_cannot_create_a_recipe_by_mixing_a_new_feed(client):
    worker, manager = _h(client, WORKER), _h(client)
    body = {"new_product_name": "Goat pellets", "components": [{"feed_product_id": BARLEY, "actual_quantity": 50}]}
    refused = client.post(f"{API}/feed-mixes", json=body, headers=worker)
    assert refused.status_code == 403 and "approved recipe" in refused.json()["detail"], refused.text
    made = client.post(f"{API}/feed-mixes", json=body, headers=manager)
    assert made.status_code == 201, made.text
    # Once the manager's first mix approved the recipe, the worker mixes it.
    again = client.post(f"{API}/feed-mixes", json={"feed_product_id": made.json()["feed_product_id"],
                                                   "components": [{"feed_product_id": BARLEY, "actual_quantity": 40}]}, headers=worker)
    assert again.status_code == 201, again.text


def test_a_poor_grade_delivery_is_held_until_released(client):
    r = client.post(f"{API}/feed-lots/receive", json={"feed_product_id": BARLEY, "quantity": 300, "quality_grade": "poor",
                                                     "quality_notes": "Wet sacks"}, headers=_h(client))
    assert r.status_code == 201, r.text
    assert r.json()["status"] == "quarantined"


def test_the_farm_calendar_needs_settings_configure(client, db_session):
    session, _ = db_session
    session.add(models.UserModulePermission(farm_id=FARM, user_id="user-worker-1", module_code="settings", can_view=True, can_create=True,
                                            can_edit=True))
    session.commit()
    worker = _h(client, WORKER)
    refused = client.patch(f"{API}/farms/me", json={"dry_off_days_before_birth": 30}, headers=worker)
    assert refused.status_code == 403, refused.text
    assert client.patch(f"{API}/farms/me", json={"dry_off_days_before_birth": 30}, headers=_h(client)).status_code == 200
