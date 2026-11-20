"""Employees enter the day's data; the manager approves what changes the
farm (v0.7.8, app/services/approval_service.py).

* An employee (feed / milk *create*, no *approve*) records milk and
  feedings directly.
* Buying feed: the employee sends a purchase request; the manager approves
  or rejects it; a delivery is recorded only against an approved request,
  up to its quantity (+10%). Without a request only the manager records one.
* A numbered mix by an employee is a request: stock and mixes are untouched
  until the manager approves it; rejecting it changes nothing.
* Correcting a milk record or a feeding: the manager directly; the employee
  by a request with a reason, applied when the manager approves.
"""
from __future__ import annotations

from sqlalchemy import select

from app.domain import feed_models as fm
from app.domain import models
from tests.conftest import auth_headers

API = "/api/v1"
FARM = "farm-origami"
BELLA, THUNDER = "cow-744", "horse-h07"
ALFALFA, BARLEY = "fp-alfalfa", "fp-barley"
WORKER = "karim.worker@origami.farm"


def _h(client, email="rami@origami.farm"):
    return auth_headers(client, email)


def _on_hand(client, product_id: str, headers) -> float:
    rows = client.get(f"{API}/feed-inventory/availability", params={"feed_product_id": product_id}, headers=headers).json()
    return rows[0]["on_hand"]


def _milk_of(client, animal_id: str, headers) -> list[dict]:
    return [r for r in client.get(f"{API}/production/milk", params={"farm_id": FARM}, headers=headers).json() if r["animal_id"] == animal_id]


# ------------------------------------------------------------- day's data
def test_an_employee_records_milk_and_feedings_directly(client):
    worker = _h(client, WORKER)
    fed = client.post(f"{API}/feeding-events", json={"subject_type": "animal", "subject_id": THUNDER, "event_type": "offered",
                                                     "components": [{"feed_product_id": ALFALFA, "quantity_offered": 4}]}, headers=worker)
    assert fed.status_code == 201, fed.text
    milk = client.post(f"{API}/production/milk", json={"animal_id": BELLA, "session": "midday", "liters": 6}, headers=worker)
    assert milk.status_code == 201, milk.text


# ---------------------------------------------------------------- buying
def test_buying_feed_is_requested_approved_then_received(client, db_session):
    session, _ = db_session
    worker, manager = _h(client, WORKER), _h(client)
    delivery = {"feed_product_id": BARLEY, "quantity": 500, "unit": "kg", "supplier_label": "Bekaa Grains"}

    refused = client.post(f"{API}/feed-lots/receive", json=delivery, headers=worker)
    assert refused.status_code == 403 and "purchase request" in refused.json()["detail"], refused.text
    legacy = client.post(f"{API}/feed/transactions", json={"item_id": "inv-barley", "direction": "in", "quantity": 100, "unit": "kg"}, headers=worker)
    assert legacy.status_code in (403, 404), legacy.text

    asked = client.post(f"{API}/procurement/requisitions", json={"lines": [{"feed_product_id": BARLEY, "requested_quantity": 500}],
                                                                 "justification": "Two weeks left", "purpose_code": "feed_purchase", "submit": True},
                        headers=worker)
    assert asked.status_code == 201, asked.text
    req = asked.json()
    assert req["status"] == "submitted"
    session.expire_all()
    told = session.scalars(select(models.Notification).where(models.Notification.entity_id == req["id"])).all()
    assert told and all(n.user_id != "user-worker-1" for n in told), "the managers hear of the request"

    early = client.post(f"{API}/feed-lots/receive", json={**delivery, "requisition_id": req["id"]}, headers=worker)
    assert early.status_code == 409, "a delivery waits for the approval"
    assert client.post(f"{API}/procurement/requisitions/{req['id']}/approve", json={}, headers=worker).status_code in (403, 422)
    approved = client.post(f"{API}/procurement/requisitions/{req['id']}/approve", json={"comments": "Order from Bekaa"}, headers=manager)
    assert approved.status_code == 200 and approved.json()["status"] == "approved", approved.text

    too_much = client.post(f"{API}/feed-lots/receive", json={**delivery, "quantity": 600, "requisition_id": req["id"]}, headers=worker)
    assert too_much.status_code == 422 and "approved" in too_much.json()["detail"], too_much.text
    before = _on_hand(client, BARLEY, manager)
    received = client.post(f"{API}/feed-lots/receive", json={**delivery, "quantity": 520, "requisition_id": req["id"]}, headers=worker)
    assert received.status_code == 201, received.text
    assert _on_hand(client, BARLEY, manager) == before + 520
    assert client.get(f"{API}/procurement/requisitions/{req['id']}", headers=worker).json()["status"] == "received"


def test_a_rejected_purchase_request_says_why_and_buys_nothing(client):
    worker, manager = _h(client, WORKER), _h(client)
    req = client.post(f"{API}/procurement/requisitions", json={"lines": [{"feed_product_id": BARLEY, "requested_quantity": 200}], "submit": True},
                      headers=worker).json()
    assert client.post(f"{API}/procurement/requisitions/{req['id']}/reject", json={}, headers=manager).status_code == 422
    rejected = client.post(f"{API}/procurement/requisitions/{req['id']}/reject", json={"comments": "Enough in the barn"}, headers=manager)
    assert rejected.json()["status"] == "rejected"
    r = client.post(f"{API}/feed-lots/receive", json={"feed_product_id": BARLEY, "quantity": 200, "requisition_id": req["id"]}, headers=worker)
    assert r.status_code == 409, r.text


# ------------------------------------------------------------------ mixes
def _mix_body(client, manager) -> dict:
    made = client.post(f"{API}/feed-mixes", json={"new_product_name": "Heifer mix", "components": [{"feed_product_id": BARLEY, "actual_quantity": 30}]},
                       headers=manager)
    assert made.status_code == 201, made.text
    return {"feed_product_id": made.json()["feed_product_id"], "components": [{"feed_product_id": BARLEY, "actual_quantity": 25}]}


def test_an_employees_mix_counts_only_once_the_manager_approves(client, db_session):
    session, _ = db_session
    worker, manager = _h(client, WORKER), _h(client)
    body = _mix_body(client, manager)
    assert client.post(f"{API}/feed-mixes", json=body, headers=worker).status_code == 403
    barley = _on_hand(client, BARLEY, manager)
    mixes = len(client.get(f"{API}/feed-batches", headers=manager).json())

    sent = client.post(f"{API}/approval-requests", json={"kind": "feed_mix", "payload": body}, headers=worker)
    assert sent.status_code == 201, sent.text
    request = sent.json()
    assert request["status"] == "pending" and "Heifer mix" in request["summary"]
    assert _on_hand(client, BARLEY, manager) == barley, "a request moves no stock"
    assert len(client.get(f"{API}/feed-batches", headers=manager).json()) == mixes, "and numbers no mix"

    assert client.post(f"{API}/approval-requests/{request['id']}/approve", headers=worker).status_code == 403
    waiting = client.get(f"{API}/approval-requests", params={"status": "pending"}, headers=manager).json()
    assert request["id"] in [w["id"] for w in waiting]

    approved = client.post(f"{API}/approval-requests/{request['id']}/approve", json={}, headers=manager)
    assert approved.status_code == 200, approved.text
    assert approved.json()["status"] == "approved" and approved.json()["result_type"] == "feed_batch"
    assert _on_hand(client, BARLEY, manager) == barley - 25
    batch = session.get(fm.FeedBatch, approved.json()["result_id"])
    assert batch is not None and batch.mix_number > 0
    session.expire_all()
    note = session.scalars(select(models.Notification).where(models.Notification.entity_id == request["id"],
                                                             models.Notification.user_id == "user-worker-1")).all()
    assert note, "the employee hears the answer"
    assert client.post(f"{API}/approval-requests/{request['id']}/approve", json={}, headers=manager).status_code == 409


def test_a_rejected_mix_changes_nothing(client):
    worker, manager = _h(client, WORKER), _h(client)
    body = _mix_body(client, manager)
    request = client.post(f"{API}/approval-requests", json={"kind": "feed_mix", "payload": body}, headers=worker).json()
    barley = _on_hand(client, BARLEY, manager)
    assert client.post(f"{API}/approval-requests/{request['id']}/reject", json={}, headers=manager).status_code == 422, "a rejection says why"
    rejected = client.post(f"{API}/approval-requests/{request['id']}/reject", json={"note": "Weigh the barley again"}, headers=manager)
    assert rejected.json()["status"] == "rejected" and rejected.json()["decision_note"] == "Weigh the barley again"
    assert _on_hand(client, BARLEY, manager) == barley
    mine = client.get(f"{API}/approval-requests", headers=worker).json()
    assert [m["status"] for m in mine if m["id"] == request["id"]] == ["rejected"]


# ------------------------------------------------------------- corrections
def test_a_milk_correction_by_an_employee_waits_for_the_manager(client, db_session):
    session, _ = db_session
    worker, manager = _h(client, WORKER), _h(client)
    record = client.post(f"{API}/production/milk", json={"animal_id": BELLA, "session": "midday", "liters": 61}, headers=worker).json()
    fix = {"liters": 16.1}

    assert client.post(f"{API}/production/milk/{record['id']}/correct", json={**fix, "reason": "decimal"}, headers=worker).status_code == 403
    no_reason = client.post(f"{API}/approval-requests", json={"kind": "milk_correction", "target_id": record["id"], "payload": fix}, headers=worker)
    assert no_reason.status_code == 422
    sent = client.post(f"{API}/approval-requests", json={"kind": "milk_correction", "target_id": record["id"], "payload": fix,
                                                        "reason": "Typed 61 for 16.1"}, headers=worker)
    assert sent.status_code == 201, sent.text
    assert "61 L → 16.1 L" in sent.json()["summary"]
    again = client.post(f"{API}/approval-requests", json={"kind": "milk_correction", "target_id": record["id"], "payload": {"liters": 16},
                                                         "reason": "again"}, headers=worker)
    assert again.status_code == 409, "one request per record at a time"
    direct = client.post(f"{API}/production/milk/{record['id']}/correct", json={"liters": 15, "reason": "manager"}, headers=manager)
    assert direct.status_code == 409, "the manager decides the request first"
    assert [r["liters"] for r in _milk_of(client, BELLA, manager) if r["id"] == record["id"]] == [61]

    approved = client.post(f"{API}/approval-requests/{sent.json()['id']}/approve", json={}, headers=manager)
    assert approved.status_code == 200, approved.text
    assert [r["liters"] for r in _milk_of(client, BELLA, manager) if r["id"] == record["id"]] == [16.1]
    session.expire_all()
    audit = session.scalars(select(models.AuditLog).where(models.AuditLog.entity_id == record["id"])).all()
    assert audit and audit[-1].changes_json["liters"] == {"from": 61, "to": 16.1}
    assert audit[-1].metadata_json["requested_by"] == "user-worker-1"


def test_the_manager_corrects_milk_directly_and_the_rules_still_hold(client):
    manager = _h(client)
    record = client.post(f"{API}/production/milk", json={"animal_id": BELLA, "session": "midday", "liters": 9}, headers=manager).json()
    assert client.post(f"{API}/production/milk/{record['id']}/correct", json={"liters": 9, "reason": "x"}, headers=manager).status_code == 422
    assert client.post(f"{API}/production/milk/{record['id']}/correct", json={"liters": 400, "reason": "x"}, headers=manager).status_code == 422
    assert client.post(f"{API}/production/milk/{record['id']}/correct", json={"liters": 10}, headers=manager).status_code == 422, "says why"
    fixed = client.post(f"{API}/production/milk/{record['id']}/correct", json={"liters": 10.5, "session": "evening", "reason": "evening milking"},
                        headers=manager)
    assert fixed.status_code == 200, fixed.text
    assert (fixed.json()["liters"], fixed.json()["session"]) == (10.5, "evening")


def test_an_employee_withdraws_a_request_only_their_own(client):
    worker, manager = _h(client, WORKER), _h(client)
    record = client.post(f"{API}/production/milk", json={"animal_id": BELLA, "session": "midday", "liters": 8}, headers=worker).json()
    sent = client.post(f"{API}/approval-requests", json={"kind": "milk_correction", "target_id": record["id"], "payload": {"liters": 7},
                                                        "reason": "misread"}, headers=worker).json()
    assert sent["id"] not in [r["id"] for r in client.get(f"{API}/approval-requests", params={"mine": True}, headers=manager).json()]
    assert sent["id"] in [r["id"] for r in client.get(f"{API}/approval-requests", headers=manager).json()], "the manager's list has it"
    cancelled = client.post(f"{API}/approval-requests/{sent['id']}/cancel", headers=worker)
    assert cancelled.json()["status"] == "cancelled"
    assert [r["liters"] for r in _milk_of(client, BELLA, manager) if r["id"] == record["id"]] == [8]


def test_a_feeding_correction_returns_the_stock_and_records_what_was_fed(client, db_session):
    session, _ = db_session
    worker, manager = _h(client, WORKER), _h(client)
    alfalfa = _on_hand(client, ALFALFA, manager)
    event = client.post(f"{API}/feeding-events", json={"subject_type": "animal", "subject_id": THUNDER, "event_type": "offered",
                                                       "components": [{"feed_product_id": ALFALFA, "quantity_offered": 12}]}, headers=worker).json()
    assert _on_hand(client, ALFALFA, manager) == alfalfa - 12
    assert client.post(f"{API}/feeding-events/{event['id']}/reverse", json={"reason": "x"}, headers=worker).status_code == 403

    fix = {"components": [{"feed_product_id": ALFALFA, "quantity_offered": 2}]}
    sent = client.post(f"{API}/approval-requests", json={"kind": "feeding_correction", "target_id": event["id"], "payload": fix,
                                                        "reason": "It was 2 kg, not 12"}, headers=worker)
    assert sent.status_code == 201, sent.text
    assert _on_hand(client, ALFALFA, manager) == alfalfa - 12, "nothing moves while it waits"
    approved = client.post(f"{API}/approval-requests/{sent.json()['id']}/approve", json={}, headers=manager)
    assert approved.status_code == 200, approved.text
    assert _on_hand(client, ALFALFA, manager) == alfalfa - 2
    session.expire_all()
    original = session.get(fm.FeedingEvent, event["id"])
    assert original.status == "reversed"
    replacement = session.get(fm.FeedingEvent, approved.json()["result_id"])
    assert replacement.status == "recorded" and replacement.recorded_by == "user-worker-1"
    assert [c.quantity_offered for c in replacement.components] == [2]


def test_the_manager_undoes_a_feeding_directly(client):
    manager = _h(client)
    event = client.post(f"{API}/feeding-events", json={"subject_type": "animal", "subject_id": THUNDER, "event_type": "offered",
                                                       "components": [{"feed_product_id": ALFALFA, "quantity_offered": 3}]}, headers=manager).json()
    undone = client.post(f"{API}/feeding-events/{event['id']}/correct", json={"reason": "Wrong horse"}, headers=manager)
    assert undone.status_code == 201, undone.text
    assert undone.json()["status"] == "reversal"
    assert client.post(f"{API}/feeding-events/{event['id']}/correct", json={"reason": "again"}, headers=manager).status_code in (409, 422)


def test_an_employee_sees_only_their_own_requests(client, db_session):
    session, _ = db_session
    worker, manager = _h(client, WORKER), _h(client)
    record = client.post(f"{API}/production/milk", json={"animal_id": BELLA, "session": "midday", "liters": 5}, headers=manager).json()
    mine = client.post(f"{API}/approval-requests", json={"kind": "milk_correction", "target_id": record["id"], "payload": {"liters": 6},
                                                        "reason": "manager's own"}, headers=manager)
    assert mine.status_code == 201
    assert mine.json()["id"] not in [r["id"] for r in client.get(f"{API}/approval-requests", headers=worker).json()]
    assert client.get(f"{API}/approval-requests/{mine.json()['id']}", headers=worker).status_code == 404
