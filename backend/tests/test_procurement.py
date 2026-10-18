"""Purchase requisitions (database/PROCUREMENT-SCHEMA.md §5–§6, §12): a
draft is not a purchase; submit and approve are separate steps with the
approving authority snapshotted; a cancelled or rejected draft counts as
nothing; incoming supply is visible to the pharmacy and never counted as
stock.
"""
from __future__ import annotations

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.domain import models
from tests.conftest import auth_headers

API = "/api/v1"
NACL, ELECTROLYTE = "med-nacl", "med-electrolyte"


def _h(client: TestClient) -> dict:
    return auth_headers(client)


def _worker(client: TestClient) -> dict:
    return auth_headers(client, "karim.worker@origami.farm", "farmos123")


class TestRequisitions:
    def test_a_manual_requisition_is_drafted_submitted_and_decided_with_authority(self, client: TestClient, db_session):
        db, _ = db_session
        r = client.post(f"{API}/procurement/requisitions", json={"lines": []}, headers=_h(client))
        assert r.status_code == 422
        r = client.post(f"{API}/procurement/requisitions", json={"lines": [{"inventory_item_id": ELECTROLYTE, "requested_quantity": 40, "uom_code": "boxes"}]}, headers=_h(client))
        assert r.status_code == 422 and "Unknown unit" in r.json()["detail"]
        r = client.post(f"{API}/procurement/requisitions", json={
            "purpose_code": "pharmacy_replenishment", "justification": "Summer heat: electrolytes for the flocks",
            "lines": [{"inventory_item_id": ELECTROLYTE, "requested_quantity": 40}, {"inventory_item_id": NACL, "requested_quantity": 12, "estimated_unit_price": 2.6, "specification": "1 L bags"}],
        }, headers=_h(client))
        assert r.status_code == 201, r.text
        req = r.json()
        assert req["status"] == "draft" and req["requisition_no"] == "REQ-000001" and req["currency"] == "USD" and req["requested_by_name"] == "Rami Farah"
        assert req["lines"][0]["uom_code"] == "sachet" and req["lines"][0]["estimated_unit_price"] == 0.9, "the unit and price default from the item"
        assert req["total_estimated_amount"] == round(40 * 0.9 + 12 * 2.6, 4)
        task = db.get(models.Task, req["task_id"])
        assert task.source_type == "purchase_requisition" and task.assigned_to == "user-rami" and task.status == "open"
        # Incoming only once submitted; a draft is intent.
        assert client.get(f"{API}/pharmacy/medicines/{ELECTROLYTE}", headers=_h(client)).json()["confirmed_incoming"] == 0
        r = client.post(f"{API}/procurement/requisitions/{req['id']}/submit", headers=_h(client))
        assert r.status_code == 200 and r.json()["status"] == "submitted" and r.json()["submitted_at"]
        assert client.get(f"{API}/pharmacy/medicines/{ELECTROLYTE}", headers=_h(client)).json()["confirmed_incoming"] == 40
        assert client.post(f"{API}/procurement/requisitions/{req['id']}/submit", headers=_h(client)).status_code == 422
        # A worker cannot approve; a rejection needs a reason; the decision snapshots who could.
        r = client.post(f"{API}/procurement/requisitions/{req['id']}/approve", json={}, headers=_worker(client))
        assert r.status_code == 403, r.text
        r = client.post(f"{API}/procurement/requisitions/{req['id']}/reject", json={"comments": ""}, headers=_h(client))
        assert r.status_code == 422
        r = client.post(f"{API}/procurement/requisitions/{req['id']}/approve", json={"comments": "Go ahead before the heat"}, headers=_h(client))
        assert r.status_code == 200, r.text
        approved = r.json()
        assert approved["status"] == "approved" and approved["decided_by"] == "user-rami" and all(l["status"] == "approved" for l in approved["lines"])
        assert approved["approvals"][0]["authority"]["basis"] == "role"
        db.expire_all()
        assert db.get(models.Task, req["task_id"]).status == "done"
        assert client.post(f"{API}/procurement/requisitions/{req['id']}/approve", json={}, headers=_h(client)).status_code == 422, "decided once"
        assert client.post(f"{API}/procurement/requisitions/{req['id']}/cancel", json={"reason": "late"}, headers=_h(client)).status_code == 200
        listed = client.get(f"{API}/procurement/requisitions", params={"status": "cancelled"}, headers=_h(client)).json()
        assert [x["id"] for x in listed] == [req["id"]]
        assert client.get(f"{API}/pharmacy/medicines/{ELECTROLYTE}", headers=_h(client)).json()["confirmed_incoming"] == 0

    def test_a_shortage_draft_is_withdrawn_when_the_shortage_resolves(self, client: TestClient):
        low = next(a for a in client.get(f"{API}/pharmacy/alerts", params={"inventory_item_id": NACL}, headers=_h(client)).json() if a["alert_type"] == "BELOW_MINIMUM_STOCK")
        req = client.post(f"{API}/pharmacy/alerts/{low['id']}/requisition", headers=_h(client)).json()["requisition"]
        assert req["status"] == "draft"
        # Stock arrives another way (a donation): the draft nobody acted on is cancelled with the shortage.
        r = client.post(f"{API}/pharmacy/lots/receive", json={"inventory_item_id": NACL, "quantity": 10, "lot_code": "NACL-GIFT", "expiry_date": "2027-12-01T00:00:00Z", "source_type": "donation"}, headers=_h(client))
        assert r.status_code == 201, r.text
        r = client.get(f"{API}/procurement/requisitions/{req['id']}", headers=_h(client))
        assert r.status_code == 200 and r.json()["status"] == "cancelled", r.text
        cancelled = client.get(f"{API}/procurement/requisitions", params={"status": "cancelled"}, headers=_h(client)).json()
        assert [x["id"] for x in cancelled] == [req["id"]]
        # The worker with inventory view reads requisitions; without it, no.
        r = client.get(f"{API}/procurement/requisitions", headers=_worker(client))
        assert r.status_code == 200
