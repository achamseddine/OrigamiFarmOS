"""Feed stock integrity (v0.8.4; audit 2026-11-25 I-1, I-2).

The rows are the stock: a lot is the sum of its movements and never goes
below zero; the stock line is the sum of every movement; a kilo issued
with no lot belongs to an open stock exception — approved, with a reason —
until it is reconciled. Every scenario ends by asking the server's own
reconciliation (GET /feed-inventory/integrity) whether the stored figures
still equal their rows.

Concurrency (I-13) is proven on a real PostgreSQL 16 server in
tests/test_feed_stock_concurrency_pg.py; the migration of older data in
tests/test_feed_stock_migration.py.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select

from app.domain import feed_models as fm
from app.domain import models
from tests.conftest import auth_headers

API = "/api/v1"
BELLA = "cow-744"
WORKER = "karim.worker@origami.farm"


def _h(client, email="rami@origami.farm"):
    return auth_headers(client, email)


def _ago(days: float) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()


def _product(client, h, name: str) -> dict:
    r = client.post(f"{API}/feed-products", json={"name": name, "ration_type": "hay_straw"}, headers=h)
    assert r.status_code == 201, r.text
    return r.json()


def _lot(client, h, product_id: str, qty: float, *, days_ago: float = 0, code: str | None = None, cost: float = 0.2) -> dict:
    body = {"feed_product_id": product_id, "quantity": qty, "unit_cost": cost, "supplier_label": "Integrity test",
            "received_at": _ago(days_ago), "confirm_duplicate": True}
    if code:
        body["lot_code"] = code
    r = client.post(f"{API}/feed-lots/receive", json=body, headers=h)
    assert r.status_code == 201, r.text
    return r.json()


def _feed(client, h, product_id: str, qty: float, *, lot_id: str | None = None, allow_negative: bool = False,
          reason: str | None = None, occurred_at: str | None = None, subject: str = BELLA):
    comp = {"feed_product_id": product_id, "quantity_offered": qty}
    if lot_id:
        comp["lot_id"] = lot_id
    body = {"subject_type": "animal", "subject_id": subject, "event_type": "offered", "components": [comp], "confirm_duplicate": True}
    if allow_negative:
        body["allow_negative"] = True
    if reason is not None:
        body["override_reason"] = reason
    if occurred_at:
        body["occurred_at"] = occurred_at
    return client.post(f"{API}/feeding-events", json=body, headers=h)


def _avail(client, h, product_id: str) -> dict:
    return client.get(f"{API}/feed-products/{product_id}", headers=h).json()["availability"]


def _lots(client, h, product_id: str) -> dict[str, float]:
    return {l["lot_code"]: l["quantity_on_hand"] for l in _avail(client, h, product_id)["lots"]}


def _stock_line(client, h, product: dict) -> float:
    items = client.get(f"{API}/feed/items", params={"farm_id": "farm-origami"}, headers=h).json()
    return next(i["current_qty"] for i in items if i["id"] == product["inventory_item_id"])


def _consistent(client, h) -> None:
    report = client.get(f"{API}/feed-inventory/integrity", headers=h).json()
    bad = [p for p in report["products"] if not p["consistent"]]
    assert report["consistent"], bad


def _exceptions(client, h, product_id: str, status: str | None = None) -> list[dict]:
    params = {"feed_product_id": product_id}
    if status:
        params["status"] = status
    return client.get(f"{API}/feed-inventory/exceptions", params=params, headers=h).json()


def _no_approve(session, user_id: str = "user-worker-1") -> None:
    for row in session.scalars(select(models.UserModulePermission).where(models.UserModulePermission.user_id == user_id)):
        if row.module_code in ("feed_nutrition", "inventory"):
            row.can_view, row.can_create, row.can_approve = True, True, False
    session.commit()


def _movements(session, item_id: str) -> int:
    session.expire_all()
    return session.scalar(select(func.count(models.InventoryTransaction.id)).where(models.InventoryTransaction.item_id == item_id))


# ------------------------------------------------------- the demo farm itself
def test_the_seeded_farm_passes_its_own_reconciliation(client):
    _consistent(client, _h(client))


# ----------------------------------------------------------- I-1: named lot
def test_NEW1_a_50kg_issue_naming_a_20kg_lot_is_refused_and_moves_nothing(client, db_session):
    session, _ = db_session
    h = _h(client)
    p = _product(client, h, "Integrity hay NEW1")
    small = _lot(client, h, p["id"], 20, days_ago=3, code="NEW1-SMALL")
    _lot(client, h, p["id"], 200, days_ago=1, code="NEW1-BIG")
    moves = _movements(session, p["inventory_item_id"])

    r = _feed(client, h, p["id"], 50, lot_id=small["id"])
    assert r.status_code == 422, r.text
    detail = r.json()["detail"]
    assert "NEW1-SMALL" in detail and "never made up from another lot" in detail, detail
    assert _movements(session, p["inventory_item_id"]) == moves, "a refused issue posts nothing"
    assert _lots(client, h, p["id"]) == {"NEW1-SMALL": 20, "NEW1-BIG": 200}

    # The override is the manager's and needs a reason: without one, refused too.
    r = _feed(client, h, p["id"], 50, lot_id=small["id"], allow_negative=True)
    assert r.status_code == 422 and "override_reason" in r.json()["detail"], r.text
    assert _movements(session, p["inventory_item_id"]) == moves
    assert _exceptions(client, h, p["id"]) == []
    _consistent(client, h)


def test_NEW1_an_override_without_approval_is_forbidden(client, db_session):
    session, _ = db_session
    _no_approve(session)
    h = _h(client)
    p = _product(client, h, "Integrity hay NEW1b")
    small = _lot(client, h, p["id"], 20, code="NEW1B-SMALL")
    r = _feed(client, _h(client, WORKER), p["id"], 50, lot_id=small["id"], allow_negative=True, reason="I am sure it is there")
    assert r.status_code == 403, r.text
    assert _lots(client, h, p["id"]) == {"NEW1B-SMALL": 20}


def test_an_approved_override_empties_the_named_lot_and_records_the_rest_as_an_exception(client):
    h = _h(client)
    p = _product(client, h, "Integrity hay override")
    small = _lot(client, h, p["id"], 20, days_ago=3, code="OVR-SMALL")
    _lot(client, h, p["id"], 200, days_ago=1, code="OVR-BIG")

    r = _feed(client, h, p["id"], 50, lot_id=small["id"], allow_negative=True, reason="Bales from the Bekaa delivery not entered yet")
    assert r.status_code == 201, r.text
    comps = sorted(r.json()["components"], key=lambda c: c["lot_id"] or "")
    assert [(c["lot_id"], c["quantity_offered"]) for c in comps] == [(None, 30), (small["id"], 20)]
    assert _lots(client, h, p["id"]) == {"OVR-SMALL": 0, "OVR-BIG": 200}, "never made up from a second lot"

    [exc] = _exceptions(client, h, p["id"])
    assert exc["status"] == "open" and exc["kind"] == "untraced_issue"
    assert exc["quantity"] == 30 and exc["open_quantity"] == 30 and exc["lot_code"] == "OVR-SMALL"
    assert exc["reason"] == "Bales from the Bekaa delivery not entered yet"
    assert exc["requested_by"] and exc["requested_by"] == exc["approved_by"] and exc["approved_by_name"]
    assert exc["source_entity_type"] == "feeding_event" and exc["source_entity_id"] == r.json()["id"]

    a = _avail(client, h, p["id"])
    assert (a["on_hand"], a["lot_on_hand"], a["untraced"], a["open_exceptions"]) == (170, 200, 30, 1)
    assert a["available"] == 170
    assert _stock_line(client, h, p) == a["on_hand"]
    _consistent(client, h)


# ---------------------------------------------------- I-2: line and lots agree
def test_NEW2_after_an_override_and_a_delivery_the_stock_line_and_the_lots_reconcile(client):
    h = _h(client)
    hay = _product(client, h, "Integrity hay NEW2")
    assert client.post(f"{API}/feed-inventory/counts", json={"feed_product_id": hay["id"], "counted_quantity": 10}, headers=h).status_code == 201
    r = _feed(client, h, hay["id"], 60, allow_negative=True, reason="Truck unloaded before the delivery was entered")
    assert r.status_code == 201, r.text
    _lot(client, h, hay["id"], 100, code="NEW2-TRUCK")

    a = _avail(client, h, hay["id"])
    # One number for the stock everywhere: 10 counted − 60 fed + 100 received.
    assert a["on_hand"] == 50 and _stock_line(client, h, hay) == 50
    # Its two parts, explicit: 100 kg in lots, 50 kg fed with no lot and open.
    assert (a["lot_on_hand"], a["untraced"], a["available"]) == (100, 50, 50)
    _consistent(client, h)

    # More than what is available is refused, not taken from the lot.
    assert _feed(client, h, hay["id"], 60).status_code == 422

    # Reconciled: the 50 kg came from that truck. The lot gives them up now.
    [exc] = _exceptions(client, h, hay["id"], "open")
    done = client.post(f"{API}/feed-inventory/exceptions/{exc['id']}/resolve",
                       json={"resolution": "assigned_to_lot", "lot_id": _lot_id(client, h, hay["id"], "NEW2-TRUCK"),
                             "note": "Workers fed from the truck before it was entered"}, headers=h)
    assert done.status_code == 200, done.text
    assert done.json()["status"] == "resolved" and done.json()["resolution"] == "assigned_to_lot"
    assert done.json()["resolution_lot_code"] == "NEW2-TRUCK" and done.json()["resolved_by_name"]
    a = _avail(client, h, hay["id"])
    assert (a["on_hand"], a["lot_on_hand"], a["untraced"], a["available"]) == (50, 50, 0, 50)
    assert _stock_line(client, h, hay) == 50
    assert _lots(client, h, hay["id"]) == {"INTEGRITY-HAY-NEW2-COUNT": 0, "NEW2-TRUCK": 50}
    _consistent(client, h)
    # Reconciled once.
    again = client.post(f"{API}/feed-inventory/exceptions/{exc['id']}/resolve",
                        json={"resolution": "confirmed_unrecorded_stock", "note": "again"}, headers=h)
    assert again.status_code == 409


def _lot_id(client, h, product_id: str, code: str) -> str:
    return next(l["id"] for l in _avail(client, h, product_id)["lots"] if l["lot_code"] == code)


def test_an_exception_confirmed_as_unrecorded_stock_raises_the_book_to_the_lots(client):
    h = _h(client)
    hay = _product(client, h, "Integrity hay confirm")
    _lot(client, h, hay["id"], 10, code="CONF-A")
    assert _feed(client, h, hay["id"], 25, allow_negative=True, reason="Old bales in the back barn").status_code == 201
    [exc] = _exceptions(client, h, hay["id"])
    assert _avail(client, h, hay["id"])["on_hand"] == -15
    r = client.post(f"{API}/feed-inventory/exceptions/{exc['id']}/resolve",
                    json={"resolution": "confirmed_unrecorded_stock", "note": "15 kg of old bales were never entered"}, headers=h)
    assert r.status_code == 200, r.text
    a = _avail(client, h, hay["id"])
    assert (a["on_hand"], a["untraced"], a["lot_on_hand"]) == (0, 0, 0)
    _consistent(client, h)


def test_a_count_settles_every_open_exception_and_becomes_the_stock(client):
    h = _h(client)
    hay = _product(client, h, "Integrity hay count")
    _lot(client, h, hay["id"], 40, code="CNT-A")
    assert _feed(client, h, hay["id"], 55, allow_negative=True, reason="Fed before the delivery was entered").status_code == 201
    _lot(client, h, hay["id"], 100, code="CNT-B")
    before = _avail(client, h, hay["id"])
    assert (before["on_hand"], before["untraced"]) == (85, 15)

    r = client.post(f"{API}/feed-inventory/counts", json={"feed_product_id": hay["id"], "counted_quantity": 90, "notes": "Barn walk"}, headers=h)
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["before"] == 85 and body["delta"] == 5 and [e["quantity"] for e in body["exceptions_settled"]] == [15]
    a = body["availability"]
    assert (a["on_hand"], a["lot_on_hand"], a["untraced"], a["available"]) == (90, 90, 0, 90)
    [exc] = _exceptions(client, h, hay["id"])
    assert exc["status"] == "resolved" and exc["resolution"] == "count" and exc["open_quantity"] == 0
    assert _stock_line(client, h, hay) == 90
    _consistent(client, h)


def test_undoing_an_override_feeding_closes_its_exception(client):
    h = _h(client)
    hay = _product(client, h, "Integrity hay reverse")
    _lot(client, h, hay["id"], 10, code="REV-A")
    fed = _feed(client, h, hay["id"], 60, allow_negative=True, reason="Entered the wrong animal's ration")
    assert fed.status_code == 201
    r = client.post(f"{API}/feeding-events/{fed.json()['id']}/reverse", json={"reason": "Typed 60 for 6"}, headers=h)
    assert r.status_code == 201, r.text
    [exc] = _exceptions(client, h, hay["id"])
    assert exc["status"] == "reversed" and exc["resolution"] == "reversed" and exc["open_quantity"] == 0
    a = _avail(client, h, hay["id"])
    assert (a["on_hand"], a["lot_on_hand"], a["untraced"]) == (10, 10, 0)
    assert _lots(client, h, hay["id"]) == {"REV-A": 10}
    _consistent(client, h)


def test_an_exception_cannot_be_assigned_to_a_lot_that_arrived_after_the_feeding(client):
    h = _h(client)
    hay = _product(client, h, "Integrity hay lineage")
    _lot(client, h, hay["id"], 5, days_ago=10, code="LIN-OLD")
    assert _feed(client, h, hay["id"], 20, allow_negative=True, reason="Bales not entered", occurred_at=_ago(6)).status_code == 201
    late = _lot(client, h, hay["id"], 100, days_ago=0, code="LIN-NEW")
    [exc] = _exceptions(client, h, hay["id"])
    r = client.post(f"{API}/feed-inventory/exceptions/{exc['id']}/resolve",
                    json={"resolution": "assigned_to_lot", "lot_id": late["id"], "note": "From the new truck"}, headers=h)
    assert r.status_code == 422 and "after the feed was issued" in r.json()["detail"], r.text
    assert _exceptions(client, h, hay["id"], "open")


def test_reconciling_is_the_managers_and_says_how(client, db_session):
    session, _ = db_session
    h = _h(client)
    hay = _product(client, h, "Integrity hay perms")
    _lot(client, h, hay["id"], 5, code="PRM-A")
    assert _feed(client, h, hay["id"], 9, allow_negative=True, reason="Not entered").status_code == 201
    [exc] = _exceptions(client, h, hay["id"])
    _no_approve(session)
    worker = _h(client, WORKER)
    url = f"{API}/feed-inventory/exceptions/{exc['id']}/resolve"
    assert client.post(url, json={"resolution": "confirmed_unrecorded_stock", "note": "x"}, headers=worker).status_code == 403
    assert client.post(url, json={"resolution": "confirmed_unrecorded_stock", "note": ""}, headers=h).status_code == 422
    assert client.post(url, json={"resolution": "wished_away", "note": "x"}, headers=h).status_code == 422
    assert client.get(f"{API}/feed-inventory/exceptions", headers=worker).status_code == 200, "anyone on Feed sees them"


# ------------------------------------------------- issue: FIFO, lot, holds
def test_fifo_takes_the_oldest_lots_first_and_a_named_lot_only_itself(client):
    h = _h(client)
    p = _product(client, h, "Integrity hay fifo")
    _lot(client, h, p["id"], 30, days_ago=5, code="FIFO-1")
    _lot(client, h, p["id"], 40, days_ago=3, code="FIFO-2")
    newest = _lot(client, h, p["id"], 50, days_ago=1, code="FIFO-3")
    r = _feed(client, h, p["id"], 50)
    assert r.status_code == 201, r.text
    assert _lots(client, h, p["id"]) == {"FIFO-1": 0, "FIFO-2": 20, "FIFO-3": 50}
    assert all(c["lot_id"] for c in r.json()["components"])
    r = _feed(client, h, p["id"], 25, lot_id=newest["id"])
    assert r.status_code == 201
    assert _lots(client, h, p["id"]) == {"FIFO-1": 0, "FIFO-2": 20, "FIFO-3": 25}
    assert _avail(client, h, p["id"])["on_hand"] == 45
    _consistent(client, h)


def test_a_held_lot_is_not_available_and_cannot_be_named(client):
    h = _h(client)
    p = _product(client, h, "Integrity hay hold")
    held = _lot(client, h, p["id"], 100, days_ago=4, code="HOLD-Q")
    _lot(client, h, p["id"], 30, days_ago=2, code="HOLD-OK")
    assert client.patch(f"{API}/feed-lots/{held['id']}/status", json={"status": "quarantined", "reason": "Mould seen"}, headers=h).status_code == 200
    a = _avail(client, h, p["id"])
    assert (a["on_hand"], a["unusable"], a["available"]) == (130, 100, 30)
    named = _feed(client, h, p["id"], 10, lot_id=held["id"])
    assert named.status_code == 422 and "quarantined" in named.json()["detail"]
    assert _feed(client, h, p["id"], 31).status_code == 422, "FIFO never reaches into the held lot"
    assert _feed(client, h, p["id"], 30).status_code == 201
    assert _lots(client, h, p["id"]) == {"HOLD-Q": 100, "HOLD-OK": 0}
    assert client.patch(f"{API}/feed-lots/{held['id']}/status", json={"status": "active", "reason": "Lab clear"}, headers=h).status_code == 200
    assert _avail(client, h, p["id"])["available"] == 100
    _consistent(client, h)


def test_a_product_reservation_holds_its_kilos_back_without_ever_issuing_from_no_lot(client):
    """Before v0.8.4 a reservation of the product was subtracted from every
    lot in turn, so an issue the arithmetic allowed came out partly with no
    lot — silently, without any override."""
    h = _h(client)
    p = _product(client, h, "Integrity hay reserve")
    _lot(client, h, p["id"], 50, days_ago=3, code="RES-1")
    _lot(client, h, p["id"], 50, days_ago=1, code="RES-2")
    r = client.post(f"{API}/feed-allocations", json={"feed_product_id": p["id"], "quantity": 30, "subject_type": "animal",
                                                     "subject_id": "horse-h07", "purpose": "Thunder's hay"}, headers=h)
    assert r.status_code == 201, r.text
    assert _avail(client, h, p["id"])["available"] == 70
    fed = _feed(client, h, p["id"], 70)
    assert fed.status_code == 201, fed.text
    assert all(c["lot_id"] for c in fed.json()["components"]), fed.json()["components"]
    assert _exceptions(client, h, p["id"]) == []
    assert _lots(client, h, p["id"]) == {"RES-1": 0, "RES-2": 30}
    assert _feed(client, h, p["id"], 1).status_code == 422, "the 30 kg are Thunder's"
    _consistent(client, h)


def test_a_reservation_on_a_held_lot_is_not_subtracted_twice(client):
    h = _h(client)
    p = _product(client, h, "Integrity hay reserve held")
    held = _lot(client, h, p["id"], 100, days_ago=3, code="RH-Q")
    _lot(client, h, p["id"], 100, days_ago=1, code="RH-OK")
    r = client.post(f"{API}/feed-allocations", json={"feed_product_id": p["id"], "quantity": 50, "lot_id": held["id"], "purpose": "Heifers"},
                    headers=h)
    assert r.status_code == 201, r.text
    client.patch(f"{API}/feed-lots/{held['id']}/status", json={"status": "quarantined", "reason": "Mould"}, headers=h)
    assert _avail(client, h, p["id"])["available"] == 100


# ------------------------------------------------ corrections and returns
def test_a_return_comes_out_of_its_lot_and_never_below_zero(client):
    h = _h(client)
    p = _product(client, h, "Integrity hay return")
    lot = _lot(client, h, p["id"], 40, days_ago=2, code="RET-A")
    _lot(client, h, p["id"], 60, days_ago=1, code="RET-B")
    ok = client.post(f"{API}/feed-inventory/adjustments", json={"feed_product_id": p["id"], "lot_id": lot["id"], "delta": -15, "reason": "return",
                                                                "explanation": "Wet bales sent back to the supplier"}, headers=h)
    assert ok.status_code == 201, ok.text
    assert _lots(client, h, p["id"]) == {"RET-A": 25, "RET-B": 60}
    too_much = client.post(f"{API}/feed-inventory/adjustments", json={"feed_product_id": p["id"], "lot_id": lot["id"], "delta": -26, "reason": "return",
                                                                      "explanation": "More than it holds"}, headers=h)
    assert too_much.status_code == 422, too_much.text
    spill = client.post(f"{API}/feed-inventory/adjustments", json={"feed_product_id": p["id"], "delta": -35, "reason": "waste",
                                                                   "explanation": "Rain through the roof"}, headers=h)
    assert spill.status_code == 201 and len(spill.json()["transaction_ids"]) == 2
    assert _lots(client, h, p["id"]) == {"RET-A": 0, "RET-B": 50}, "a loss with no lot named is taken oldest first"
    assert client.post(f"{API}/feed-inventory/adjustments", json={"feed_product_id": p["id"], "delta": -51, "reason": "waste",
                                                                  "explanation": "x"}, headers=h).status_code == 422
    _consistent(client, h)


def test_a_gain_with_no_lot_to_put_it_in_gets_a_lot_of_its_own(client):
    h = _h(client)
    p = _product(client, h, "Integrity hay gain")
    r = client.post(f"{API}/feed-inventory/adjustments", json={"feed_product_id": p["id"], "delta": 12, "reason": "adjustment",
                                                               "explanation": "Bales found behind the stack"}, headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["lot_ids"] and r.json()["lot_ids"][0]
    a = _avail(client, h, p["id"])
    assert (a["on_hand"], a["lot_on_hand"], a["untraced"]) == (12, 12, 0)
    _consistent(client, h)


# ------------------------------------------------- approvals name both people
def test_an_employees_mix_over_the_stock_names_the_employee_and_the_approving_manager(client, db_session):
    session, _ = db_session
    _no_approve(session)
    worker, manager = _h(client, WORKER), _h(client)
    made = client.post(f"{API}/feed-mixes", json={"new_product_name": "Integrity heifer mix",
                                                  "components": [{"feed_product_id": "fp-barley", "actual_quantity": 30}]}, headers=manager)
    assert made.status_code == 201, made.text
    barley = _avail(client, manager, "fp-barley")["available"]
    body = {"feed_product_id": made.json()["feed_product_id"], "components": [{"feed_product_id": "fp-barley", "actual_quantity": barley + 40}],
            "output_quantity": barley + 40}
    request = client.post(f"{API}/approval-requests", json={"kind": "feed_mix", "payload": body, "reason": "Big batch for the weekend"},
                          headers=worker).json()
    short = client.post(f"{API}/approval-requests/{request['id']}/approve", json={}, headers=manager)
    assert short.status_code == 422 and "Not enough" in short.json()["detail"], short.text
    ok = client.post(f"{API}/approval-requests/{request['id']}/approve",
                     json={"allow_negative": True, "override_reason": "Barley bags in the truck, delivery note to follow"}, headers=manager)
    assert ok.status_code == 200, ok.text
    [exc] = _exceptions(client, manager, "fp-barley", "open")
    worker_id = session.scalar(select(models.User.id).where(models.User.email == WORKER))
    manager_id = session.scalar(select(models.User.id).where(models.User.email == "rami@origami.farm"))
    assert exc["requested_by"] == worker_id and exc["approved_by"] == manager_id
    assert exc["approval_request_id"] == request["id"] and exc["source_entity_type"] == "feed_batch"
    assert exc["reason"] == "Barley bags in the truck, delivery note to follow" and round(exc["quantity"], 3) == 40
    _consistent(client, manager)


# ------------------------------------------------ the other stock writers
def test_a_device_cannot_push_a_bare_feed_quantity(client):
    h = _h(client)
    before = _avail(client, h, "fp-dairy-mix")["on_hand"]
    item = {"idempotency_key": "integrity-1", "operation": "create", "entity_type": "inventory_item", "entity_id": "feed-dairy-mix",
            "payload": {"direction": "out", "quantity": 5}, "client_created_at": "2026-11-25T09:00:00Z"}
    r = client.post(f"{API}/sync/push", json={"farm_id": "farm-origami", "device_id": "tablet-01", "items": [item]}, headers=h)
    assert r.status_code == 200 and r.json()["results"][0]["status"] == "rejected", r.text
    assert _avail(client, h, "fp-dairy-mix")["on_hand"] == before
    _consistent(client, h)


def test_a_shop_sale_of_feed_is_issued_from_its_lots(client, db_session):
    session, _ = db_session
    h = _h(client)
    lots_before = _lots(client, h, "fp-dairy-mix")
    on_hand = _avail(client, h, "fp-dairy-mix")["on_hand"]
    r = client.post(f"{API}/visit-retail-sales", json={"lines": [{"inventory_item_id": "feed-dairy-mix", "quantity": 2, "unit_price": 3}]}, headers=h)
    assert r.status_code == 201, r.text
    assert _avail(client, h, "fp-dairy-mix")["on_hand"] == on_hand - 2
    after = _lots(client, h, "fp-dairy-mix")
    assert sum(lots_before.values()) - sum(after.values()) == 2, "the kilos left a lot"
    session.expire_all()
    sold = session.scalars(select(models.InventoryTransaction).where(models.InventoryTransaction.reason == "visitor_retail_sale",
                                                                     models.InventoryTransaction.item_id == "feed-dairy-mix")).all()
    assert sold and all(t.lot_id for t in sold)
    _consistent(client, h)


def test_every_untraced_movement_belongs_to_an_exception_or_an_opening_balance(client, db_session):
    session, _ = db_session
    h = _h(client)
    hay = _product(client, h, "Integrity hay tags")
    _lot(client, h, hay["id"], 10)
    assert _feed(client, h, hay["id"], 30, allow_negative=True, reason="Not entered yet").status_code == 201
    session.expire_all()
    # Once a feed has lots, a movement with no lot is an exception's, or the
    # carry-over of stock recorded before lots (the demo farm's older
    # movements are that history, written before its feeds had lots).
    first_lot = {pid: at for pid, at in session.execute(select(fm.FeedLot.feed_product_id, func.min(fm.FeedLot.created_at)).group_by(fm.FeedLot.feed_product_id))}
    loose = [
        (t.reason, product_id) for t, product_id in session.execute(
            select(models.InventoryTransaction, fm.FeedProduct.id).join(fm.FeedProduct, fm.FeedProduct.inventory_item_id == models.InventoryTransaction.item_id)
            .where(models.InventoryTransaction.lot_id.is_(None), models.InventoryTransaction.stock_exception_id.is_(None),
                   models.InventoryTransaction.reason.not_in(("opening_balance", "count_correction"))))
        if product_id in first_lot and t.created_at >= first_lot[product_id]
    ]
    assert loose == []
    tagged = session.scalars(select(models.InventoryTransaction).where(models.InventoryTransaction.item_id == hay["inventory_item_id"],
                                                                       models.InventoryTransaction.lot_id.is_(None))).all()
    assert len(tagged) == 1 and tagged[0].stock_exception_id and tagged[0].actor_user_id


def test_a_stored_figure_that_drifts_is_reported_and_rebuilt_from_its_movements(client, db_session):
    """The reconciliation runbook's last step: a stock line or a lot whose
    stored figure no longer equals its movements (only a defect or a hand
    edit can do that) is named by the integrity check and set back to its
    movements — no movement posted, the old figure in the audit log."""
    from app.feed_stock_integrity import main as cli  # noqa: F401 - the runbook's entry point imports cleanly
    from app.services import feed_inventory_service as inv

    session, _ = db_session
    h = _h(client)
    item = session.get(models.InventoryItem, "feed-corn-silage")
    lot = session.scalars(select(fm.FeedLot).where(fm.FeedLot.feed_product_id == "fp-corn-silage", fm.FeedLot.quantity_on_hand > 0)).first()
    item.current_qty += 7
    lot.quantity_on_hand += 3
    session.commit()
    report = client.get(f"{API}/feed-inventory/integrity", headers=h).json()
    [bad] = [p for p in report["products"] if not p["consistent"]]
    assert bad["feed_product_id"] == "fp-corn-silage" and len(bad["problems"]) == 2, bad
    moves = _movements(session, "feed-corn-silage")
    out = inv.rebuild_projections(session, session.get(fm.FeedProduct, "fp-corn-silage"), user_id="user-rami")
    session.commit()
    assert set(out["changes"]) == {"stock_line", f"lot:{lot.lot_code}"}
    assert _movements(session, "feed-corn-silage") == moves, "no movement is posted"
    _consistent(client, h)
    session.expire_all()
    logged = session.scalars(select(models.AuditLog).where(models.AuditLog.action == "feed_stock_projection_rebuilt")).all()
    assert logged and logged[-1].changes_json["stock_line"] == {"from": item.current_qty + 7, "to": item.current_qty}
