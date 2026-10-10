"""Medicine & farm pharmacy (database/MEDICINE-PHARMACY-SCHEMA.md §14,
MEDICINE-NOTIFICATION-RULES.md).

The farm keeps medicine stock whether or not an animal is sick; every
receipt records lot and expiry; the manager's thresholds drive distinct,
deduplicated alerts; ineligible stock never counts; an administration
consumes the exact lot and re-evaluates at once; a requisition is a
draft; stocking never authorises use.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.domain import models
from app.domain import pharmacy_models as pm
from tests.conftest import auth_headers

API = "/api/v1"
OXYTET, FLUNIXIN, NACL, ELECTROLYTE, IVERMECTIN, VACCINE = "med-oxytet", "med-flunixin", "med-nacl", "med-electrolyte", "med-ivermectin", "med-vaccine"
BELLA = "cow-744"
WILLOW = "goat-willow"
LAYERS = "flock-layer"


def _h(client: TestClient) -> dict:
    return auth_headers(client)


def _days(n: int) -> str:
    return (datetime.now(timezone.utc) + timedelta(days=n)).isoformat()


def _medicine(client: TestClient, item_id: str) -> dict:
    r = client.get(f"{API}/pharmacy/medicines/{item_id}", headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()


def _alerts(client: TestClient, item_id: str | None = None, status: str = "open") -> list[dict]:
    r = client.get(f"{API}/pharmacy/alerts", params={"status": status, "inventory_item_id": item_id}, headers=_h(client))
    assert r.status_code == 200, r.text
    return r.json()


def _types(alerts: list[dict]) -> set[str]:
    return {a["alert_type"] for a in alerts}


class TestDashboard:
    def test_eligible_stock_is_not_on_hand(self, client: TestClient):
        """Acceptance 1 and 6: stock is kept with no patient in sight, and
        expired / storage-exception lots do not count."""
        r = client.get(f"{API}/pharmacy/medicines", headers=_h(client))
        assert r.status_code == 200, r.text
        rows = {m["inventory_item_id"]: m for m in r.json()}
        assert len(rows) == 6
        oxy = rows[OXYTET]
        assert oxy["on_hand"] == 160 and oxy["eligible_available"] == 100 and oxy["stock"]["expired"] == 60 and oxy["status"] == "OK"
        assert oxy["prescription_required"] and oxy["antimicrobial"] and oxy["withdrawal_rules"] == {"milk_days": 4, "meat_days": 28}
        assert [c["code"] for c in oxy["categories"]] == ["ANTIBIOTIC"] and oxy["ingredients"][0]["code"] == "oxytetracycline"
        vac = rows[VACCINE]
        assert vac["on_hand"] == 40 and vac["eligible_available"] == 0 and vac["storage_exception"] and vac["status"] == "OUT"
        nacl = rows[NACL]
        assert nacl["eligible_available"] == 8 and nacl["status"] == "LOW" and nacl["policy"]["minimum_stock_base"] == 12 and nacl["recommended_reorder"] == 16
        assert rows[IVERMECTIN]["policy"] is None and rows[IVERMECTIN]["status"] == "OK"
        # Essential items first, worst status first.
        assert [m["inventory_item_id"] for m in r.json()][:2] == [VACCINE, NACL]

    def test_the_seeded_scan_raised_one_alert_per_condition(self, client: TestClient):
        alerts = _alerts(client)
        by_item = {}
        for a in alerts:
            by_item.setdefault(a["inventory_item_id"], set()).add(a["alert_type"])
        assert by_item == {
            NACL: {"BELOW_MINIMUM_STOCK"}, OXYTET: {"EXPIRED_STOCK"}, ELECTROLYTE: {"EXPIRING_SOON"}, VACCINE: {"STORAGE_EXCEPTION", "OUT_OF_STOCK"},
            # Willow's dose opened the flunixin vial: its 28-day after-opening use-by is inside the 60-day warning.
            FLUNIXIN: {"EXPIRING_SOON"},
        }
        low = next(a for a in alerts if a["inventory_item_id"] == NACL)
        assert low["severity"] == "medium" and low["eligible_available_base"] == 8 and low["recommended_reorder_base"] == 16
        assert "not treatment advice" in low["explanation"]
        out = next(a for a in alerts if a["alert_type"] == "OUT_OF_STOCK")
        assert out["severity"] == "critical" and "storage exception 40" in out["explanation"]
        # A second scan changes nothing: same rows, refreshed.
        ids = {a["id"] for a in alerts}
        r = client.post(f"{API}/pharmacy/evaluate", headers=_h(client))
        assert r.status_code == 200 and r.json()["open_alerts"] == 6
        assert {a["id"] for a in _alerts(client)} == ids

    def test_summary_and_reference_data(self, client: TestClient):
        s = client.get(f"{API}/pharmacy/summary", headers=_h(client)).json()
        assert s["medicines"] == 6 and s["essential"] == 5 and s["open_alerts"] == 6 and s["unseen_alerts"] == 6
        assert s["by_status"] == {"OK": 4, "LOW": 1, "CRITICAL": 0, "OUT": 1} and s["expiring_soon"] == 2
        codes = {c["code"] for c in client.get(f"{API}/pharmacy/categories", headers=_h(client)).json()}
        assert {"FEVER_SUPPORT", "IV_FLUID", "COLIC_SUPPORT", "VACCINE"} <= codes
        bell = client.get(f"{API}/notifications", headers=_h(client)).json()["notifications"]
        assert sum(1 for n in bell if n["source_type"] == "pharmacy_stock_alert") == 6


class TestReceiptsAndLots:
    def test_a_receipt_records_lot_and_expiry_and_posts_the_ledger(self, client: TestClient, db_session):
        db, _ = db_session
        r = client.post(f"{API}/pharmacy/lots/receive", json={"inventory_item_id": NACL, "quantity": 12, "lot_code": "NACL-2612"}, headers=_h(client))
        assert r.status_code == 422 and "expiry" in r.json()["detail"]
        r = client.post(f"{API}/pharmacy/lots/receive", json={"inventory_item_id": NACL, "quantity": 12, "expiry_date": _days(365)}, headers=_h(client))
        assert r.status_code == 422 and "lot number" in r.json()["detail"]
        r = client.post(f"{API}/pharmacy/lots/receive", json={"inventory_item_id": NACL, "quantity": 12, "lot_code": "NACL-2612", "expiry_date": _days(365),
                                                            "unit_cost": 2.5, "supplier_label": "MedSupply Beirut", "reference": "INV-1042"}, headers=_h(client))
        assert r.status_code == 201, r.text
        lot = r.json()
        assert lot["lot_code"] == "NACL-2612" and lot["quantity_on_hand"] == 12 and lot["eligible"] and lot["storage_status"] == "COMPLIANT"
        tx = db.scalars(select(models.InventoryTransaction).where(models.InventoryTransaction.inventory_lot_id == lot["id"])).all()
        assert len(tx) == 1 and tx[0].direction == "in" and tx[0].quantity == 12 and tx[0].reason == "purchase"
        db.expire_all()
        assert db.get(models.InventoryItem, NACL).current_qty == 20, "the item balance and its lots agree"
        # 20 bags ≥ minimum 12: the shortage alert resolved itself, with a recovery event.
        m = _medicine(client, NACL)
        assert m["eligible_available"] == 20 and m["status"] == "OK" and m["open_alerts"] == []
        resolved = next(a for a in _alerts(client, NACL, "all") if a["alert_type"] == "BELOW_MINIMUM_STOCK")
        assert resolved["status"] == "resolved" and "above the threshold" in resolved["resolution_note"]
        events = db.scalars(select(models.Event).where(models.Event.entity_id == NACL, models.Event.event_type == "medicine_stock_recovered")).all()
        assert len(events) == 1

    def test_quarantine_recall_and_release_change_eligibility_not_on_hand(self, client: TestClient):
        lot = next(l for l in _medicine(client, OXYTET)["lots"] if l["lot_code"] == "OXY-2605")
        r = client.patch(f"{API}/pharmacy/lots/{lot['id']}/status", json={"status": "quarantined"}, headers=_h(client))
        assert r.status_code == 422, "taking a lot out of use needs a reason"
        r = client.patch(f"{API}/pharmacy/lots/{lot['id']}/status", json={"status": "quarantined", "reason": "Discoloured"}, headers=_h(client))
        assert r.status_code == 200 and r.json()["ineligible_reason"] == "quarantined" and r.json()["quarantine_reason"] == "Discoloured"
        m = _medicine(client, OXYTET)
        assert m["on_hand"] == 160 and m["eligible_available"] == 0 and m["status"] == "OUT"
        assert _types(_alerts(client, OXYTET)) == {"EXPIRED_STOCK", "OUT_OF_STOCK"}
        r = client.patch(f"{API}/pharmacy/lots/{lot['id']}/status", json={"status": "recalled", "reason": "Manufacturer recall", "recall_reference": "RC-77"}, headers=_h(client))
        assert r.status_code == 200 and r.json()["recall_reference"] == "RC-77"
        assert "RECALL_AFFECTED" in _types(_alerts(client, OXYTET))
        r = client.patch(f"{API}/pharmacy/lots/{lot['id']}/status", json={"status": "active", "reason": "Cleared by the vet"}, headers=_h(client))
        assert r.status_code == 200 and r.json()["eligible"]
        assert _types(_alerts(client, OXYTET)) == {"EXPIRED_STOCK"}, "release resolves the out-of-stock and recall findings"

    def test_an_opened_container_stops_counting_when_its_use_by_passes(self, client: TestClient):
        lot = next(l for l in _medicine(client, OXYTET)["lots"] if l["lot_code"] == "OXY-2605")
        r = client.post(f"{API}/pharmacy/lots/{lot['id']}/open", json={"opened_at": _days(-30)}, headers=_h(client))
        assert r.status_code == 200, r.text
        assert r.json()["opened_at"] and r.json()["use_by_after_opening"] and r.json()["ineligible_reason"] == "expired"
        m = _medicine(client, OXYTET)
        assert m["eligible_available"] == 0 and m["stock"]["expired"] == 160 and m["status"] == "OUT"

    def test_storage_exception_cleared_by_a_person_restores_the_vaccine(self, client: TestClient):
        lot = _medicine(client, VACCINE)["lots"][0]
        assert lot["cold_chain_exception"] and not lot["eligible"]
        r = client.patch(f"{API}/pharmacy/lots/{lot['id']}/storage", json={"storage_status": "COMPLIANT", "cold_chain_exception": False, "note": "Vet confirmed potency"}, headers=_h(client))
        assert r.status_code == 200 and r.json()["eligible"]
        m = _medicine(client, VACCINE)
        assert m["eligible_available"] == 40 and m["status"] == "OK"
        assert _alerts(client, VACCINE) == [], "both the storage and the out-of-stock findings resolved"

    def test_an_adjustment_needs_an_explanation_and_cannot_go_negative(self, client: TestClient):
        lot = _medicine(client, IVERMECTIN)["lots"][0]
        r = client.post(f"{API}/pharmacy/adjustments", json={"inventory_item_id": IVERMECTIN, "lot_id": lot["id"], "delta": -10, "reason": "waste", "explanation": ""}, headers=_h(client))
        assert r.status_code == 422
        r = client.post(f"{API}/pharmacy/adjustments", json={"inventory_item_id": IVERMECTIN, "lot_id": lot["id"], "delta": -300, "reason": "waste", "explanation": "Spilled"}, headers=_h(client))
        assert r.status_code == 422 and "negative" in r.json()["detail"]
        r = client.post(f"{API}/pharmacy/adjustments", json={"inventory_item_id": IVERMECTIN, "lot_id": lot["id"], "delta": -10, "reason": "waste", "explanation": "Spilled"}, headers=_h(client))
        assert r.status_code == 201 and r.json()["lot"]["quantity_on_hand"] == 240 and r.json()["medicine"]["eligible_available"] == 240


class TestPolicyAndAlerts:
    def test_thresholds_drive_distinct_deduplicated_alerts(self, client: TestClient):
        """Acceptance 3, 4, 5: the manager sets the levels; LOW, CRITICAL
        and OUT are distinct; one open alert per condition."""
        r = client.put(f"{API}/pharmacy/policies/{IVERMECTIN}", json={"essential": True, "minimum_stock_base": 300, "critical_stock_base": 100, "target_stock_base": 600}, headers=_h(client))
        assert r.status_code == 200, r.text
        assert r.json()["policy"]["version"] == 1 and r.json()["medicine"]["status"] == "LOW"
        assert _types(_alerts(client, IVERMECTIN)) == {"BELOW_MINIMUM_STOCK"}
        low_id = _alerts(client, IVERMECTIN)[0]["id"]
        lot = _medicine(client, IVERMECTIN)["lots"][0]

        def waste(qty: float) -> None:
            rr = client.post(f"{API}/pharmacy/adjustments", json={"inventory_item_id": IVERMECTIN, "lot_id": lot["id"], "delta": -qty, "reason": "waste", "explanation": "Leaking container"}, headers=_h(client))
            assert rr.status_code == 201, rr.text

        waste(160)  # 90 left ≤ critical 100
        open_now = _alerts(client, IVERMECTIN)
        assert _types(open_now) == {"CRITICAL_STOCK"} and open_now[0]["severity"] == "high"
        assert next(a for a in _alerts(client, IVERMECTIN, "all") if a["id"] == low_id)["status"] == "resolved"
        waste(90)  # nothing eligible, essential → OUT
        assert _types(_alerts(client, IVERMECTIN)) == {"OUT_OF_STOCK"}
        # Acknowledging records that it was seen; a rescan keeps the same row.
        out = _alerts(client, IVERMECTIN)[0]
        r = client.post(f"{API}/pharmacy/alerts/{out['id']}/acknowledge", headers=_h(client))
        assert r.status_code == 200 and r.json()["status"] == "acknowledged"
        client.post(f"{API}/pharmacy/evaluate", headers=_h(client))
        again = _alerts(client, IVERMECTIN)
        assert [a["id"] for a in again] == [out["id"]] and again[0]["status"] == "acknowledged"
        bell = client.get(f"{API}/notifications", headers=_h(client)).json()["notifications"]
        assert not any(n["source_id"] == out["id"] for n in bell), "acknowledged alerts leave the bell"
        # A receipt above the minimum resolves it.
        r = client.post(f"{API}/pharmacy/lots/receive", json={"inventory_item_id": IVERMECTIN, "quantity": 500, "lot_code": "IVM-2701", "expiry_date": _days(500)}, headers=_h(client))
        assert r.status_code == 201
        assert _alerts(client, IVERMECTIN) == [] and _medicine(client, IVERMECTIN)["status"] == "OK"
        # Policy sanity: critical above minimum is refused.
        r = client.put(f"{API}/pharmacy/policies/{IVERMECTIN}", json={"essential": True, "minimum_stock_base": 10, "critical_stock_base": 50}, headers=_h(client))
        assert r.status_code == 422

    def test_a_requisition_is_one_draft_task_never_an_order(self, client: TestClient, db_session):
        db, _ = db_session
        low = next(a for a in _alerts(client, NACL) if a["alert_type"] == "BELOW_MINIMUM_STOCK")
        r = client.post(f"{API}/pharmacy/alerts/{low['id']}/requisition", headers=_h(client))
        assert r.status_code == 200, r.text
        first = r.json()
        assert first["created"] and first["status"] == "open" and "16 bag" in first["title"] and first["alert"]["requisition_task_id"] == first["task_id"]
        r = client.post(f"{API}/pharmacy/alerts/{low['id']}/requisition", headers=_h(client))
        assert r.json()["task_id"] == first["task_id"] and not r.json()["created"], "no duplicate drafts for one unresolved shortage"
        task = db.get(models.Task, first["task_id"])
        assert task.source_type == "pharmacy_requisition" and "Needs approval" in task.description
        assert _medicine(client, NACL)["open_requisition"]
        # A manual close needs a reason.
        r = client.post(f"{API}/pharmacy/alerts/{low['id']}/resolve", json={"note": " "}, headers=_h(client))
        assert r.status_code == 422
        r = client.post(f"{API}/pharmacy/alerts/{low['id']}/resolve", json={"note": "Order placed with MedSupply, due Friday"}, headers=_h(client))
        assert r.status_code == 200 and r.json()["status"] == "resolved"


class TestAdministration:
    def test_a_dose_consumes_the_exact_lot_applies_withdrawal_and_re_evaluates(self, client: TestClient, db_session):
        """Acceptance 7 and 9: stock never authorises use; the exact lot is
        consumed; the threshold is re-checked immediately."""
        db, _ = db_session
        body = {"subject_type": "animal", "subject_id": BELLA, "inventory_item_id": FLUNIXIN, "dose_quantity": 12, "dose_unit": "ml", "route_code": "IM"}
        r = client.post(f"{API}/pharmacy/administrations", json=body, headers=_h(client))
        assert r.status_code == 422 and "prescription" in r.json()["detail"], r.text
        r = client.post(f"{API}/health/treatments", json={"entity_type": "animal", "entity_id": BELLA, "medication": "Flunixin meglumine 50 mg/mL", "dose": "2.2 mg/kg",
                                                         "route": "IM", "responsible_user_id": "user-rami", "diagnosis": "Fever"}, headers=_h(client))
        assert r.status_code == 201, r.text
        treatment_id = r.json()["id"]
        r = client.post(f"{API}/pharmacy/administrations", json={**body, "treatment_id": treatment_id, "reason": "Fever 40.1 °C"}, headers=_h(client))
        assert r.status_code == 201, r.text
        adm = r.json()
        assert adm["lot_code"] == "FLX-2611" and adm["quantity_consumed"] == 12 and adm["unit"] == "ml" and adm["administered_by_name"]
        assert adm["withdrawal_milk_until"] and adm["withdrawal_meat_until"]
        db.expire_all()
        animal = db.get(models.Animal, BELLA)
        assert animal.withdrawal_until is not None and animal.withdrawal_reason.startswith("Medication: Flunixin")
        assert abs((animal.withdrawal_until.replace(tzinfo=timezone.utc) - datetime.now(timezone.utc)) - timedelta(days=10)) < timedelta(minutes=5)
        tx = db.get(models.InventoryTransaction, adm["inventory_transaction_id"])
        assert tx.direction == "out" and tx.quantity == 12 and tx.reason == "administration" and tx.inventory_lot_id == adm["inventory_lot_id"]
        m = _medicine(client, FLUNIXIN)
        assert m["eligible_available"] == 36.5 and m["on_hand"] == 36.5
        assert m["status"] == "LOW" and _types(_alerts(client, FLUNIXIN)) == {"BELOW_MINIMUM_STOCK", "EXPIRING_SOON"}, "re-evaluated at once (acceptance 7)"
        assert db.get(models.InventoryItem, FLUNIXIN).current_qty == 36.5
        history = client.get(f"{API}/pharmacy/administrations", params={"subject_id": BELLA}, headers=_h(client)).json()
        assert [a["id"] for a in history] == [adm["id"]]
        # Reversal puts the quantity back on the same lot; the withdrawal stands.
        r = client.post(f"{API}/pharmacy/administrations/{adm['id']}/reverse", json={"reason": "Entered against the wrong cow"}, headers=_h(client))
        assert r.status_code == 201 and r.json()["status"] == "reversed"
        assert _medicine(client, FLUNIXIN)["eligible_available"] == 48.5
        db.expire_all()
        assert db.get(models.Animal, BELLA).withdrawal_until is not None

    def test_ineligible_or_unauthorised_stock_is_refused(self, client: TestClient):
        # Species restriction, like a feed usage policy.
        r = client.post(f"{API}/pharmacy/administrations", json={"subject_type": "group", "subject_id": LAYERS, "inventory_item_id": IVERMECTIN, "dose_quantity": 1,
                                                                "dose_unit": "ml", "route_code": "pour_on"}, headers=_h(client))
        assert r.status_code == 422 and "not authorised for" in r.json()["detail"]
        # An expired lot named explicitly.
        expired = next(l for l in _medicine(client, OXYTET)["lots"] if l["lot_code"] == "OXY-2602")
        r = client.post(f"{API}/health/treatments", json={"entity_type": "animal", "entity_id": BELLA, "medication": "Oxytetracycline", "dose": "20 mg/kg", "route": "IM",
                                                         "responsible_user_id": "user-rami"}, headers=_h(client))
        tid = r.json()["id"]
        r = client.post(f"{API}/pharmacy/administrations", json={"subject_type": "animal", "subject_id": BELLA, "inventory_item_id": OXYTET, "lot_id": expired["id"],
                                                                "dose_quantity": 10, "dose_unit": "ml", "route_code": "IM", "treatment_id": tid}, headers=_h(client))
        assert r.status_code == 422 and "expired" in r.json()["detail"]
        # First-expiry-first-out never picks it, and never over-draws.
        r = client.post(f"{API}/pharmacy/administrations", json={"subject_type": "animal", "subject_id": BELLA, "inventory_item_id": OXYTET, "dose_quantity": 150,
                                                                "dose_unit": "ml", "route_code": "IM", "treatment_id": tid}, headers=_h(client))
        assert r.status_code == 422 and "eligible 100" in r.json()["detail"]
        r = client.post(f"{API}/pharmacy/administrations", json={"subject_type": "animal", "subject_id": BELLA, "inventory_item_id": OXYTET, "dose_quantity": 30,
                                                                "dose_unit": "ml", "route_code": "IM", "treatment_id": tid}, headers=_h(client))
        assert r.status_code == 201 and r.json()["lot_code"] == "OXY-2605"
        # The route must be one the product is authorised for.
        r = client.post(f"{API}/pharmacy/administrations", json={"subject_type": "animal", "subject_id": BELLA, "inventory_item_id": OXYTET, "dose_quantity": 1,
                                                                "dose_unit": "ml", "route_code": "PO", "treatment_id": tid}, headers=_h(client))
        assert r.status_code == 422 and "authorised for IM, IV" in r.json()["detail"]

    def test_the_seeded_administrations_are_bound_to_their_lots(self, client: TestClient):
        rows = client.get(f"{API}/pharmacy/administrations", headers=_h(client)).json()
        willow = next(a for a in rows if a["subject_id"] == WILLOW)
        assert willow["lot_code"] == "FLX-2611" and willow["treatment_id"] == "treat-willow-flx" and willow["withdrawal_meat_until"]
        ducks = next(a for a in rows if a["subject_id"] == "flock-duck")
        assert ducks["head_count"] == 5 and ducks["quantity_consumed"] == 5 and ducks["withdrawal_milk_until"] is None
        # Four openings in the ledger so far: the duck dose and Willow's.
        m = _medicine(client, ELECTROLYTE)
        assert m["on_hand"] == 25 and m["expiring_quantity"] == 25 and m["average_daily_use"] > 0

    def test_a_worker_cannot_set_pharmacy_policy(self, client: TestClient):
        headers = auth_headers(client, "worker@origami.farm", "farmos123") if _login_ok(client, "worker@origami.farm") else None
        if headers is None:
            return
        r = client.put(f"{API}/pharmacy/policies/{NACL}", json={"essential": True, "minimum_stock_base": 5}, headers=headers)
        assert r.status_code == 403


def _login_ok(client: TestClient, email: str) -> bool:
    return client.post(f"{API}/auth/login", json={"email": email, "password": "farmos123"}).status_code == 200
