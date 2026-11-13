"""Registering without a scanned tag, pregnancy / milk answered at
registration, the farm's dry-off setting, and the standard feeds of the
animal feeding form (docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md §4,
docs/QR-ANIMAL-QUICK-ENTRY.md, database migration a8d0c2e4f6b1).
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.domain import feed_models as fm
from app.domain import reproduction_models as rm
from tests.conftest import auth_headers

API = "/api/v1"
BELLA = "cow-744"


def _h(client, email="rami@origami.farm"):
    return auth_headers(client, email)


def _register(client, h=None, **body):
    payload = {"name": "New cow", "species": "cow", "sex": "F", "life_stage": "adult", "management_profile": "dairy", **body}
    return client.post(f"{API}/animals", json=payload, headers=h or _h(client))


def _identifiers(client, animal_id, h=None):
    r = client.get(f"{API}/animals/{animal_id}/identifiers", headers=h or _h(client))
    assert r.status_code == 200, r.text
    return r.json()


# ------------------------------------------------------------ identity
def test_a_cow_registers_with_nothing_scanned_and_gets_a_farm_number(client):
    h = _h(client)
    r = _register(client, h)
    assert r.status_code == 201, r.text
    body = r.json()
    ids = _identifiers(client, body["id"], h)
    assert [i["identifier_type"] for i in ids] == ["FARM_NUMBER"]
    assert ids[0]["is_primary"] is True
    assert ids[0]["identifier_value"].isdigit() and len(ids[0]["identifier_value"]) >= 4
    assert body["tag"] == ids[0]["identifier_value"]


def test_farm_numbers_are_one_sequence_and_a_typed_tag_stays_primary(client):
    h = _h(client)
    first = _register(client, h, name="One").json()
    second = _register(client, h, name="Two", identifiers=[{"identifier_type": "EAR_TAG", "identifier_value": "LB-9911"}]).json()
    goat = client.post(f"{API}/animals", json={"name": "Kid", "species": "goat", "sex": "F"}, headers=h).json()
    n1 = int(next(i for i in _identifiers(client, first["id"], h) if i["identifier_type"] == "FARM_NUMBER")["identifier_value"])
    ids2 = _identifiers(client, second["id"], h)
    n2 = int(next(i for i in ids2 if i["identifier_type"] == "FARM_NUMBER")["identifier_value"])
    n3 = int(next(i for i in _identifiers(client, goat["id"], h) if i["identifier_type"] == "FARM_NUMBER")["identifier_value"])
    assert (n2, n3) == (n1 + 1, n1 + 2)  # one farm-level sequence, every species
    assert next(i for i in ids2 if i["is_primary"])["identifier_type"] == "EAR_TAG"
    assert second["tag"] == "LB-9911"


def test_a_given_farm_number_is_kept_and_a_duplicate_is_still_refused(client):
    h = _h(client)
    r = _register(client, h, identifiers=[{"identifier_type": "FARM_NUMBER", "identifier_value": "0500"}])
    assert r.status_code == 201
    assert [i["identifier_value"] for i in _identifiers(client, r.json()["id"], h)] == ["0500"]
    clash = _register(client, h, name="Copy", identifiers=[{"identifier_type": "FARM_NUMBER", "identifier_value": "0500"}])
    assert clash.status_code == 409
    # The next generated number follows the highest one in use.
    nxt = _register(client, h, name="Next").json()
    assert next(i for i in _identifiers(client, nxt["id"], h) if i["identifier_type"] == "FARM_NUMBER")["identifier_value"] == "0501"


def test_a_horse_registers_without_its_microchip(client):
    r = client.post(f"{API}/animals", json={"name": "Foal", "species": "horse", "sex": "F"}, headers=_h(client))
    assert r.status_code == 201, r.text
    caps = client.get(f"{API}/animals/{r.json()['id']}/capabilities", headers=_h(client))
    assert caps.status_code == 200
    assert "MICROCHIP" in caps.json()["required_identifier_types"]  # still expected — shown as missing


# ------------------------------------------------------------ pregnancy & milk at registration
def test_registered_pregnant_from_an_insemination_date(client, db_session):
    session, factory = db_session
    served = (datetime.now(timezone.utc) - timedelta(days=100)).replace(microsecond=0)
    r = _register(client, pregnant=True, service_date=served.isoformat(), service_type="ARTIFICIAL_INSEMINATION", lactating=True)
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["pregnant"] is True and body["lactating"] is True
    due = datetime.fromisoformat(body["expected_due_date"].replace("Z", "+00:00"))
    assert (due.date() - served.date()).days == 283
    with factory() as db:
        breeding = db.scalar(select(rm.BreedingEvent).where(rm.BreedingEvent.female_animal_id == body["id"]))
        episode = db.scalar(select(rm.PregnancyEpisode).where(rm.PregnancyEpisode.animal_id == body["id"]))
        assert breeding.event_type == "ARTIFICIAL_INSEMINATION"
        assert episode.originating_breeding_event_id == breeding.id


def test_registered_inseminated_but_not_confirmed(client):
    served = datetime.now(timezone.utc) - timedelta(days=10)
    r = _register(client, service_date=served.isoformat(), service_type="NATURAL_MATING")
    assert r.status_code == 201, r.text
    repro = client.get(f"{API}/animals/{r.json()['id']}/reproduction", headers=_h(client)).json()
    assert repro["summary"]["pregnant"] is False
    assert repro["summary"]["last_breeding"]["event_type"] == "NATURAL_MATING"


def test_an_insemination_past_term_is_refused(client):
    served = datetime.now(timezone.utc) - timedelta(days=400)
    r = _register(client, pregnant=True, service_date=served.isoformat())
    assert r.status_code == 422
    assert "insemination date" in r.json()["detail"].lower()


def test_a_senior_dairy_cow_can_be_pregnant_and_in_milk(client):
    r = _register(client, life_stage="senior", pregnant=True, lactating=True)
    assert r.status_code == 201, r.text
    assert r.json()["pregnant"] is True and r.json()["lactating"] is True


# ------------------------------------------------------------ dry-off setting
def test_the_manager_sets_dry_off_days_and_the_herd_follows(client):
    h = _h(client)
    assert client.get(f"{API}/farms/me", headers=h).json()["dry_off_days_before_birth"] == 60
    assert client.patch(f"{API}/farms/me", json={"dry_off_days_before_birth": 300}, headers=h).status_code == 422
    r = client.patch(f"{API}/farms/me", json={"dry_off_days_before_birth": 45}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["dry_off_days_before_birth"] == 45

    overview = client.get(f"{API}/reproduction/overview", headers=h).json()
    assert overview["dry_off_days_before_birth"] == 45
    bella = next(p for p in overview["pregnant"] if p["animal_id"] == BELLA)
    due = datetime.fromisoformat(bella["expected_due_date"].replace("Z", "+00:00"))
    dry = datetime.fromisoformat(bella["dry_off_from"].replace("Z", "+00:00"))
    assert (due - dry).days == 45
    assert bella["lactating"] is True
    assert bella["dry_off_due"] is (bella["days_to_dry_off"] <= 0)

    summary = client.get(f"{API}/animals/{BELLA}/reproduction", headers=h).json()["summary"]
    assert summary["dry_off_days_before_birth"] == 45 and summary["dry_off_from"] is not None


def test_a_worker_cannot_change_farm_settings(client):
    r = client.patch(f"{API}/farms/me", json={"dry_off_days_before_birth": 30}, headers=_h(client, "karim.worker@origami.farm"))
    assert r.status_code == 403


# ------------------------------------------------------------ standard feeds
def test_standard_slots_match_the_farms_own_feeds(client):
    slots = {s["slot"]: s for s in client.get(f"{API}/feed-products/standard-slots", headers=_h(client)).json()}
    assert list(slots) == ["concentrate", "corn_silage", "wheat_straw"]
    assert slots["corn_silage"]["feed_product_id"] == "fp-corn-silage"
    assert slots["wheat_straw"]["feed_product_id"] == "fp-wheat-straw"
    # A feed named for the slot wins over one that is only a concentrate by category (barley).
    assert slots["concentrate"]["feed_product_id"] == "fp-dairy-concentrate"


def test_ensure_standard_feeds_creates_only_what_is_missing(client, db_session):
    session, factory = db_session
    h = _h(client)
    with factory() as db:
        db.get(fm.FeedProduct, "fp-wheat-straw").status = "inactive"
        db.commit()
    before = len(client.get(f"{API}/feed-products", headers=h).json())
    slots = {s["slot"]: s for s in client.post(f"{API}/feed-products/standard", headers=h).json()}
    after = client.get(f"{API}/feed-products", headers=h).json()
    assert len(after) == before + 1
    straw = next(p for p in after if p["id"] == slots["wheat_straw"]["feed_product_id"])
    assert straw["name"] == "Wheat straw" and straw["is_feedable"] is True
    assert straw["availability"]["on_hand"] == 0  # no invented stock
    again = client.post(f"{API}/feed-products/standard", headers=h).json()
    assert len(client.get(f"{API}/feed-products", headers=h).json()) == before + 1
    assert {s["slot"]: s["feed_product_id"] for s in again} == {s: v["feed_product_id"] for s, v in slots.items()}


def test_feeding_beyond_entered_stock_needs_the_explicit_override(client):
    h = _h(client)
    straw = client.post(f"{API}/feed-products", json={"name": "Barley straw", "unit": "kg", "is_feedable": True, "category": "forage"}, headers=h).json()
    body = {"subject_type": "animal", "subject_id": BELLA, "event_type": "offered",
            "components": [{"feed_product_id": straw["id"], "quantity_offered": 6}]}
    refused = client.post(f"{API}/feeding-events", json=body, headers=h)
    assert refused.status_code == 422 and refused.json()["detail"].startswith("Not enough")
    ok = client.post(f"{API}/feeding-events", json={**body, "allow_negative": True}, headers=h)
    assert ok.status_code == 201, ok.text
    assert ok.json()["components"][0]["lot_id"] is None  # the shortfall is against no lot
