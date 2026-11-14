"""Purchase → mix → feed in one-step forms, the breeding / milk calendar after
a calving, groups that follow the herd records, and worker responsibilities
(docs/GENERIC-FEED-ARCHITECTURE.md §3, §5a; database/PRODUCTION-SCHEMA.md §8;
database/LIVESTOCK-SCHEMA.md §7; migration c3e5a7b9d1f4).
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from tests.conftest import auth_headers

API = "/api/v1"
BELLA, LUNA, CLOVER, DAISY = "cow-744", "cow-214", "cow-clover", "sheep-s045"


def _h(client, email="rami@origami.farm"):
    return auth_headers(client, email)


def _iso(days_ago: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days_ago)).isoformat()


# ------------------------------------------------------------ feed: purchase, mix, feed
def test_grain_purchase_with_quality_then_a_mix_then_feeding(client):
    h = _h(client)
    corn = client.post(f"{API}/feed-products", json={"name": "Corn grain", "unit": "kg", "is_ingredient": True, "is_feedable": False,
                                                    "category": "concentrate"}, headers=h).json()
    lot = client.post(f"{API}/feed-lots/receive", json={
        "feed_product_id": corn["id"], "quantity": 1000, "unit_cost": 0.31, "supplier_label": "Bekaa Grain Co.", "received_at": _iso(3),
        "quality_grade": "good", "moisture_pct": 13.5, "quality_notes": "Clean, no mould",
    }, headers=h)
    assert lot.status_code == 201, lot.text
    assert (lot.json()["quality_grade"], lot.json()["moisture_pct"], lot.json()["supplier_label"]) == ("good", 13.5, "Bekaa Grain Co.")
    bad = client.post(f"{API}/feed-lots/receive", json={"feed_product_id": corn["id"], "quantity": 10, "quality_grade": "excellent"}, headers=h)
    assert bad.status_code == 422

    slots = {s["slot"]: s for s in client.get(f"{API}/feed-products/standard-slots", headers=h).json()}
    # A one-step mix into a new farm feed: formula v1 is created from the mix.
    mix = client.post(f"{API}/feed-mixes", json={
        "new_product_name": "Cow concentrate", "produced_at": _iso(1),
        "components": [{"feed_product_id": corn["id"], "actual_quantity": 300}, {"feed_product_id": "fp-barley", "actual_quantity": 150}],
    }, headers=h)
    assert mix.status_code == 201, mix.text
    m = mix.json()
    assert m["status"] == "completed" and m["mix_code"] and m["actual_quantity"] == 450
    used = {c["feed_product_id"]: c["actual_quantity"] for c in m["components"]}
    assert used[corn["id"]] == 300 and used["fp-barley"] == 150
    product_id = m["feed_product_id"]
    stock = next(p for p in client.get(f"{API}/feed-products", headers=h).json() if p["id"] == product_id)
    assert stock["availability"]["on_hand"] == 450 and stock["source_type"] == "farm_produced" and stock["has_active_formula"]
    corn_now = next(p for p in client.get(f"{API}/feed-products", headers=h).json() if p["id"] == corn["id"])
    assert corn_now["availability"]["on_hand"] == 700  # the ledger, not a typed balance

    # The second mix of the same feed uses its formula; a left-out
    # ingredient is recorded as zero, not refused.
    again = client.post(f"{API}/feed-mixes", json={"feed_product_id": product_id, "components": [{"feed_product_id": corn["id"], "actual_quantity": 200}]}, headers=h)
    assert again.status_code == 201, again.text
    assert again.json()["mix_number"] == m["mix_number"] + 1

    fed = client.post(f"{API}/feeding-events", json={"subject_type": "animal", "subject_id": BELLA, "event_type": "offered",
                                                     "components": [{"feed_product_id": product_id, "quantity_offered": 8}]}, headers=h)
    assert fed.status_code == 201, fed.text
    assert fed.json()["components"][0]["batch_id"] == m["id"]  # FIFO: the oldest mix's output lot first
    assert slots["concentrate"]["feed_product_id"] is not None


def test_a_mix_cannot_make_a_bought_feed_or_itself(client):
    h = _h(client)
    bought = client.post(f"{API}/feed-mixes", json={"feed_product_id": "fp-barley", "components": [{"feed_product_id": "fp-alfalfa", "actual_quantity": 10}]}, headers=h)
    assert bought.status_code == 422 and "bought-in" in bought.json()["detail"]
    empty = client.post(f"{API}/feed-mixes", json={"new_product_name": "X", "components": [{"feed_product_id": "fp-barley", "actual_quantity": 0}]}, headers=h)
    assert empty.status_code == 422


# ------------------------------------------------------------ calendar after a calving
def test_the_calendar_after_a_calving_and_a_service(client):
    h = _h(client)
    r = client.patch(f"{API}/farms/me", json={"milk_peak_start_days": 40, "milk_peak_end_days": 70, "breeding_wait_days": 50, "heat_cycle_days": 21}, headers=h)
    assert r.status_code == 200, r.text
    assert client.patch(f"{API}/farms/me", json={"milk_peak_start_days": 80, "milk_peak_end_days": 70}, headers=h).status_code == 422

    # A fresh cow registered in milk, calved 55 days ago: in her peak window
    # and past the 50-day wait, not served since — ready to inseminate.
    cow = client.post(f"{API}/animals", json={"name": "Fresh", "species": "cow", "sex": "F", "management_profile": "dairy",
                                             "lactating": True, "lactation_started_at": _iso(55)}, headers=h).json()
    s = client.get(f"{API}/animals/{cow['id']}/reproduction", headers=h).json()["summary"]
    assert s["days_in_milk"] == 55 and s["in_milk_peak"] is True and s["ready_for_breeding"] is True
    overview = client.get(f"{API}/reproduction/overview", headers=h).json()
    assert cow["id"] in {r["animal_id"] for r in overview["in_milk_peak"]}
    assert cow["id"] in {r["animal_id"] for r in overview["ready_for_breeding"]}

    # Inseminated 20 days ago: no longer "ready", watched for a return to heat (21 ± 3).
    assert client.post(f"{API}/animals/{cow['id']}/breedings", json={"event_type": "ARTIFICIAL_INSEMINATION", "occurred_at": _iso(20)}, headers=h).status_code == 201
    s = client.get(f"{API}/animals/{cow['id']}/reproduction", headers=h).json()["summary"]
    assert s["ready_for_breeding"] is False and s["heat_watch_now"] is True
    assert cow["id"] in {r["animal_id"] for r in client.get(f"{API}/reproduction/overview", headers=h).json()["heat_watch"]}


def test_the_calving_date_of_the_current_lactation_is_corrected_with_an_audit(client):
    h = _h(client)
    cow = client.post(f"{API}/animals", json={"name": "Late entry", "species": "cow", "sex": "F", "management_profile": "dairy", "lactating": True}, headers=h).json()
    r = client.patch(f"{API}/animals/{cow['id']}/lactation", json={"started_at": _iso(30), "reason": "calving date found in the notebook"}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["summary"]["days_in_milk"] == 30
    assert client.patch(f"{API}/animals/{cow['id']}/lactation", json={"started_at": (datetime.now(timezone.utc) + timedelta(days=3)).isoformat()}, headers=h).status_code == 422
    # A lactation started by a recorded birth is dated by that birth.
    luna = client.get(f"{API}/animals/{LUNA}/reproduction", headers=h).json()["summary"]
    if luna["lactation"] and luna["lactation"]["birth_event_id"]:
        assert client.patch(f"{API}/animals/{LUNA}/lactation", json={"started_at": _iso(10)}, headers=h).status_code == 409


# ------------------------------------------------------------ groups that follow the records
def test_cows_can_be_grouped_and_rule_groups_follow_pregnancy(client):
    h = _h(client)
    herd = client.post(f"{API}/animal-groups", json={"name": "Heifers", "species": "cow", "group_type": "herd"}, headers=h)
    assert herd.status_code == 201, herd.text
    groups = {g["id"]: g for g in client.get(f"{API}/animal-groups", headers=h).json()}
    pregnant, open_ = groups["grp-cows-pregnant"], groups["grp-cows-open"]
    assert pregnant["membership_rule"] == "PREGNANT" and pregnant["group_type"] == "cohort"

    def members(gid):
        return {m["animal_id"] for m in client.get(f"{API}/animal-groups/{gid}/members", headers=h).json()}

    assert BELLA in members("grp-cows-pregnant") and CLOVER in members("grp-cows-open")
    # Clover confirmed pregnant: she leaves "Open cows" and joins "Pregnant cows" — and stays in her herd.
    before_herd = client.get(f"{API}/animals/{CLOVER}", headers=h).json()["group_name"]
    r = client.post(f"{API}/animals/{CLOVER}/pregnancy-checks", json={"assessment_type": "ULTRASOUND", "result_code": "POSITIVE", "estimated_gestation_days": 40}, headers=h)
    assert r.status_code == 201, r.text
    assert CLOVER in members("grp-cows-pregnant") and CLOVER not in members("grp-cows-open")
    assert client.get(f"{API}/animals/{CLOVER}", headers=h).json()["group_name"] == before_herd

    # A new rule group starts with whoever already matches.
    milking = client.post(f"{API}/animal-groups", json={"name": "Milking cows", "species": "cow", "group_type": "herd", "membership_rule": "IN_MILK"}, headers=h)
    assert milking.status_code == 201, milking.text
    assert milking.json()["group_type"] == "cohort" and milking.json()["count"] >= 1
    assert client.post(f"{API}/animal-groups", json={"name": "X", "species": "cow", "membership_rule": "SICK"}, headers=h).status_code == 422


# ------------------------------------------------------------ responsibilities
def test_a_worker_is_made_responsible_for_a_herd_with_duties(client):
    h = _h(client)
    users = {u["email"]: u for u in client.get(f"{API}/employees", headers=h).json()}
    vet = users["nadine.acct@origami.farm"]
    r = client.post(f"{API}/employees/{vet['id']}/responsibilities", json={"scope_type": "group", "scope_id": "grp-dairy-herd",
                                                                          "duties": ["milking", "observation"]}, headers=h)
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["scope_name"] == "Dairy Herd" and body["duties"] == ["milking", "observation"]
    assert "milk_production" in body["modules_granted"]
    access = client.get(f"{API}/me/access", headers=_h(client, "nadine.acct@origami.farm")).json()
    granted = {m["module_code"] if isinstance(m, dict) else m for m in access.get("modules", access.get("permissions", []))}
    assert "milk_production" in str(access) or "milk_production" in granted

    mine = client.get(f"{API}/me/responsibilities", headers=_h(client, "nadine.acct@origami.farm")).json()
    assert mine[0]["scope_name"] == "Dairy Herd" and BELLA in {a["id"] for a in mine[0]["animals"]}
    assert client.post(f"{API}/employees/{vet['id']}/responsibilities", json={"scope_type": "group", "scope_id": "grp-dairy-herd",
                                                                             "duties": ["feeding"]}, headers=h).status_code == 409
    assert client.post(f"{API}/employees/{vet['id']}/responsibilities", json={"scope_type": "group", "scope_id": "grp-dairy-herd",
                                                                             "duties": ["harvest"]}, headers=h).status_code == 422
    end = client.post(f"{API}/employees/{vet['id']}/responsibilities/{body['id']}/end", json={"reason": "moved to the clinic"}, headers=h)
    assert end.status_code == 200 and end.json()["status"] == "ended"
    assert client.get(f"{API}/me/responsibilities", headers=_h(client, "nadine.acct@origami.farm")).json() == []
    # The demo worker already looks after the dairy herd.
    karim = client.get(f"{API}/me/responsibilities", headers=_h(client, "karim.worker@origami.farm")).json()
    assert karim and set(karim[0]["duties"]) == {"milking", "feeding", "observation"}


def test_only_a_manager_assigns_responsibilities(client):
    users = {u["email"]: u for u in client.get(f"{API}/employees", headers=_h(client)).json()}
    r = client.post(f"{API}/employees/{users['karim.worker@origami.farm']['id']}/responsibilities",
                    json={"scope_type": "animal", "scope_id": BELLA, "duties": ["milking"]}, headers=_h(client, "karim.worker@origami.farm"))
    assert r.status_code == 403
