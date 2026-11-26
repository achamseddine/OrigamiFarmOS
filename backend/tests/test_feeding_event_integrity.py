"""Feeding event integrity (v0.8.7; audit 2026-11-25 I-7, I-12).

I-7 — what an animal ate cannot be more than what was put in front of it.
A component's `quantity_consumed` is in the component's unit, like
`quantity_offered`; it is compared after both are in the feed's stock unit
and stored in that unit. 5 kg offered / 9 kg consumed is refused (422)
before a gram leaves the store — on a new feeding, a correction and an
employee's correction request.

I-12 — one round of feed is not counted twice. A cow fed with her group at
06:00 and on her own at 06:05 is a possible duplicate (409 "Possible
duplicate: …") when she is one of the heads the group's ration feeds
(v0.8.6, one base ration per head) and the same feed is in both, within a
feeding round (an hour). The same holds the other way round (fed alone,
then the group). It is not asked for a feed she has a supplement of, for a
cow fed on her own ration, for another feed, for a refusal, or when the
group's head count already leaves her out. A real extra feeding is
recorded once the person confirms it (`confirm_additional_feeding`, or the
generic `confirm_duplicate`); the confirmation is audited.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.core.duplicates import PREFIX
from app.core.idempotency import HEADER, REPLAYED_HEADER
from app.domain import feed_models as fm
from app.domain import models
from tests.conftest import auth_headers

API = "/api/v1"
BEIRUT = ZoneInfo("Asia/Beirut")
UTC = timezone.utc
HERD = "grp-dairy-herd"               # Bella, Luna, Clover — DAIRY-HIGH
BELLA, LUNA, CLOVER, THUNDER = "cow-744", "cow-214", "cow-clover", "horse-h07"
MIX, ALFALFA, CONC, STRAW = "fp-dairy-mix", "fp-alfalfa", "fp-dairy-concentrate", "fp-wheat-straw"
WORKER = "karim.worker@origami.farm"
ACCOUNTANT = "nadine.acct@origami.farm"


def _h(client, email="rami@origami.farm"):
    return auth_headers(client, email)


# A fixed farm day for every round in these tests: two days back, so each
# time of that day is in the past whatever the clock says when they run, and
# the next day's 00:05 too (a deterministic clock, not "yesterday at" that
# moves). The demo farm's own rounds are at 08:00 and 19:00 (and Bella's
# supplement at 09:00); the rounds here keep an hour away from them.
FARM_DAY = datetime.now(UTC).astimezone(BEIRUT).date() - timedelta(days=2)
REASON = "Bella was still hungry after the round"


def _at(hour: int, minute: int = 0, *, next_day: bool = False) -> datetime:
    day = FARM_DAY + timedelta(days=1 if next_day else 0)
    return datetime(day.year, day.month, day.day, hour, minute, tzinfo=BEIRUT)


def _body(subject_type, subject_id, pid, qty, *, at=None, event_type="offered", consumed=None, unit=None, **extra):
    comp = {"feed_product_id": pid, "quantity_offered": qty}
    if consumed is not None:
        comp["quantity_consumed"] = consumed
    if unit is not None:
        comp["unit"] = unit
    body = {"subject_type": subject_type, "subject_id": subject_id, "event_type": event_type, "components": [comp], **extra}
    if at is not None:
        body["occurred_at"] = at.astimezone(UTC).isoformat()
    return body


def _post(client, body, headers=None):
    return client.post(f"{API}/feeding-events", json=body, headers=headers or _h(client))


def _on_hand(client, pid) -> float:
    return client.get(f"{API}/feed-products/{pid}", headers=_h(client)).json()["availability"]["on_hand"]


def _is_possible_duplicate(r) -> bool:
    return r.status_code == 409 and r.json()["detail"].startswith(PREFIX)


def _events(session, subject_id) -> list[fm.FeedingEvent]:
    session.expire_all()
    return list(session.scalars(select(fm.FeedingEvent).where(fm.FeedingEvent.subject_id == subject_id, fm.FeedingEvent.status == "recorded")))


def _confirmations(session, entity_id) -> list[models.Event]:
    session.expire_all()
    return list(session.scalars(select(models.Event).where(models.Event.entity_id == entity_id,
                                                           models.Event.event_type == "feeding_additional_confirmed")))


# =========================================================== I-7
class TestConsumedNeverExceedsOffered:
    def test_I7_5kg_offered_9kg_consumed_is_refused_and_nothing_moves(self, client: TestClient, db_session):
        session, _ = db_session
        before = _on_hand(client, ALFALFA)
        r = _post(client, _body("animal", THUNDER, ALFALFA, 5, consumed=9))
        assert r.status_code == 422, r.text
        assert "9" in r.json()["detail"] and "5" in r.json()["detail"] and "consumed" in r.json()["detail"].lower()
        assert _on_hand(client, ALFALFA) == before, "a refused feeding moves no stock"
        assert not [e for e in _events(session, THUNDER) if any(c.quantity_consumed == 9 for c in e.components)]

    def test_consumption_equal_to_the_offer_is_accepted(self, client: TestClient):
        r = _post(client, _body("animal", THUNDER, ALFALFA, 5, consumed=5))
        assert r.status_code == 201, r.text
        assert r.json()["components"][0]["quantity_consumed"] == 5

    def test_units_are_converted_before_comparing_and_storing(self, client: TestClient):
        """5000 g offered of a feed kept in kg, 4000 g eaten: 5 kg out of
        the store, 4 kg consumed — not 4000 kg."""
        before = _on_hand(client, ALFALFA)
        r = _post(client, _body("animal", THUNDER, ALFALFA, 5000, consumed=4000, unit="g"))
        assert r.status_code == 201, r.text
        comp = r.json()["components"][0]
        assert (comp["quantity_offered"], comp["quantity_consumed"], comp["unit"]) == (5, 4, "kg")
        assert round(before - _on_hand(client, ALFALFA), 3) == 5
        refused = _post(client, _body("animal", THUNDER, ALFALFA, 5000, consumed=9000, unit="g"))
        assert refused.status_code == 422, refused.text

    def test_a_consumption_split_over_two_lots_keeps_its_total(self, client: TestClient, db_session):
        """A feeding drawn from two lots splits what was eaten between them
        in proportion — in the stock unit, never more than each lot gave."""
        from app.services import feed_inventory_service as inv

        session, _ = db_session
        inv.receive(session, session.get(fm.FeedProduct, ALFALFA), quantity=50, unit_cost=0.3, lot_code="ALF-SPLIT",
                    source_type="purchased", user_id="user-rami")
        session.commit()
        lots = [l for l in client.get(f"{API}/feed-lots", params={"feed_product_id": ALFALFA}, headers=_h(client)).json() if l["quantity_on_hand"] > 0]
        first = min(l["quantity_on_hand"] for l in lots if l["lot_code"] != "ALF-SPLIT")
        offered = round(first + 4, 3)
        r = _post(client, _body("animal", THUNDER, ALFALFA, offered * 1000, consumed=(offered - 1) * 1000, unit="g"))
        assert r.status_code == 201, r.text
        comps = r.json()["components"]
        assert len(comps) >= 2
        assert round(sum(c["quantity_offered"] for c in comps), 3) == offered
        assert round(sum(c["quantity_consumed"] for c in comps), 3) == round(offered - 1, 3)
        assert all(c["quantity_consumed"] <= c["quantity_offered"] + 1e-9 for c in comps)

    def test_a_later_estimate_or_refusal_is_measured_against_the_days_offer(self, client: TestClient):
        """Session 01: an intake estimate recorded on its own later is not a
        second issue (no stock moves, nothing more is fed), and it cannot
        say more was eaten than was offered that farm day — in any unit.
        Refusals add up the same way."""
        before = _on_hand(client, ALFALFA)
        assert _post(client, _body("animal", THUNDER, ALFALFA, 5, at=_at(13, 0))).status_code == 201
        after_offer = _on_hand(client, ALFALFA)
        assert round(before - after_offer, 3) == 5
        for qty, unit in ((9, None), (9000, "g")):
            r = _post(client, _body("animal", THUNDER, ALFALFA, qty, unit=unit, at=_at(17, 0), event_type="consumed_estimate"))
            assert r.status_code == 422 and "offered" in r.json()["detail"], (qty, unit, r.text)
        ok = _post(client, _body("animal", THUNDER, ALFALFA, 4000, unit="g", at=_at(17, 0), event_type="consumed_estimate"))
        assert ok.status_code == 201, ok.text
        assert ok.json()["components"][0]["quantity_offered"] == 4 and ok.json()["components"][0]["unit"] == "kg"
        assert _on_hand(client, ALFALFA) == after_offer, "an estimate moves no stock"
        plan = client.get(f"{API}/livestock-subjects/{THUNDER}/feeding-plan", headers=_h(client)).json()
        fed = next(f["quantity"] for f in plan["fed_7d"] if f["feed_product_id"] == ALFALFA)
        assert fed == round(fed, 3) and not any(f["quantity"] == fed + 4 for f in plan["fed_7d"]), "not counted as fed"
        assert _post(client, _body("animal", THUNDER, ALFALFA, 3, at=_at(17, 30), event_type="refusal")).status_code == 201
        second = _post(client, _body("animal", THUNDER, ALFALFA, 2.5, at=_at(18, 0), event_type="refusal"))
        assert second.status_code == 422 and "refused today" in second.json()["detail"], "5.5 kg refused of 5 kg offered"
        assert _post(client, _body("animal", THUNDER, ALFALFA, 2, at=_at(18, 0), event_type="refusal")).status_code == 201, "5 of 5 is possible"
        # A day with nothing offered on record cannot be judged: the estimate stands.
        assert _post(client, _body("animal", THUNDER, ALFALFA, 2, at=_at(13, 0, next_day=True) - timedelta(days=2),
                                   event_type="consumed_estimate")).status_code == 201

    def test_an_intake_estimate_cannot_exceed_its_offer_either(self, client: TestClient):
        r = _post(client, _body("group", HERD, MIX, 5, consumed=9, event_type="consumed_estimate"))
        assert r.status_code == 422, r.text

    def test_a_correction_cannot_record_more_eaten_than_given(self, client: TestClient):
        event = _post(client, _body("animal", THUNDER, ALFALFA, 6)).json()
        fix = {"reason": "measured at the bunk", "components": [{"feed_product_id": ALFALFA, "quantity_offered": 5, "quantity_consumed": 9}]}
        r = client.post(f"{API}/feeding-events/{event['id']}/correct", json=fix, headers=_h(client))
        assert r.status_code == 422, r.text
        assert client.get(f"{API}/feeding-events", params={"subject_id": THUNDER}, headers=_h(client)).json()[0]["status"] == "recorded", \
            "the original stays as it was"

    def test_an_employee_correction_request_is_refused_at_once(self, client: TestClient):
        worker = _h(client, WORKER)
        event = _post(client, _body("animal", THUNDER, ALFALFA, 7), headers=worker).json()
        fix = {"components": [{"feed_product_id": ALFALFA, "quantity_offered": 5, "quantity_consumed": 9}]}
        r = client.post(f"{API}/approval-requests", json={"kind": "feeding_correction", "target_id": event["id"], "payload": fix,
                                                          "reason": "measured"}, headers=worker)
        assert r.status_code == 422, r.text


# =========================================================== I-12
def _since(days: int) -> str:
    return (datetime.now(UTC) - timedelta(days=days)).isoformat()


def _assign(client, subject_id, **body):
    r = client.post(f"{API}/livestock-subjects/{subject_id}/feeding-assignments", json=body, headers=_h(client))
    assert r.status_code == 201, r.text
    return r.json()


@pytest.fixture()
def herd_on_ration(client):
    """The herd on DAIRY-HIGH and Bella's +2 kg concentrate supplement,
    both in force for four days (the demo farm's start now), so
    yesterday's rounds are read with them."""
    _assign(client, HERD, program_id="prog-dairy-high", valid_from=_since(4))
    _assign(client, BELLA, assignment_type="supplement", feed_product_id=CONC, quantity_per_head=2, reason="High yield", valid_from=_since(4))


@pytest.mark.usefixtures("herd_on_ration")
class TestOneRoundIsNotCountedTwice:
    def test_I12_a_cow_fed_with_her_group_at_0600_then_alone_at_0605(self, client: TestClient, db_session):
        session, _ = db_session
        group = _post(client, _body("group", HERD, MIX, 30, at=_at(6, 0), event_type="delivered"))
        assert group.status_code == 201, group.text
        before = _on_hand(client, MIX)
        alone = _post(client, _body("animal", BELLA, MIX, 10, at=_at(6, 5)))
        assert _is_possible_duplicate(alone), alone.text
        detail = alone.json()["detail"]
        assert "Bella" in detail and "Dairy Herd" in detail and "06:00" in detail
        assert _on_hand(client, MIX) == before, "nothing left the store"
        assert not _events(session, BELLA) or all(ensure_minutes(e) != (6, 5) for e in _events(session, BELLA))

        confirmed = _post(client, _body("animal", BELLA, MIX, 10, at=_at(6, 5), confirm_additional_feeding=True, additional_feeding_reason=REASON))
        assert confirmed.status_code == 201, confirmed.text
        assert round(before - _on_hand(client, MIX), 3) == 10
        audit = _confirmations(session, BELLA)
        assert len(audit) == 1 and audit[0].payload_json["overlaps"][0]["feeding_event_id"] == group.json()["id"]
        assert audit[0].payload_json["feeding_event_id"] == confirmed.json()["id"] and audit[0].created_by == "user-rami"

    def test_a_confirmation_says_why_and_the_reason_is_kept(self, client: TestClient, db_session):
        """Session 01: an extra feeding is confirmed with a reason — refused
        (422, nothing issued) without one; kept on the audit record and on
        the feeding itself, so the manager reads why."""
        session, _ = db_session
        assert _post(client, _body("group", HERD, MIX, 30, at=_at(6, 0), event_type="delivered")).status_code == 201
        before = _on_hand(client, MIX)
        for flag in ("confirm_additional_feeding", "confirm_duplicate"):
            for reason in (None, "   "):
                extra = {flag: True, **({"additional_feeding_reason": reason} if reason is not None else {})}
                r = _post(client, _body("animal", BELLA, MIX, 10, at=_at(6, 5), **extra))
                assert r.status_code == 422 and "why" in r.json()["detail"].lower(), (flag, reason, r.text)
        assert _on_hand(client, MIX) == before, "nothing left the store"
        r = _post(client, _body("animal", BELLA, MIX, 10, at=_at(6, 5), confirm_additional_feeding=True, additional_feeding_reason=REASON))
        assert r.status_code == 201, r.text
        assert REASON in (r.json()["notes"] or "")
        audit = _confirmations(session, BELLA)[0]
        assert audit.payload_json["reason"] == REASON
        # No overlap, no reason needed.
        assert _post(client, _body("animal", THUNDER, ALFALFA, 4, at=_at(6, 5))).status_code == 201

    def test_the_other_way_round_alone_first_then_the_group(self, client: TestClient, db_session):
        session, _ = db_session
        assert _post(client, _body("animal", BELLA, MIX, 10, at=_at(6, 0))).status_code == 201
        group = _post(client, _body("group", HERD, MIX, 30, at=_at(6, 5), event_type="delivered"))
        assert _is_possible_duplicate(group), group.text
        assert "Bella" in group.json()["detail"]
        # The group's feeding was for the two others: the head count says so, nothing is asked.
        partial = _post(client, _body("group", HERD, MIX, 20, at=_at(6, 5), event_type="delivered", head_count=2))
        assert partial.status_code == 201, partial.text
        assert not _confirmations(session, HERD)

    def test_the_generic_duplicate_confirmation_also_records_it(self, client: TestClient, db_session):
        session, _ = db_session
        assert _post(client, _body("group", HERD, MIX, 30, at=_at(6, 0), event_type="delivered")).status_code == 201
        r = _post(client, _body("animal", BELLA, MIX, 10, at=_at(6, 5), confirm_duplicate=True, additional_feeding_reason=REASON))
        assert r.status_code == 201, r.text
        assert _confirmations(session, BELLA)[0].payload_json["confirmed_with"] == "confirm_duplicate"

    def test_a_supplement_is_not_asked(self, client: TestClient):
        """Bella's +2 kg concentrate is on top of the herd's ration."""
        assert _post(client, _body("group", HERD, CONC, 9, at=_at(6, 0), event_type="delivered")).status_code == 201
        assert _post(client, _body("animal", BELLA, CONC, 2, at=_at(6, 5))).status_code == 201
        assert _is_possible_duplicate(_post(client, _body("animal", LUNA, CONC, 2, at=_at(6, 6)))), \
            "Luna has no supplement: her concentrate came with the herd"

    def test_a_cow_on_her_own_ration_is_not_in_the_groups_feeding(self, client: TestClient):
        _assign(client, CLOVER, program_id="prog-dairy-medium", valid_from=_since(4))
        assert _post(client, _body("group", HERD, MIX, 20, at=_at(6, 0), event_type="delivered")).status_code == 201
        assert _post(client, _body("animal", CLOVER, MIX, 8, at=_at(6, 5))).status_code == 201

    def test_another_feed_a_refusal_or_another_round_is_not_asked(self, client: TestClient):
        # The demo farm's own rounds are at 08:00 and 19:00: these are at 13:00.
        assert _post(client, _body("group", HERD, ALFALFA, 9, at=_at(13, 0), event_type="delivered")).status_code == 201
        assert _post(client, _body("animal", BELLA, STRAW, 2, at=_at(13, 5))).status_code == 201, "another feed"
        assert _post(client, _body("animal", BELLA, ALFALFA, 1, at=_at(13, 10), event_type="refusal")).status_code == 201, \
            "a refusal moves nothing"
        assert _post(client, _body("animal", BELLA, ALFALFA, 3, at=_at(14, 30))).status_code == 201, "the next round"
        assert _post(client, _body("group", HERD, MIX, 30, at=_at(15, 30), event_type="refusal")).status_code == 201
        assert _post(client, _body("animal", LUNA, MIX, 9, at=_at(15, 35))).status_code == 201, "a group refusal fed nobody"

    def test_a_round_across_midnight_is_still_one_round(self, client: TestClient):
        """23:50 and 00:05 in Beirut are two farm days but one round."""
        assert _post(client, _body("group", HERD, MIX, 30, at=_at(23, 50), event_type="delivered")).status_code == 201
        assert _is_possible_duplicate(_post(client, _body("animal", LUNA, MIX, 10, at=_at(0, 5, next_day=True))))

    def test_one_ration_per_head_and_the_ledger_after_a_confirmed_extra(self, client: TestClient):
        today = datetime.now(UTC).astimezone(BEIRUT).date()
        at_group = datetime.now(UTC) - timedelta(minutes=20)
        at_cow = datetime.now(UTC) - timedelta(minutes=15)
        assert _post(client, _body("group", HERD, MIX, 31, at=at_group, event_type="delivered")).status_code == 201
        r = _post(client, _body("animal", LUNA, MIX, 3, at=at_cow, confirm_additional_feeding=True, additional_feeding_reason=REASON))
        assert r.status_code == 201, r.text
        plan = client.get(f"{API}/feeding-plan/today", params={"day": today.isoformat()}, headers=_h(client)).json()
        herd = next(l for l in plan["lines"] if l["subject_id"] == HERD)
        assert herd["head_count"] == 3, "an extra feeding does not change who the ration feeds"
        fed_luna = sum(f["quantity"] for u in plan["unplanned_fed"] if u["subject_id"] == LUNA for f in u["fed"] if f["feed_product_id"] == MIX)
        assert fed_luna == 3, "the extra is hers, not the group's"
        integrity = client.get(f"{API}/feed-inventory/integrity", headers=_h(client))
        assert integrity.status_code == 200, integrity.text
        row = next(p for p in integrity.json()["products"] if p["feed_product_id"] == MIX)
        assert row["consistent"], row


@pytest.mark.usefixtures("herd_on_ration")
class TestWhoConfirmsAndReplays:
    def test_a_worker_is_asked_and_confirms_her_own_round(self, client: TestClient, db_session):
        session, _ = db_session
        worker = _h(client, WORKER)
        assert _post(client, _body("group", HERD, MIX, 30, at=_at(6, 0), event_type="delivered"), headers=worker).status_code == 201
        asked = _post(client, _body("animal", BELLA, MIX, 10, at=_at(6, 5)), headers=worker)
        assert _is_possible_duplicate(asked), asked.text
        done = _post(client, _body("animal", BELLA, MIX, 10, at=_at(6, 5), confirm_additional_feeding=True, additional_feeding_reason=REASON), headers=worker)
        assert done.status_code == 201, done.text
        assert done.json()["recorded_by"] == "user-worker-1"
        assert _confirmations(session, BELLA)[0].created_by == "user-worker-1"

    def test_someone_who_cannot_record_feedings_cannot_confirm_one(self, client: TestClient):
        r = _post(client, _body("animal", BELLA, MIX, 10, confirm_additional_feeding=True, additional_feeding_reason=REASON), headers=_h(client, ACCOUNTANT))
        assert r.status_code == 403, r.text

    def test_a_replay_of_the_confirmed_feeding_records_it_once(self, client: TestClient, db_session):
        """The tablet resends a refused write with the same key once the
        person confirms (the refusal is never stored); a later replay of the
        same key is answered from the stored response."""
        session, _ = db_session
        h = _h(client)
        assert _post(client, _body("group", HERD, MIX, 30, at=_at(6, 0), event_type="delivered")).status_code == 201
        key = {**h, HEADER: "outbox-feeding-bella-0605"}
        body = _body("animal", BELLA, MIX, 10, at=_at(6, 5))
        assert _is_possible_duplicate(client.post(f"{API}/feeding-events", json=body, headers=key))
        first = client.post(f"{API}/feeding-events", json={**body, "confirm_additional_feeding": True, "additional_feeding_reason": REASON}, headers=key)
        assert first.status_code == 201, first.text
        again = client.post(f"{API}/feeding-events", json={**body, "confirm_additional_feeding": True, "additional_feeding_reason": REASON}, headers=key)
        assert again.headers.get(REPLAYED_HEADER) == "true" and again.json()["id"] == first.json()["id"]
        assert len([e for e in _events(session, BELLA) if e.id == first.json()["id"]]) == 1
        assert len(_confirmations(session, BELLA)) == 1

    def test_an_offline_feeding_replayed_after_the_groups_is_asked_with_its_own_time(self, client: TestClient):
        """A tablet without signal fed Bella at 06:05; the herd's 06:00
        feeding reached the server first from another device. Replayed
        later, the queued entry keeps 06:05 and is asked about (the sync
        panel's "Record anyway" resends it confirmed)."""
        assert _post(client, _body("group", HERD, MIX, 30, at=_at(6, 0), event_type="delivered")).status_code == 201
        queued = {**_body("animal", BELLA, MIX, 10, at=_at(6, 5)), "notes": "offline"}
        replay = client.post(f"{API}/feeding-events", json=queued, headers={**_h(client), HEADER: "outbox-offline-1"})
        assert _is_possible_duplicate(replay), replay.text
        resent = client.post(f"{API}/feeding-events", json={**queued, "confirm_duplicate": True, "additional_feeding_reason": "Recorded on the tablet offline"}, headers={**_h(client), HEADER: "outbox-offline-1"})
        assert resent.status_code == 201, resent.text
        assert resent.json()["occurred_at"].startswith(_at(6, 5).astimezone(UTC).strftime("%Y-%m-%dT%H:%M"))


def ensure_minutes(e: fm.FeedingEvent) -> tuple[int, int]:
    t = e.occurred_at if e.occurred_at.tzinfo else e.occurred_at.replace(tzinfo=UTC)
    local = t.astimezone(BEIRUT)
    return local.hour, local.minute
