"""Milk safety judged at the milking time (v0.8.5, ADR-005; audit
2026-11-25 I-3 and I-15).

A milking is judged from the animal's dated history — the treatments and
doses that put a withdrawal on her milk, the lactations she was in — at
its own timestamp. The same milking gets the same answer whether it is
entered at the parlour, from a paper sheet days later, corrected, or
replayed by a tablet that was offline. Milk a recorded withdrawal covers is
only ever withheld; milk the records cannot vouch for is kept but held for
review; neither reaches the saleable tank.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import func, select

from app.domain import milk_models as mm
from app.domain import models
from app.domain import pharmacy_models as pm
from app.services import milk_safety_service as safety
from app.services import milk_service
from tests.conftest import auth_headers

API = "/api/v1"
LUNA, CLOVER, BELLA, GIGI = "cow-214", "cow-clover", "cow-744", "goat-gigi"
WORKER = "karim.worker@origami.farm"


def _h(client, email="rami@origami.farm"):
    return auth_headers(client, email)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _ago(days: float, hour: int | None = None) -> datetime:
    t = _now() - timedelta(days=days)
    return t.replace(hour=hour, minute=0, second=0, microsecond=0) if hour is not None else t


def _iso(t: datetime) -> str:
    return t.isoformat()


def _user_id(session, email="rami@origami.farm") -> str:
    return session.scalar(select(models.User.id).where(models.User.email == email))


def _treat(client, session, animal_id: str, *, start: datetime, until: datetime, medication="Amoxicillin", entity_type="animal"):
    r = client.post(f"{API}/health/treatments", headers=_h(client), json={
        "entity_type": entity_type, "entity_id": animal_id, "medication": medication, "dose": "10 mL", "route": "IM",
        "responsible_user_id": _user_id(session), "start_at": _iso(start), "withdrawal_until": _iso(until), "confirm_duplicate": True})
    assert r.status_code == 201, r.text
    return r.json()


def _milk(client, animal_id: str, at: datetime | None, *, destination="stored", session="morning", liters=10.0, headers=None):
    body = {"animal_id": animal_id, "session": session, "liters": liters, "destination": destination, "confirm_duplicate": True}
    if at is not None:
        body["recorded_at"] = _iso(at)
    return client.post(f"{API}/production/milk", headers=headers or _h(client), json=body)


def _tank(client) -> float:
    return client.get(f"{API}/production/milk-tank", headers=_h(client)).json()["balance_l"]


def _record(session, record_id: str) -> models.MilkRecord:
    session.expire_all()
    return session.get(models.MilkRecord, record_id)


# ------------------------------------------------------------- I-3 (NEW3)
def test_NEW3_milk_inside_a_withdrawal_that_ended_yesterday_is_not_stored_or_sold(client, db_session):
    """Entered today, dated two days ago — inside a withdrawal a treatment
    recorded, which ended yesterday. Today's record says she is clear; the
    milking was not."""
    session, _ = db_session
    _treat(client, session, LUNA, start=_ago(5), until=_ago(1))
    tank = _tank(client)
    for destination in ("stored", "sold", "processed", "consumed"):
        r = _milk(client, LUNA, _ago(2, hour=7), destination=destination)
        assert r.status_code == 422, (destination, r.text)
        assert "under withdrawal when milked" in r.json()["detail"] and "Amoxicillin" in r.json()["detail"]
    assert _tank(client) == tank
    ok = _milk(client, LUNA, _ago(2, hour=7), destination="withheld")
    assert ok.status_code == 201, ok.text
    assert (ok.json()["withdrawal_check"], ok.json()["release_status"]) == ("withdrawal", "not_for_sale")
    assert _tank(client) == tank
    # Today, after the withdrawal, she is clear again.
    today = _milk(client, LUNA, None)
    assert today.status_code == 201 and (today.json()["withdrawal_check"], today.json()["release_status"]) == ("clear", "saleable")


def test_NEW3_with_only_her_record_to_go_on_the_milk_is_held_not_sold(client, db_session):
    """No dated treatment explains her withdrawal (an older record): milk
    from before the server held it cannot be cleared — it is kept, held for
    review, and never counted in the tank."""
    session, _ = db_session
    clover = session.get(models.Animal, CLOVER)
    clover.withdrawal_until = _ago(1)
    clover.withdrawal_reason = "Medication"
    session.commit()
    tank = _tank(client)
    r = _milk(client, CLOVER, _ago(2, hour=7))
    assert r.status_code == 201, r.text
    assert (r.json()["withdrawal_check"], r.json()["release_status"]) == ("uncertain", "held")
    assert "cannot be confirmed" in r.json()["safety_note"]
    assert _tank(client) == tank, "held milk is not in the tank"
    held = client.get(f"{API}/production/milk-held", headers=_h(client)).json()
    assert [h["id"] for h in held] == [r.json()["id"]] and held[0]["animal_name"] == "Clover"


def test_the_same_milking_gets_the_same_answer_whatever_the_entry_day(client, db_session, monkeypatch):
    """The answer depends on the milking time and her history only: judged
    as if entered during the withdrawal, the next day, or a week later."""
    session, _ = db_session
    _treat(client, session, LUNA, start=_ago(6), until=_ago(3))
    luna = session.get(models.Animal, LUNA)
    session.refresh(luna)
    inside, after, before = _ago(4, hour=7), _ago(2, hour=7), _ago(8, hour=7)
    answers = []
    for entered in (_ago(3.5), _ago(2), _now()):
        monkeypatch.setattr(safety, "now", lambda e=entered: e)
        answers.append(tuple(milk_service.check_milk(session, luna, t, "withheld").assessment.status for t in (inside, after, before)))
    assert answers == [("withdrawal", "clear", "clear")] * 3


# ------------------------------------------------------- overlapping medicines
def test_overlapping_medicines_each_keep_their_window(client, db_session):
    session, _ = db_session
    _treat(client, session, LUNA, start=_ago(6), until=_ago(3), medication="Amoxicillin")
    _treat(client, session, LUNA, start=_ago(4), until=_ago(1), medication="Oxytetracycline")
    for days, expect in ((5, "Amoxicillin"), (3.5, "Amoxicillin"), (2, "Oxytetracycline")):
        r = _milk(client, LUNA, _ago(days))
        assert r.status_code == 422 and expect in r.json()["detail"], (days, r.text)
    both = _milk(client, LUNA, _ago(3.5), destination="withheld").json()
    assert "Amoxicillin" in both["safety_note"] and "Oxytetracycline" in both["safety_note"]
    assert _milk(client, LUNA, _ago(0.5)).json()["release_status"] == "saleable"


def test_a_shorter_treatment_never_cuts_a_longer_withdrawal_on_her_record(client, db_session):
    session, _ = db_session
    _treat(client, session, LUNA, start=_now() - timedelta(hours=1), until=_now() + timedelta(days=5), medication="Long-acting")
    _treat(client, session, LUNA, start=_now() - timedelta(minutes=30), until=_now() + timedelta(days=2), medication="Short")
    session.expire_all()
    until = session.get(models.Animal, LUNA).withdrawal_until.replace(tzinfo=timezone.utc)
    assert until > _now() + timedelta(days=4)
    assert _milk(client, LUNA, None).status_code == 422


def test_a_group_treatment_covers_the_animals_in_the_group_at_the_time(client, db_session):
    session, _ = db_session
    _treat(client, session, "grp-dairy-herd", entity_type="group", start=_ago(5), until=_ago(1), medication="Herd drench")
    assert _milk(client, LUNA, _ago(3)).status_code == 422, "Luna was in the herd then"
    # Gigi (a goat) was never in the dairy herd.
    assert _milk(client, GIGI, _ago(3)).json()["release_status"] == "saleable"


def test_a_reversed_dose_leaves_the_milk_for_a_veterinarian(client, db_session):
    """A dose recorded then reversed does not prove she was not dosed: milk
    in its window is held, not cleared and not refused."""
    session, _ = db_session
    adm = session.scalars(select(pm.MedicationAdministration)).first()
    assert adm is not None
    adm.subject_type, adm.subject_id = "animal", CLOVER
    adm.administered_at, adm.withdrawal_milk_until, adm.withdrawal_meat_until = _ago(4), _ago(1), None
    adm.status, adm.reversal_reason = "reversed", "Entered on the wrong animal"
    session.commit()
    r = _milk(client, CLOVER, _ago(2))
    assert r.status_code == 201 and (r.json()["withdrawal_check"], r.json()["release_status"]) == ("uncertain", "held"), r.text
    assert "reversed" in r.json()["safety_note"]


# --------------------------------------------------------- reviewing held milk
def test_held_milk_is_released_only_by_a_vet_or_the_manager_saying_why(client, db_session):
    session, _ = db_session
    clover = session.get(models.Animal, CLOVER)
    clover.withdrawal_until = _ago(1)
    session.commit()
    rec = _milk(client, CLOVER, _ago(2)).json()
    tank = _tank(client)
    url = f"{API}/production/milk/{rec['id']}/review"
    assert client.post(url, headers=_h(client, WORKER), json={"decision": "release", "note": "looks fine"}).status_code == 403
    assert client.post(url, headers=_h(client), json={"decision": "release", "note": ""}).status_code == 422
    r = client.post(url, headers=_h(client), json={"decision": "release", "note": "Vet: the treatment began the day after this milking"})
    assert r.status_code == 200, r.text
    assert r.json()["release_status"] == "released" and r.json()["review_note"].startswith("Vet:")
    assert _tank(client) == pytest.approx(tank + 10)
    assert client.post(url, headers=_h(client), json={"decision": "release", "note": "again"}).status_code == 409


def test_held_milk_withheld_after_review_leaves_the_tank_as_it_was(client, db_session):
    session, _ = db_session
    clover = session.get(models.Animal, CLOVER)
    clover.withdrawal_until = _ago(1)
    session.commit()
    rec = _milk(client, CLOVER, _ago(2)).json()
    tank = _tank(client)
    r = client.post(f"{API}/production/milk/{rec['id']}/review", headers=_h(client), json={"decision": "withhold", "note": "Not worth the risk"})
    assert r.status_code == 200, r.text
    assert (r.json()["destination"], r.json()["release_status"]) == ("withheld", "not_for_sale")
    assert _tank(client) == tank


def test_milk_a_recorded_withdrawal_covers_is_never_released(client, db_session):
    """A treatment recorded after the milk was saved holds it; a reviewer
    cannot clear what a prescription window covers."""
    session, _ = db_session
    rec = _milk(client, LUNA, _ago(2)).json()
    assert rec["release_status"] == "saleable"
    _treat(client, session, LUNA, start=_ago(3), until=_ago(1))
    assert _record(session, rec["id"]).release_status == "held"
    r = client.post(f"{API}/production/milk/{rec['id']}/review", headers=_h(client), json={"decision": "release", "note": "please"})
    assert r.status_code == 409 and "cannot be released" in r.json()["detail"]


# ---------------------------------------------------- facts recorded later
def test_a_treatment_entered_late_holds_milk_already_saved_and_changes_no_sale(client, db_session):
    session, _ = db_session
    h = _h(client)
    rec = _milk(client, LUNA, _ago(2, hour=7)).json()
    sold = client.post(f"{API}/production/milk-sales", headers=h, json={"liters": 5, "price_per_liter": 0.5, "buyer_name": "Dairy"})
    assert sold.status_code == 201, sold.text
    sales_before = session.scalar(select(func.count(mm.MilkSale.id)))
    tank = _tank(client)
    _treat(client, session, LUNA, start=_ago(3), until=_ago(1))
    session.expire_all()
    held = session.get(models.MilkRecord, rec["id"])
    assert (held.release_status, held.withdrawal_check) == ("held", "withdrawal")
    assert "Held when the treatment" in held.safety_note
    assert _tank(client) < tank, "held milk leaves the saleable tank"
    assert session.scalar(select(func.count(mm.MilkSale.id))) == sales_before
    assert session.scalars(select(models.Notification).where(models.Notification.notification_type == "milk_safety")).first() is not None


# ------------------------------------------------------- corrections
def test_a_correction_is_judged_again_at_its_new_time_and_destination(client, db_session):
    session, _ = db_session
    _treat(client, session, LUNA, start=_ago(5), until=_ago(3))
    rec = _milk(client, LUNA, _ago(2, hour=12), session="midday").json()
    assert rec["release_status"] == "saleable"
    url = f"{API}/production/milk/{rec['id']}/correct"
    into = client.post(url, headers=_h(client), json={"recorded_at": _iso(_ago(4, hour=12)), "reason": "It was Tuesday's milk"})
    assert into.status_code == 422 and "under withdrawal when milked" in into.json()["detail"]
    withheld = client.post(url, headers=_h(client), json={"recorded_at": _iso(_ago(4, hour=12)), "destination": "withheld", "reason": "Tuesday, withheld"})
    assert withheld.status_code == 200, withheld.text
    assert (withheld.json()["withdrawal_check"], withheld.json()["release_status"]) == ("withdrawal", "not_for_sale")
    back = client.post(url, headers=_h(client), json={"recorded_at": _iso(_ago(1, hour=12)), "destination": "stored", "reason": "It was yesterday after all"})
    assert back.status_code == 200 and back.json()["release_status"] == "saleable", back.text


def test_the_tank_and_the_collector_only_ever_see_saleable_milk(client, db_session):
    session, _ = db_session
    clover = session.get(models.Animal, CLOVER)
    clover.withdrawal_until = _ago(0.1)
    session.commit()
    tank = _tank(client)
    held = _milk(client, CLOVER, _ago(1, hour=7), liters=40)
    assert held.json()["release_status"] == "held"
    assert _tank(client) == tank
    # More than the saleable tank holds is refused to the collector.
    h = _h(client)
    client.put(f"{API}/production/milk-routine", headers=h, json={"collector_name": "Abu Ali", "collector_price": 0.5, "collector_currency": "USD"})
    r = client.post(f"{API}/production/milk-handovers", headers=h, json={"session": "morning", "calves_l": 0, "collected_l": tank + 30,
                                                                       "confirm_duplicate": True})
    assert r.status_code == 422 and "tank holds" in r.json()["detail"], r.text


# --------------------------------------------------------- I-15 (dry-off)
def test_I15_milk_from_before_yesterdays_dry_off_is_accepted_after_it_refused(client, db_session):
    session, _ = db_session
    h = _h(client)
    r = client.post(f"{API}/animals/{LUNA}/dry-off", headers=h, json={"ended_at": _iso(_ago(1, hour=12))})
    assert r.status_code == 200, r.text
    before = _milk(client, LUNA, _ago(3, hour=7))
    assert before.status_code == 201, before.text
    assert (before.json()["withdrawal_check"], before.json()["release_status"]) == ("clear", "saleable")
    assert before.json()["lactation_episode_id"], "it belongs to the lactation that has ended"
    after = _milk(client, LUNA, _ago(1, hour=18), session="evening")
    assert after.status_code == 409 and "dried off on" in after.json()["detail"], after.text
    today = _milk(client, LUNA, None)
    assert today.status_code == 409


def test_I15_before_the_lactation_started_is_refused(client, db_session):
    session, _ = db_session
    # Luna's lactation started 2026-08-27 in the demo farm (90 days ago).
    r = _milk(client, LUNA, _ago(120))
    assert r.status_code == 422 and "milk cannot be dated before it" in r.json()["detail"], r.text


def test_I15_a_recent_dry_off_does_not_lift_a_withdrawal(client, db_session):
    session, _ = db_session
    _treat(client, session, LUNA, start=_ago(5), until=_ago(2))
    client.post(f"{API}/animals/{LUNA}/dry-off", headers=_h(client), json={"ended_at": _iso(_ago(1, hour=12))})
    r = _milk(client, LUNA, _ago(3, hour=7))
    assert r.status_code == 422 and "under withdrawal when milked" in r.json()["detail"]
    assert _milk(client, LUNA, _ago(3, hour=7), destination="withheld").status_code == 201


def test_I15_a_correction_cannot_move_milk_past_the_dry_off(client, db_session):
    session, _ = db_session
    rec = _milk(client, LUNA, _ago(3, hour=12), session="midday").json()
    client.post(f"{API}/animals/{LUNA}/dry-off", headers=_h(client), json={"ended_at": _iso(_ago(2, hour=12))})
    r = client.post(f"{API}/production/milk/{rec['id']}/correct", headers=_h(client),
                    json={"recorded_at": _iso(_ago(1, hour=13)), "reason": "wrong day"})
    assert r.status_code in (409, 422) and "dried off" in r.json()["detail"], r.text


def test_a_capability_still_decides_who_gives_milk(client):
    r = _milk(client, "bull-b01", _ago(1))
    assert r.status_code in (404, 422)


# ----------------------------------------------------------- offline replay
def _push(client, items):
    return client.post(f"{API}/sync/push", headers=_h(client), json={"farm_id": "farm-origami", "device_id": "tablet-07", "items": items}).json()


def _item(key, animal, at, destination="stored", liters=9):
    return {"idempotency_key": key, "operation": "create", "entity_type": "animal", "entity_id": animal,
            "payload": {"session": "morning", "liters": liters, "destination": destination}, "client_created_at": _iso(at)}


def test_an_offline_replay_is_judged_at_the_milking_time(client, db_session):
    """Judged at the milking time, never saleable under a withdrawal. Since
    ADR-008 the replay that says "stored" is kept but held, not rejected:
    the device recorded it offline and the milk may be in the tank."""
    session, _ = db_session
    _treat(client, session, LUNA, start=_ago(5), until=_ago(1))
    tank = _tank(client)
    t = _ago(2, hour=5)
    out = _push(client, [_item("replay-1", LUNA, t), _item("replay-2", LUNA, t, destination="withheld"), _item("replay-3", CLOVER, t)])
    statuses = [r["status"] for r in out["results"]]
    assert statuses == ["accepted", "accepted", "accepted"], out
    rows = session.scalars(select(models.MilkRecord).where(models.MilkRecord.recorded_by.is_not(None))
                           .order_by(models.MilkRecord.recorded_at.desc())).all()
    replayed = [r for r in rows if r.animal_id in (LUNA, CLOVER) and abs((r.recorded_at.replace(tzinfo=timezone.utc) - t).total_seconds()) < 2]
    assert sorted((r.animal_id, r.destination, r.release_status) for r in replayed) == sorted(
        [(CLOVER, "stored", "saleable"), (LUNA, "stored", "held"), (LUNA, "withheld", "not_for_sale")])
    held = next(r for r in replayed if r.release_status == "held")
    assert held.withdrawal_check == "withdrawal" and "under withdrawal when milked" in held.safety_note
    assert _tank(client) == pytest.approx(tank + 9)


# ------------------------------------------------------- older records
def test_older_records_are_reviewed_not_rewritten(client, db_session):
    session, _ = db_session
    old = session.scalars(select(models.MilkRecord).where(models.MilkRecord.animal_id == LUNA)
                          .order_by(models.MilkRecord.recorded_at.desc())).first()
    assert old.withdrawal_check == "unchecked" and old.release_status == "saleable"
    at = old.recorded_at.replace(tzinfo=timezone.utc)
    # A treatment that covered it, entered as history directly (no hold).
    session.add(models.Treatment(id="treat-history", entity_type="animal", entity_id=LUNA, medication="Penicillin", dose="1", route="IM",
                                 start_at=at - timedelta(hours=2), withdrawal_until=at + timedelta(days=1), responsible_user_id="user-vet-1",
                                 status="completed"))
    session.commit()
    tank = _tank(client)
    review = client.get(f"{API}/production/milk-safety/review", headers=_h(client)).json()
    assert [f["milk_record_id"] for f in review["findings"]] == [old.id]
    assert review["findings"][0]["withdrawal_check"] == "withdrawal" and review["withdrawal_l"] == pytest.approx(old.liters, abs=0.1)
    assert _record(session, old.id).release_status == "saleable" and _tank(client) == tank, "read only"


def test_the_milk_safety_check_answers_before_saving(client, db_session):
    session, _ = db_session
    _treat(client, session, LUNA, start=_ago(5), until=_ago(1))
    r = client.get(f"{API}/production/milk-safety", headers=_h(client), params={"animal_id": LUNA, "at": _iso(_ago(2))}).json()
    assert r["withdrawal_check"] == "withdrawal" and r["windows"][0]["label"].startswith("Amoxicillin")
    clear = client.get(f"{API}/production/milk-safety", headers=_h(client), params={"animal_id": LUNA}).json()
    assert clear["withdrawal_check"] == "clear" and clear["lactation_episode_id"]
