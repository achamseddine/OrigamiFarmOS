"""Milk entered on a tablet that was offline is cleared by the server
(audit I-11, I-16; ADR-008).

The mandatory scenario: tablet A loses the farm server; the veterinarian
records a treatment with a milk withdrawal on tablet B; tablet A, still on
what it knew before, records 10 L of Bella's milk as stored. On tablet A
that milk waits for the server's safety check (the app's side, tested in
mobile/flutter_app/test/production/offline_milk_test.dart). When tablet A
reconnects, its queued write carries `X-Offline-Recorded-At`; the server
judges the milking at its own time from the treatment history — not from
what the tablet knew — and:

  clear       keeps it saleable, as a live entry;
  uncertain   holds it for review, as a live entry;
  withdrawal  keeps the record (the milk was milked, and may be in the
              tank) but held: never in the saleable tank, the collector's
              handover or a sale, never released, the manager and the
              veterinarian told — where a live entry is refused (422) so
              the person at the parlour withholds it;
  refused     a milking the animal cannot have given (dried off, not on
              the farm) is still refused, and the tablet keeps showing it.

The milking keeps its own date and time, and the farm's clock (its time
zone, with the daylight-saving changes ahead) is given to the tablet so the
morning and the afternoon milking are the farm's, not the device's.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest
from sqlalchemy import func, select

from app.domain import milk_models as mm
from app.domain import models
from app.domain import reproduction_models as rm
from tests.conftest import auth_headers

API = "/api/v1"
BELLA, CLOVER, LUNA = "cow-744", "cow-clover", "cow-214"
VET, WORKER, MANAGER = "layla.vet@origami.farm", "karim.worker@origami.farm", "rami@origami.farm"
OFFLINE = "X-Offline-Recorded-At"


def _now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def _iso(t: datetime) -> str:
    return t.isoformat()


def _h(client, email=MANAGER, **extra):
    return {**auth_headers(client, email), **extra}


def _treat_from_tablet_b(client, session, animal_id, *, start, until):
    """The veterinarian, on tablet B, while tablet A is offline."""
    vet = session.scalar(select(models.User.id).where(models.User.email == VET))
    r = client.post(f"{API}/health/treatments", headers=_h(client, VET), json={
        "entity_type": "animal", "entity_id": animal_id, "medication": "Oxytetracycline LA", "dose": "20 mL", "route": "IM",
        "responsible_user_id": vet, "start_at": _iso(start), "withdrawal_until": _iso(until), "confirm_duplicate": True})
    assert r.status_code == 201, r.text
    return r.json()


def _milk_from_tablet_a(client, animal_id, milked_at, *, liters=10.0, destination="stored", queued_at=None, key=None, email=WORKER):
    """Tablet A's queued write, replayed when it reconnects: the body it
    built offline, the key it kept, and when it was recorded offline."""
    headers = _h(client, email)
    if queued_at is not None:
        headers[OFFLINE] = _iso(queued_at)
    if key is not None:
        headers["Idempotency-Key"] = key
    return client.post(f"{API}/production/milk", headers=headers, json={
        "animal_id": animal_id, "session": "morning", "liters": liters, "destination": destination,
        "recorded_at": _iso(milked_at), "confirm_duplicate": True})


def _tank(client) -> float:
    return client.get(f"{API}/production/milk-tank", headers=_h(client)).json()["balance_l"]


def _held_ids(session, animal_id) -> set[str]:
    """Held records of the animal. The demo farm's own milking of the last
    hours falls inside a withdrawal started three hours ago and is held too,
    so a test about tablet A's write counts the rows that write added."""
    session.expire_all()
    return set(session.scalars(select(models.MilkRecord.id).where(models.MilkRecord.animal_id == animal_id,
                                                                  models.MilkRecord.release_status == "held")))


def _record(session, record_id) -> models.MilkRecord:
    session.expire_all()
    return session.get(models.MilkRecord, record_id)


class TestTheMandatoryScenario:
    def test_tablet_a_s_10_l_under_the_withdrawal_tablet_b_recorded_is_kept_but_held(self, client, db_session):
        session, _ = db_session
        now = _now()
        treated_at, milked_at = now - timedelta(hours=3), now - timedelta(hours=2)
        # 1-2. Tablet A is offline; the vet records the treatment on tablet B.
        _treat_from_tablet_b(client, session, BELLA, start=treated_at, until=now + timedelta(days=4))
        tank = _tank(client)
        sales = session.scalar(select(func.count(mm.MilkSale.id)))
        # 3. Tablet A records 10 L as stored, from what it knew before; it
        # reaches the server when tablet A reconnects, an hour later.
        r = _milk_from_tablet_a(client, BELLA, milked_at, queued_at=milked_at + timedelta(minutes=1), key="tablet-a-bella-1")
        # 5. The server judged it from the treatment history: kept, held.
        assert r.status_code == 201, r.text
        body = r.json()
        assert (body["withdrawal_check"], body["release_status"]) == ("withdrawal", "held")
        assert "offline" in body["safety_note"] and "withdrawal" in body["safety_note"].lower()
        rec = _record(session, body["id"])
        # The milking keeps its own time, not the moment it reached the server.
        assert abs((rec.recorded_at.replace(tzinfo=timezone.utc) - milked_at).total_seconds()) < 1
        assert (rec.destination, rec.liters) == ("stored", 10.0), "where the milk went is a fact; whether it may be sold is the status"
        # 4. Not in the saleable tank, the collector's handover or a sale.
        assert _tank(client) == pytest.approx(tank)
        h = _h(client)
        client.put(f"{API}/production/milk-routine", headers=h, json={"collector_name": "Abu Ali", "collector_price": 0.5, "collector_currency": "USD"})
        over = client.post(f"{API}/production/milk-handovers", headers=h, json={
            "session": "morning", "calves_l": 0, "collected_l": tank + 10, "confirm_duplicate": True})
        assert over.status_code == 422 and "tank holds" in over.json()["detail"], over.text
        sale = client.post(f"{API}/production/milk-sales", headers=h, json={"liters": tank + 10, "price_per_liter": 0.5, "buyer_name": "Dairy"})
        assert sale.status_code in (409, 422), sale.text
        assert session.scalar(select(func.count(mm.MilkSale.id))) == sales, "no revenue from it"
        # The manager and the veterinarian are told the tank may hold it.
        session.expire_all()
        told = session.scalars(select(models.Notification).where(models.Notification.notification_type == "milk_safety",
                                                                 models.Notification.entity_id == BELLA)).all()
        assert {n.user_id for n in told} >= {"user-rami", "user-vet-1", "user-worker-1"}, "and the worker who saw \"saved\" on tablet A"
        assert any("tank" in (n.description or "") for n in told)

    def test_the_review_cannot_release_it_and_withholding_it_is_on_file(self, client, db_session):
        session, _ = db_session
        now = _now()
        _treat_from_tablet_b(client, session, BELLA, start=now - timedelta(hours=3), until=now + timedelta(days=4))
        body = _milk_from_tablet_a(client, BELLA, now - timedelta(hours=2), queued_at=now - timedelta(hours=2)).json()
        url = f"{API}/production/milk/{body['id']}/review"
        r = client.post(url, headers=_h(client, VET), json={"decision": "release", "note": "the tank looked fine"})
        assert r.status_code == 409 and "cannot be released" in r.json()["detail"], r.text
        r = client.post(url, headers=_h(client, VET), json={"decision": "withhold", "note": "Tank emptied and discarded at 10:00"})
        assert r.status_code == 200, r.text
        assert (r.json()["destination"], r.json()["release_status"]) == ("withheld", "not_for_sale")
        assert session.scalar(select(func.count(models.AuditLog.id)).where(models.AuditLog.entity_id == body["id"],
                                                                         models.AuditLog.action == "milk_record_corrected")) == 1

    def test_the_replay_is_sent_once_however_often_tablet_a_retries(self, client, db_session):
        session, _ = db_session
        now = _now()
        _treat_from_tablet_b(client, session, BELLA, start=now - timedelta(hours=3), until=now + timedelta(days=4))
        before = _held_ids(session, BELLA)
        first = _milk_from_tablet_a(client, BELLA, now - timedelta(hours=2), queued_at=now - timedelta(hours=2), key="tablet-a-once")
        again = _milk_from_tablet_a(client, BELLA, now - timedelta(hours=2), queued_at=now - timedelta(hours=2), key="tablet-a-once")
        assert (first.status_code, again.status_code) == (201, 201)
        assert first.json()["id"] == again.json()["id"]
        assert _held_ids(session, BELLA) - before == {first.json()["id"]}

    def test_at_the_parlour_the_same_milking_is_still_refused_so_it_is_withheld(self, client, db_session):
        session, _ = db_session
        now = _now()
        _treat_from_tablet_b(client, session, BELLA, start=now - timedelta(hours=3), until=now + timedelta(days=4))
        live = _milk_from_tablet_a(client, BELLA, now - timedelta(minutes=5))
        assert live.status_code == 422 and "withheld" in live.json()["detail"], live.text
        assert _milk_from_tablet_a(client, BELLA, now - timedelta(minutes=5), destination="withheld").json()["release_status"] == "not_for_sale"


class TestEveryOtherAnswer:
    def test_clear_milk_entered_offline_counts_in_the_tank_as_a_live_entry(self, client, db_session):
        tank = _tank(client)
        now = _now()
        r = _milk_from_tablet_a(client, CLOVER, now - timedelta(hours=2), queued_at=now - timedelta(hours=2))
        assert r.status_code == 201, r.text
        assert (r.json()["withdrawal_check"], r.json()["release_status"]) == ("clear", "saleable")
        assert _tank(client) == pytest.approx(tank + 10)

    def test_milk_entered_offline_as_withheld_stays_withheld(self, client, db_session):
        session, _ = db_session
        now = _now()
        _treat_from_tablet_b(client, session, BELLA, start=now - timedelta(hours=3), until=now + timedelta(days=4))
        r = _milk_from_tablet_a(client, BELLA, now - timedelta(hours=2), destination="withheld", queued_at=now - timedelta(hours=2))
        assert (r.status_code, r.json()["release_status"]) == (201, "not_for_sale")

    def test_a_milking_she_cannot_have_given_is_still_refused_so_the_tablet_shows_it(self, client, db_session):
        session, _ = db_session
        now = _now()
        assert session.scalars(select(rm.LactationEpisode).where(rm.LactationEpisode.animal_id == LUNA,
                                                                 rm.LactationEpisode.status == "active")).first() is not None
        r = client.post(f"{API}/animals/{LUNA}/dry-off", headers=_h(client), json={"ended_at": _iso(now - timedelta(days=1))})
        assert r.status_code == 200, r.text
        refused = _milk_from_tablet_a(client, LUNA, now - timedelta(hours=2), queued_at=now - timedelta(hours=2))
        assert refused.status_code in (409, 422) and "dried off" in refused.json()["detail"], refused.text

    def test_the_other_order_tablet_a_first_then_the_treatment_backdated_holds_it(self, client, db_session):
        """Tablet A reconnects first (clear then); tablet B, offline too,
        syncs a treatment that began before the milking: the milk is held."""
        session, _ = db_session
        now = _now()
        body = _milk_from_tablet_a(client, BELLA, now - timedelta(hours=2), queued_at=now - timedelta(hours=2)).json()
        assert body["release_status"] == "saleable"
        _treat_from_tablet_b(client, session, BELLA, start=now - timedelta(hours=3), until=now + timedelta(days=4))
        assert _record(session, body["id"]).release_status == "held"

    def test_a_date_sent_by_the_tablet_that_is_not_a_date_is_not_trusted(self, client, db_session):
        session, _ = db_session
        now = _now()
        _treat_from_tablet_b(client, session, BELLA, start=now - timedelta(hours=3), until=now + timedelta(days=4))
        headers = _h(client, WORKER, **{OFFLINE: "yesterday-ish"})
        r = client.post(f"{API}/production/milk", headers=headers, json={
            "animal_id": BELLA, "session": "morning", "liters": 10, "destination": "stored", "recorded_at": _iso(now - timedelta(hours=2)),
            "confirm_duplicate": True})
        assert r.status_code == 422, "not a time it was entered offline: judged as a live entry"


class TestTheFarmsClock:
    def test_the_tablet_gets_the_farm_s_zone_and_its_changes_ahead(self, client):
        clock = client.get(f"{API}/farms/me", headers=_h(client, WORKER)).json()["clock"]
        assert clock["timezone"] == "Asia/Beirut"
        offsets = clock["offsets"]
        assert len(offsets) >= 2, "Lebanon changes its clocks within a year"
        tz = ZoneInfo("Asia/Beirut")
        starts = [datetime.fromisoformat(o["from"]) for o in offsets]
        assert starts == sorted(starts)
        for o, start in zip(offsets, starts):
            # Each entry is the offset from the instant it takes effect...
            assert o["offset_minutes"] == start.astimezone(tz).utcoffset().total_seconds() / 60
        for prev, start in zip(starts, starts[1:]):
            # ... and changes exactly then: a minute before, the previous one.
            before = (start - timedelta(minutes=1)).astimezone(tz).utcoffset()
            assert before != start.astimezone(tz).utcoffset()
            assert start - prev > timedelta(days=30)

    def test_a_farm_without_a_zone_runs_on_utc(self, client, db_session):
        session, _ = db_session
        farm = session.get(models.Farm, "farm-origami")
        farm.timezone = ""
        session.commit()
        clock = client.get(f"{API}/farms/me", headers=_h(client)).json()["clock"]
        assert clock["timezone"] == "UTC" and [o["offset_minutes"] for o in clock["offsets"]] == [0]


class TestTheOlderSyncPush:
    def test_a_batch_pushed_by_an_offline_tablet_is_cleared_the_same_way(self, client, db_session):
        session, _ = db_session
        now = _now()
        _treat_from_tablet_b(client, session, BELLA, start=now - timedelta(hours=3), until=now + timedelta(days=4))
        tank = _tank(client)
        before = _held_ids(session, BELLA)
        t = now - timedelta(hours=2)
        out = client.post(f"{API}/sync/push", headers=_h(client), json={"farm_id": "farm-origami", "device_id": "tablet-a", "items": [
            {"idempotency_key": "push-bella", "operation": "create", "entity_type": "animal", "entity_id": BELLA,
             "payload": {"session": "morning", "liters": 10, "destination": "stored"}, "client_created_at": _iso(t)},
        ]}).json()
        assert [r["status"] for r in out["results"]] == ["accepted"], out
        added = _held_ids(session, BELLA) - before
        assert len(added) == 1
        held = [_record(session, i) for i in added]
        assert held[0].withdrawal_check == "withdrawal"
        assert _tank(client) == pytest.approx(tank)
