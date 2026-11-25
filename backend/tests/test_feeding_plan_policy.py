"""One feeding policy for the plan, the reports and the forecast (v0.8.6;
audit 2026-11-25 I-4 / AF-01, I-5 / AF-05, I-6 / NEW-6).

Base allowance — each head gets exactly one base ration:
  1. its own explicit program;
  2. else the program of a status group it is in (pregnant, open, in milk,
     dry — the more specific ration);
  3. else the program of its herd / pen (its exclusive group);
  4. else the program of any other group it is in.
A group's plan counts only the heads it actually feeds that way. An
override replaces one product's quantity for that head (and plans the head
on its own); a supplement adds on top; a restriction removes a product.

Fed — only what moved stock: an `offered` / `delivered` feeding. A refusal
or a consumption estimate is recorded, shown apart, and never counted as fed.

Days — every "today", "yesterday" and day-by-day figure is the farm's
calendar day in its own time zone (Asia/Beirut on the demo farm), daylight
saving included.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi.testclient import TestClient

from app.services import farm_time
from app.services import feed_forecast_service as forecast
from tests.conftest import auth_headers

API = "/api/v1"
BEIRUT = ZoneInfo("Asia/Beirut")
UTC = timezone.utc
HERD = "grp-dairy-herd"            # Bella, Luna, Clover — DAIRY-HIGH, 2 feedings a day
PREGNANT = "grp-cows-pregnant"     # status group (rule PREGNANT): Bella
BELLA, LUNA, CLOVER = "cow-744", "cow-214", "cow-clover"
THUNDER = "horse-h07"
LAYERS, HEN = "flock-layer", "hen-247"
MIX, ALFALFA, CONC, STRAW = "fp-dairy-mix", "fp-alfalfa", "fp-dairy-concentrate", "fp-wheat-straw"
# DAIRY-HIGH per head per day: 2 × (10 mix, 3 alfalfa, 3 concentrate).
HIGH = {MIX: 20.0, ALFALFA: 6.0, CONC: 6.0}
# DAIRY-MEDIUM: 2 × (8, 3, 2).
MEDIUM = {MIX: 16.0, ALFALFA: 6.0, CONC: 4.0}
BELLA_SUPPLEMENT = 2.0             # seeded: +2 kg concentrate a day


def _h(client):
    return auth_headers(client)


def _plan(client, **params):
    r = client.get(f"{API}/feeding-plan/today", headers=_h(client), params=params)
    assert r.status_code == 200, r.text
    return r.json()


def _subject_plan(client, sid):
    r = client.get(f"{API}/livestock-subjects/{sid}/feeding-plan", headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()


def _line(plan, sid):
    return next((l for l in plan["lines"] if l["subject_id"] == sid), None)


def _targets(line) -> dict[str, float]:
    return {t["feed_product_id"]: t["daily_total"] for t in line["daily_targets"]} if line else {}


def _species_total(plan, species, pid) -> float:
    """What the plan asks for one species — every line of it."""
    return round(sum(_targets(l).get(pid, 0.0) for l in plan["lines"] if l["species"] == species), 3)


def _total(plan, pid, key="daily_total") -> float:
    return next((t[key] for t in plan["totals"] if t["feed_product_id"] == pid), 0.0)


def _fed(line, pid) -> float:
    return next((f["quantity"] for f in (line or {}).get("fed", []) if f["feed_product_id"] == pid), 0.0)


def _fed_to(plan, sid, pid) -> float:
    """What a subject was fed that day, planned or not."""
    rows = [l for l in plan["lines"] + plan["unplanned_fed"] if l["subject_id"] == sid]
    return round(sum(_fed(r, pid) for r in rows), 3)


def _per_head_sum(client, animal_ids, pid) -> float:
    """Each cow's own effective ration, summed — what the herd should get."""
    total = 0.0
    for a in animal_ids:
        total += next((t["daily_total"] for t in _subject_plan(client, a)["daily_targets"] if t["feed_product_id"] == pid), 0.0)
    return round(total, 3)


def _assign(client, subject_id, **body):
    r = client.post(f"{API}/livestock-subjects/{subject_id}/feeding-assignments", headers=_h(client), json=body)
    assert r.status_code == 201, r.text
    return r.json()


def _feed(client, subject_type, subject_id, pid, qty, *, event_type="offered", at: datetime | None = None, **extra):
    body = {"subject_type": subject_type, "subject_id": subject_id, "event_type": event_type,
            "components": [{"feed_product_id": pid, "quantity_offered": qty}], **extra}
    if at is not None:
        body["occurred_at"] = at.astimezone(UTC).isoformat()
    r = client.post(f"{API}/feeding-events", headers=_h(client), json=body)
    assert r.status_code == 201, r.text
    return r.json()


def _farm_today() -> date:
    return datetime.now(UTC).astimezone(BEIRUT).date()


def _local(day: date, hour: int, minute: int = 0, *, fold: int = 0) -> datetime:
    return datetime(day.year, day.month, day.day, hour, minute, tzinfo=BEIRUT, fold=fold)


# ===================================================== I-4: one base per head
class TestOneBaseAllowancePerHead:
    def test_AF01_a_cow_with_her_own_ration_is_not_fed_twice(self, client: TestClient):
        """The 3-head dairy herd; Clover is put on her own ration. Before
        v0.8.6 the herd still counted 3 heads and Clover's line added her
        base ration again: 76 kg of dairy mix for 3 cows that eat 56."""
        before = _plan(client)
        assert _line(before, HERD)["head_count"] == 3
        _assign(client, CLOVER, program_id="prog-dairy-medium")

        plan = _plan(client)
        herd = _line(plan, HERD)
        assert herd["head_count"] == 2 and herd["member_count"] == 3
        assert [(e["animal_id"], e["reason"]) for e in herd["excluded_heads"]] == [(CLOVER, "own_program")]
        assert _targets(herd) == {pid: q * 2 for pid, q in HIGH.items()}
        clover = _line(plan, CLOVER)
        assert clover["basis"] == "own_program" and _targets(clover) == MEDIUM
        # One base allowance per head plus Bella's genuine supplement.
        assert _species_total(plan, "cow", MIX) == 2 * 20 + 16 == 56
        assert _species_total(plan, "cow", ALFALFA) == 3 * 6 == 18
        assert _species_total(plan, "cow", CONC) == 2 * 6 + 4 + BELLA_SUPPLEMENT == 18
        for pid in (MIX, ALFALFA, CONC):
            assert _species_total(plan, "cow", pid) == _per_head_sum(client, (BELLA, LUNA, CLOVER), pid)
        # The farm totals the feed room reads say the same.
        assert _total(plan, MIX) == 56

    def test_a_supplement_adds_on_top_and_keeps_her_in_her_group(self, client: TestClient):
        plan = _plan(client)
        assert _line(plan, HERD)["head_count"] == 3, "a supplement does not take Bella out of the herd's ration"
        bella = _line(plan, BELLA)
        assert bella["basis"] == "supplement_only" and _targets(bella) == {CONC: BELLA_SUPPLEMENT}
        assert _species_total(plan, "cow", CONC) == 3 * 6 + 2 == _per_head_sum(client, (BELLA, LUNA, CLOVER), CONC)

    def test_an_override_replaces_her_quantity_and_she_is_planned_once(self, client: TestClient):
        _assign(client, LUNA, assignment_type="override", feed_product_id=ALFALFA, quantity_per_head=4, reason="Body condition")
        plan = _plan(client)
        herd = _line(plan, HERD)
        assert herd["head_count"] == 2 and herd["excluded_heads"][0]["reason"] == "own_override"
        luna = _line(plan, LUNA)
        assert luna["basis"] == "adjusted_group_ration"
        assert _targets(luna) == {MIX: 20.0, ALFALFA: 4.0, CONC: 6.0}, "the group's ration with her quantity replaced"
        assert _species_total(plan, "cow", ALFALFA) == 2 * 6 + 4 == _per_head_sum(client, (BELLA, LUNA, CLOVER), ALFALFA)
        assert _species_total(plan, "cow", MIX) == 60, "the override changes alfalfa only"

    def test_an_override_of_a_feed_not_in_the_ration_says_so(self, client: TestClient):
        _assign(client, LUNA, assignment_type="override", feed_product_id=STRAW, quantity_per_head=3, reason="Fibre")
        p = _subject_plan(client, LUNA)
        assert any("not in the ration" in w for w in p["review"]["warnings"])
        assert all(t["feed_product_id"] != STRAW for t in p["daily_targets"])

    def test_a_restriction_takes_the_feed_from_her_only(self, client: TestClient):
        _assign(client, BELLA, assignment_type="restriction", feed_product_id=CONC, reason="Vet: acidosis")
        plan = _plan(client)
        herd = _line(plan, HERD)
        assert herd["head_count"] == 2 and herd["excluded_heads"][0]["reason"] == "own_restriction"
        assert _targets(_line(plan, BELLA)) == {MIX: 20.0, ALFALFA: 6.0}, "no concentrate, and her concentrate supplement is dropped"
        assert _species_total(plan, "cow", CONC) == 2 * 6

    def test_a_group_restriction_binds_every_member_and_the_feeding(self, client: TestClient):
        _assign(client, PREGNANT, assignment_type="restriction", feed_product_id=STRAW, reason="Pregnant cows: no straw this month")
        r = client.post(f"{API}/feeding-events", headers=_h(client), json={
            "subject_type": "animal", "subject_id": BELLA, "components": [{"feed_product_id": STRAW, "quantity_offered": 1}]})
        assert r.status_code == 422 and "restricted" in r.json()["detail"], r.text
        # Luna is not in the status group: she may have straw.
        _feed(client, "animal", LUNA, STRAW, 1)

    def test_a_status_group_ration_is_her_base_not_an_extra_one(self, client: TestClient):
        """Bella is in the Dairy Herd and in "Pregnant cows" (a group that
        follows the pregnancy records). Give the status group a ration: it
        becomes her base — the herd stops counting her — and when she is
        no longer pregnant she falls back to the herd's."""
        _assign(client, PREGNANT, program_id="prog-dairy-lactating")   # 2 × (9 mix, 3 alfalfa)
        plan = _plan(client)
        herd, preg = _line(plan, HERD), _line(plan, PREGNANT)
        assert herd["head_count"] == 2 and herd["excluded_heads"] == [
            {"animal_id": BELLA, "name": "Bella", "reason": "other_group", "group_id": PREGNANT, "group_name": "Pregnant cows"}]
        assert preg["head_count"] == 1 and _targets(preg) == {MIX: 18.0, ALFALFA: 6.0}
        assert _species_total(plan, "cow", MIX) == 2 * 20 + 18 == _per_head_sum(client, (BELLA, LUNA, CLOVER), MIX)
        bella = _subject_plan(client, BELLA)
        assert bella["program"]["inherited_from"]["group_id"] == PREGNANT
        assert any("Dairy Herd" in w and "one base ration" in w for w in bella["review"]["warnings"])

        r = client.post(f"{API}/animals/{BELLA}/pregnancy-checks", headers=_h(client),
                        json={"assessment_type": "ULTRASOUND", "result_code": "NEGATIVE"})
        assert r.status_code == 201, r.text
        plan = _plan(client)
        assert _line(plan, HERD)["head_count"] == 3 and _line(plan, PREGNANT)["head_count"] == 0
        assert _species_total(plan, "cow", MIX) == 60

    def test_a_cow_in_two_groups_with_rations_gets_one_of_them(self, client: TestClient):
        """Two overlapping groups (cohorts), both with a ration: she gets the
        status group's or, at the same level, the one named first — and the
        other is named as not applied. Never both."""
        r = client.post(f"{API}/animal-groups", headers=_h(client), json={"name": "Show team", "species": "cow", "group_type": "cohort"})
        assert r.status_code == 201, r.text
        show = r.json()["id"]
        assert client.post(f"{API}/animal-groups/{show}/members", headers=_h(client), json={"animal_id": LUNA}).status_code == 201
        _assign(client, show, program_id="prog-dairy-medium")
        plan = _plan(client)
        # Luna's herd is exclusive (level 3) and the show team is not (level 4): the herd's ration is hers.
        assert _line(plan, show)["head_count"] == 0 and _line(plan, show)["excluded_heads"][0]["reason"] == "other_group"
        assert _line(plan, HERD)["head_count"] == 3
        assert any("Show team" in w for w in _subject_plan(client, LUNA)["review"]["warnings"])
        assert _species_total(plan, "cow", MIX) == 60

    def test_a_counted_flock_keeps_its_count_less_a_hen_fed_on_her_own(self, client: TestClient):
        before = _line(_plan(client), LAYERS)
        assert before["head_count"] == 2450
        _assign(client, HEN, program_id="prog-layer")
        plan = _plan(client)
        layers = _line(plan, LAYERS)
        assert layers["head_count"] == 2449 and layers["member_count"] == 2
        assert _total(plan, "fp-layer-feed") == _total(_plan(client), "fp-layer-feed")
        assert abs(_targets(layers)["fp-layer-feed"] + _targets(_line(plan, HEN))["fp-layer-feed"] - _targets(before)["fp-layer-feed"]) < 1e-6

    def test_the_group_feeding_defaults_to_the_heads_its_ration_feeds(self, client: TestClient):
        _assign(client, CLOVER, program_id="prog-dairy-medium")
        event = _feed(client, "group", HERD, MIX, 41, event_type="delivered")
        assert event["head_count"] == 2, "Clover is fed on her own"

    def test_demand_and_days_of_cover_use_the_same_heads(self, client: TestClient):
        _assign(client, CLOVER, program_id="prog-dairy-medium")
        plan = _plan(client)
        cover = {r["feed_product_id"]: r for r in client.get(f"{API}/feed-inventory/days-of-cover", headers=_h(client)).json()}
        assert cover[MIX]["daily_demand"] == _total(plan, MIX) == 56


# ===================================================== I-5: fed = stock moved
class TestOnlyStockMovingFeedIsFed:
    def test_AF05_a_2kg_refusal_is_not_2kg_fed(self, client: TestClient):
        h = _h(client)
        base_plan = _plan(client)
        base_fed = _total(base_plan, MIX, "fed_today")
        base_line = _fed(_line(base_plan, HERD), MIX)
        base_7d = next((x["quantity"] for x in _subject_plan(client, HERD)["fed_7d"] if x["feed_product_id"] == MIX), 0.0)
        base_cost = client.get(f"{API}/feed-costs", params={"days": 7}, headers=h).json()
        base_cost_qty = next((p["quantity"] for p in base_cost["by_product"] if p["feed_product_id"] == MIX), 0.0)

        _feed(client, "group", HERD, MIX, 33, event_type="delivered", at=datetime.now(UTC) - timedelta(minutes=50))
        on_hand = client.get(f"{API}/feed-products/{MIX}", headers=h).json()["availability"]["on_hand"]
        _feed(client, "group", HERD, MIX, 2, event_type="refusal", at=datetime.now(UTC) - timedelta(minutes=5))
        _feed(client, "group", HERD, MIX, 25, event_type="consumed_estimate", at=datetime.now(UTC) - timedelta(minutes=4))
        assert client.get(f"{API}/feed-products/{MIX}", headers=h).json()["availability"]["on_hand"] == on_hand, "a refusal moves no stock"

        plan = _plan(client)
        assert _total(plan, MIX, "fed_today") == base_fed + 33
        assert _fed(_line(plan, HERD), MIX) == base_line + 33
        herd = _subject_plan(client, HERD)
        assert next(x["quantity"] for x in herd["fed_7d"] if x["feed_product_id"] == MIX) == base_7d + 33
        assert next(x["quantity"] for x in herd["refused_7d"] if x["feed_product_id"] == MIX) == 2
        assert any(x["feed_product_id"] == MIX and x["quantity"] >= 25 for x in herd["consumed_7d"])
        cost = client.get(f"{API}/feed-costs", params={"days": 7}, headers=h).json()
        assert next(p["quantity"] for p in cost["by_product"] if p["feed_product_id"] == MIX) == round(base_cost_qty + 33, 2)
        report = client.get(f"{API}/reports/feed", params={"start": _farm_today().isoformat(), "end": _farm_today().isoformat()}, headers=h).json()
        used = next(u for u in report["used"] if u["feed_product_id"] == MIX)
        assert used["quantity"] == round(base_fed + 33, 1), "the usage report counts what was fed today, as the plan does"

    def test_a_refusal_naming_a_lot_is_not_a_second_exposure(self, client: TestClient):
        fed = _feed(client, "animal", THUNDER, ALFALFA, 6)
        lot_id = fed["components"][0]["lot_id"]
        r = client.post(f"{API}/feeding-events", headers=_h(client), json={"subject_type": "animal", "subject_id": THUNDER, "event_type": "refusal",
                                                                          "components": [{"feed_product_id": ALFALFA, "quantity_offered": 1, "lot_id": lot_id}]})
        assert r.status_code == 201, r.text
        trace = client.get(f"{API}/feed-lots/{lot_id}/trace", headers=_h(client)).json()
        mine = [e for e in trace["feeding_events"] if e["subject_id"] == THUNDER]
        assert [e["event_id"] for e in mine] == [fed["id"]]

    def test_the_history_forecast_counts_issues_on_the_day_they_were_fed(self, client: TestClient, db_session):
        """Straw is in no program, so its daily demand comes from history:
        the last 14 whole farm days of issues. A feeding entered today for
        yesterday counts for yesterday; a refusal never counts."""
        _session, factory = db_session
        yesterday_noon = _local(_farm_today() - timedelta(days=1), 12)
        _feed(client, "animal", LUNA, STRAW, 7, at=yesterday_noon)
        _feed(client, "animal", LUNA, STRAW, 3, event_type="refusal", at=yesterday_noon + timedelta(hours=1))
        _feed(client, "animal", LUNA, STRAW, 5)   # today: not a whole day yet
        db = factory()
        try:
            from app.domain import feed_models as fm

            item = db.get(fm.FeedProduct, STRAW).inventory_item_id
            assert round(forecast._historic_daily_usage(db, item) * forecast.HISTORY_DAYS, 3) == 7
        finally:
            db.close()


# ===================================================== I-6: the farm's days
class TestFarmDays:
    def test_daylight_saving_days_are_23_and_25_hours_long(self):
        lo, hi = farm_time.day_bounds(BEIRUT, date(2026, 3, 29))
        assert hi - lo == timedelta(hours=23)
        assert lo == datetime(2026, 3, 28, 22, 0, tzinfo=UTC)
        lo, hi = farm_time.day_bounds(BEIRUT, date(2026, 10, 24))
        assert hi - lo == timedelta(hours=25)
        assert (lo, hi) == (datetime(2026, 10, 23, 21, 0, tzinfo=UTC), datetime(2026, 10, 24, 22, 0, tzinfo=UTC))
        lo, hi = farm_time.day_bounds(BEIRUT, date(2026, 11, 25))
        assert (lo, hi) == (datetime(2026, 11, 24, 22, 0, tzinfo=UTC), datetime(2026, 11, 25, 22, 0, tzinfo=UTC))

    def test_NEW6_a_feeding_at_0030_beirut_is_on_that_beirut_day(self, client: TestClient):
        """00:30 in Beirut is 22:30 UTC the evening before. It belongs to
        the Beirut day — today's plan if it is today, `?day=` if it is past."""
        today = _farm_today()
        yesterday = today - timedelta(days=1)
        at = _local(yesterday, 0, 30)
        assert at.astimezone(UTC).date() == yesterday - timedelta(days=1), "the UTC calendar puts it a day earlier"
        _feed(client, "animal", THUNDER, ALFALFA, 7.5, at=at)
        _feed(client, "animal", THUNDER, ALFALFA, 4.5, at=_local(yesterday, 23, 30))   # 21:30 UTC — still yesterday in Beirut

        plan = _plan(client, day=yesterday.isoformat())
        assert plan["date"] == yesterday.isoformat() and plan["timezone"] == "Asia/Beirut"
        assert plan["from"].startswith((yesterday - timedelta(days=1)).isoformat() + "T22:00") or plan["from"].startswith((yesterday - timedelta(days=1)).isoformat() + "T21:00")
        assert _fed_to(plan, THUNDER, ALFALFA) == 12.0
        before = _plan(client, day=(yesterday - timedelta(days=1)).isoformat())
        assert _fed_to(before, THUNDER, ALFALFA) == 0.0, "not on the UTC day before"

        now_local = datetime.now(UTC).astimezone(BEIRUT)
        if now_local.hour >= 1:
            _feed(client, "animal", THUNDER, ALFALFA, 3.25, at=_local(today, 0, 30))
            p = _plan(client)
            assert p["date"] == today.isoformat()
            assert _fed_to(p, THUNDER, ALFALFA) >= 3.25
            assert _fed_to(_plan(client, day=yesterday.isoformat()), THUNDER, ALFALFA) == 12.0

    def test_feedings_across_the_autumn_change_land_on_their_farm_day(self, client: TestClient):
        """2026-10-24 has two 23:30s in Beirut (clocks go back at midnight)."""
        _feed(client, "animal", THUNDER, ALFALFA, 1.25, at=datetime(2026, 10, 24, 20, 30, tzinfo=UTC))   # 23:30 summer time
        _feed(client, "animal", THUNDER, ALFALFA, 2.25, at=datetime(2026, 10, 24, 21, 30, tzinfo=UTC))   # 23:30 again, winter time
        _feed(client, "animal", THUNDER, ALFALFA, 3.25, at=datetime(2026, 10, 24, 22, 30, tzinfo=UTC))   # 00:30 on the 25th
        assert _fed_to(_plan(client, day="2026-10-24"), THUNDER, ALFALFA) == 3.5
        assert _fed_to(_plan(client, day="2026-10-25"), THUNDER, ALFALFA) == 3.25
        assert _total(_plan(client, day="2026-10-24"), ALFALFA, "fed_today") == 3.5, "the day's totals say what left the store that day"

    def test_a_feeding_in_the_spring_gap_hour_lands_on_the_new_day(self, client: TestClient):
        _feed(client, "animal", THUNDER, ALFALFA, 1.75, at=datetime(2026, 3, 28, 22, 30, tzinfo=UTC))   # 01:30 summer time, 29 March
        assert _fed_to(_plan(client, day="2026-03-29"), THUNDER, ALFALFA) == 1.75
        assert _fed_to(_plan(client, day="2026-03-28"), THUNDER, ALFALFA) == 0.0

    def test_a_past_day_is_planned_with_what_was_in_force_then(self, client: TestClient):
        """The herd has been on its ration for five days; Clover's own
        ration starts now. Yesterday's plan still has the herd feeding her
        (3 heads, no line of her own); today's has her on her own."""
        today = _farm_today()
        _assign(client, HERD, program_id="prog-dairy-high", valid_from=_local(today - timedelta(days=5), 6).astimezone(UTC).isoformat())
        _assign(client, CLOVER, program_id="prog-dairy-medium")
        past = _plan(client, day=(today - timedelta(days=1)).isoformat())
        assert _line(past, HERD)["head_count"] == 3 and _line(past, CLOVER) is None
        assert _species_total(past, "cow", MIX) == 60
        now_ = _plan(client)
        assert _line(now_, HERD)["head_count"] == 2 and _line(now_, CLOVER)["basis"] == "own_program"
        assert _species_total(now_, "cow", MIX) == 56
        assert _line(_plan(client, day=(today - timedelta(days=9)).isoformat()), HERD) is None, "before the herd's ration began"

    def test_a_past_day_still_sees_a_ration_ended_since(self, client: TestClient):
        """Luna's override ran for the last five days and is ended now: today
        she is back in the herd's count, yesterday she was on her own line."""
        today = _farm_today()
        _assign(client, HERD, program_id="prog-dairy-high", valid_from=_local(today - timedelta(days=5), 6).astimezone(UTC).isoformat())
        o = _assign(client, LUNA, assignment_type="override", feed_product_id=ALFALFA, quantity_per_head=4, reason="Body condition",
                    valid_from=_local(today - timedelta(days=5), 6).astimezone(UTC).isoformat())
        r = client.delete(f"{API}/livestock-subjects/{LUNA}/feeding-assignments/{o['id']}", headers=_h(client))
        assert r.status_code == 200, r.text
        past = _plan(client, day=(today - timedelta(days=1)).isoformat())
        assert _line(past, HERD)["head_count"] == 2 and _targets(_line(past, LUNA))[ALFALFA] == 4.0
        assert _line(_plan(client), HERD)["head_count"] == 3 and _line(_plan(client), LUNA) is None

    def test_partial_group_feeding_is_the_groups_not_spread_over_heads(self, client: TestClient):
        """Two of the three cows fed from the herd's ration: the herd's
        line shows the 22 kg, no cow's own line or history is credited
        with a share of it."""
        event = _feed(client, "group", HERD, MIX, 22, event_type="delivered", head_count=2, notes="Clover at the vet")
        assert event["head_count"] == 2
        plan = _plan(client)
        assert _fed(_line(plan, HERD), MIX) >= 22
        assert _fed_to(plan, BELLA, MIX) == 0.0
        assert all(x["feed_product_id"] != MIX for x in _subject_plan(client, CLOVER)["fed_7d"])

    def test_a_subjects_history_is_its_farm_days_not_rolling_hours(self, client: TestClient):
        yesterday_late = _local(_farm_today() - timedelta(days=1), 23, 30)
        e = _feed(client, "animal", THUNDER, ALFALFA, 0.75, at=yesterday_late)
        today_only = client.get(f"{API}/livestock-subjects/{THUNDER}/feeding-history", params={"days": 1}, headers=_h(client)).json()
        assert e["id"] not in {x["id"] for x in today_only}
        two_days = client.get(f"{API}/livestock-subjects/{THUNDER}/feeding-history", params={"days": 2}, headers=_h(client)).json()
        assert e["id"] in {x["id"] for x in two_days}

    def test_the_cost_summary_uses_farm_days(self, client: TestClient):
        now_local = datetime.now(UTC).astimezone(BEIRUT)
        if now_local.hour < 1:
            return
        e = _feed(client, "animal", THUNDER, ALFALFA, 0.5, at=_local(_farm_today(), 0, 30))
        cost = client.get(f"{API}/feed-costs", params={"days": 1}, headers=_h(client)).json()
        thunder = next(s for s in cost["by_subject"] if s["subject_id"] == THUNDER)
        assert thunder["quantity"] >= 0.5 and e["total_cost"] is not None
