"""Demo pharmacy for the Origami farm (database/MEDICINE-PHARMACY-SCHEMA.md).

Six stocked medicines with lots and expiries, the manager's essential-
stock policy, one prescribed administration bound to its lot, one flock
dose, and the first scan — so the demo opens on a pharmacy that is below
minimum on IV fluids, holds an expired antibiotic lot, has electrolytes
expiring soon and a vaccine lot under a cold-chain exception. None of
that advises treating anyone; it says what the shelf holds.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy.orm import Session

from app.domain import models
from app.domain import pharmacy_models as pm
from app.repositories.base import new_id
from app.services import pharmacy_service as ph

MANAGER = "user-rami"
VET = "user-vet-1"


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _days(n: int, hour: int = 9) -> datetime:
    return _now().replace(hour=hour, minute=0, second=0, microsecond=0) + timedelta(days=n)


def seed_pharmacy_demo_data(db: Session, farm_id: str) -> None:
    if db.get(pm.MedicineProduct, "med-oxytet") is not None:
        return
    ph.ensure_pharmacy_reference_data(db)

    def product(item_id: str, name: str, unit: str, *, supplier: str, unit_cost: float, **fields) -> pm.MedicineProduct:
        item = models.InventoryItem(id=item_id, farm_id=farm_id, name=name, category="medicine", unit=unit, current_qty=0, reorder_level=0,
                                    supplier_label=supplier, unit_cost=unit_cost)
        db.add(item)
        db.flush()
        return ph.create_product(db, farm_id, inventory_item_id=item_id, user_id=MANAGER, **fields)

    oxytet = product("med-oxytet", "Oxytetracycline 200 mg/mL injectable", "ml", supplier="VetCare", unit_cost=0.18,
                     generic_name="Oxytetracycline", brand_name="Oxytet 200 LA", dosage_form="injectable", strength_value=200, strength_uom="mg/ml",
                     administration_routes=["IM", "IV"], prescription_required=True, antimicrobial=True, opened_shelf_life_days=28, default_pack_size=100, pack_uom="ml",
                     manufacturer_name="VetCare Labs", species_codes=["cow", "goat", "sheep"], withdrawal_rules={"milk_days": 4, "meat_days": 28},
                     category_codes=["ANTIBIOTIC"], ingredients=[{"code": "oxytetracycline", "concentration_value": 200, "concentration_uom": "mg/ml"}])
    flunixin = product("med-flunixin", "Flunixin meglumine 50 mg/mL injectable", "ml", supplier="VetCare", unit_cost=0.32,
                       generic_name="Flunixin meglumine", brand_name="Finadyne", dosage_form="injectable", strength_value=50, strength_uom="mg/ml",
                       administration_routes=["IM", "IV"], prescription_required=True, opened_shelf_life_days=28, default_pack_size=50, pack_uom="ml",
                       manufacturer_name="VetCare Labs", species_codes=["cow", "horse", "goat", "sheep"], withdrawal_rules={"milk_days": 1, "meat_days": 10},
                       category_codes=["PAIN_INFLAMMATION", "FEVER_SUPPORT"], ingredients=[{"code": "flunixin_meglumine", "concentration_value": 50, "concentration_uom": "mg/ml"}])
    nacl = product("med-nacl", "Sodium chloride 0.9% IV fluid 1 L", "bag", supplier="MedSupply Beirut", unit_cost=2.4,
                   generic_name="Sodium chloride 0.9%", dosage_form="intravenous_fluid", strength_value=0.9, strength_uom="%", administration_routes=["IV"],
                   default_pack_size=1, pack_uom="bag", manufacturer_name="Pharmaline", withdrawal_rules={}, category_codes=["IV_FLUID"],
                   ingredients=[{"code": "sodium_chloride", "concentration_value": 0.9, "concentration_uom": "%"}])
    electrolyte = product("med-electrolyte", "Oral electrolyte sachet", "sachet", supplier="MedSupply Beirut", unit_cost=0.9,
                          generic_name="Glucose / electrolyte", dosage_form="oral", administration_routes=["PO"], default_pack_size=20, pack_uom="sachet",
                          withdrawal_rules={}, category_codes=["ELECTROLYTE"], ingredients=[{"code": "glucose_electrolyte"}])
    ivermectin = product("med-ivermectin", "Ivermectin pour-on 5 mg/mL", "ml", supplier="VetCare", unit_cost=0.12,
                         generic_name="Ivermectin", dosage_form="pour_on", strength_value=5, strength_uom="mg/ml", administration_routes=["pour_on"],
                         default_pack_size=250, pack_uom="ml", species_codes=["cow", "sheep", "goat"], withdrawal_rules={"meat_days": 35},
                         category_codes=["ANTIPARASITIC"], ingredients=[{"code": "ivermectin", "concentration_value": 5, "concentration_uom": "mg/ml"}])
    vaccine = product("med-vaccine", "Clostridial vaccine (8-way)", "dose", supplier="VetCare", unit_cost=1.1,
                      generic_name="Clostridial toxoid", dosage_form="vaccine", administration_routes=["SC"], cold_chain_required=True, storage_min_c=2, storage_max_c=8,
                      default_pack_size=20, pack_uom="dose", species_codes=["cow", "sheep", "goat"], withdrawal_rules={"meat_days": 21},
                      category_codes=["VACCINE"], ingredients=[{"code": "clostridial_toxoid"}])

    # ------------------------------------------------------------- lots
    ph.receive_lot(db, oxytet, quantity=100, lot_code="OXY-2605", expiry_date=_days(240), unit_cost=0.18, supplier_label="VetCare", received_at=_days(-20), user_id=MANAGER)
    ph.receive_lot(db, oxytet, quantity=60, lot_code="OXY-2602", expiry_date=_days(-10), unit_cost=0.18, supplier_label="VetCare", received_at=_days(-200),
                   notes="Older stock — expired on the shelf", user_id=MANAGER)
    ph.receive_lot(db, flunixin, quantity=50, lot_code="FLX-2611", expiry_date=_days(120), unit_cost=0.32, supplier_label="VetCare", received_at=_days(-15), user_id=MANAGER)
    ph.receive_lot(db, nacl, quantity=8, lot_code="NACL-2607", expiry_date=_days(300), unit_cost=2.4, supplier_label="MedSupply Beirut", received_at=_days(-30), user_id=MANAGER)
    ph.receive_lot(db, electrolyte, quantity=30, lot_code="ELC-2609", expiry_date=_days(45), unit_cost=0.9, supplier_label="MedSupply Beirut", received_at=_days(-60), user_id=MANAGER)
    ph.receive_lot(db, ivermectin, quantity=250, lot_code="IVM-2603", expiry_date=_days(400), unit_cost=0.12, supplier_label="VetCare", received_at=_days(-40), user_id=MANAGER)
    ph.receive_lot(db, vaccine, quantity=40, lot_code="VAC-2608", expiry_date=_days(200), unit_cost=1.1, supplier_label="VetCare", received_at=_days(-3),
                   storage_status="EXCEPTION", cold_chain_exception=True, notes="Fridge off for 6 h on delivery day — held until the vet clears it", user_id=MANAGER)

    # --------------------------------------------------------- policies
    # The manager's own essential list (§5): thresholds, not medical advice.
    ph.upsert_policy(db, nacl, essential=True, minimum_stock_base=12, critical_stock_base=4, target_stock_base=24, lead_time_days=3, expiry_warning_days=60, user_id=MANAGER)
    ph.upsert_policy(db, oxytet, essential=True, minimum_stock_base=100, critical_stock_base=40, target_stock_base=300, lead_time_days=5, user_id=MANAGER)
    ph.upsert_policy(db, flunixin, essential=True, minimum_stock_base=40, critical_stock_base=15, target_stock_base=150, lead_time_days=5, user_id=MANAGER)
    ph.upsert_policy(db, electrolyte, essential=True, minimum_stock_base=10, critical_stock_base=4, target_stock_base=40, lead_time_days=3, user_id=MANAGER)
    ph.upsert_policy(db, vaccine, essential=True, minimum_stock_base=20, critical_stock_base=5, target_stock_base=60, lead_time_days=10, user_id=MANAGER)

    # --------------------------------------------------- administrations
    # Willow (goat, under withdrawal already): a prescribed anti-inflammatory
    # dose bound to its lot, with the product's authorised withdrawal.
    treatment = models.Treatment(
        id="treat-willow-flx", entity_type="animal", entity_id="goat-willow", diagnosis="Fever 40.5 °C, off feed", medication="Flunixin meglumine 50 mg/mL",
        dose="1.1 mg/kg IM once", route="IM", start_at=_days(-1, 8), responsible_user_id=VET, vet_id=VET, status="active",
    )
    db.add(treatment)
    db.flush()
    ph.administer(db, farm_id, subject_type="animal", subject_id="goat-willow", inventory_item_id=flunixin.inventory_item_id, dose_quantity=1.5, dose_unit="ml",
                  route_code="IM", treatment_id=treatment.id, administered_at=_days(-1, 8), reason="Fever 40.5 °C", user_id=VET)
    # The duck flock: oral electrolytes to five birds — no prescription, no withdrawal.
    ph.administer(db, farm_id, subject_type="group", subject_id="flock-duck", inventory_item_id=electrolyte.inventory_item_id, dose_quantity=1, dose_unit="sachet",
                  route_code="PO", head_count=5, administered_at=_days(-2, 10), reason="Heat stress", user_id="user-worker-1")

    db.flush()
    ph.evaluate_farm(db, farm_id, user_id=MANAGER)
    db.flush()
    assert new_id  # keeps the import explicit for seeds that add ids by hand later
