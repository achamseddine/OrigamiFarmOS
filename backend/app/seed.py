"""Seeds the Origami Farms Option C demo dataset.

Mirrors `mobile/flutter_app/lib/data/demo/demo_data.dart` so the tablet
mock-data narrative and the backend's *computed* state agree, and adds
enough small history (milk/feed/egg/treatment/observation rows) that the
rule engine in app/recommendations/engine.py fires for real from that
history rather than from hand-authored recommendation rows — see
app/services/recommendation_service.py.

Usage:
    python -m app.seed            # seed into DATABASE_URL (creates tables first)
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy.orm import Session

from app.core.security import hash_password
from app.db.base import Base, SessionLocal, engine
from app.domain import models
from app.domain import mouneh_models  # noqa: F401 - ensures Mouneh tables are registered on Base.metadata
from app.mouneh.seed import seed_mouneh_demo_data
from app.repositories.base import new_id

FARM_ID = "farm-origami"


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _days_ago(n: int, hour: int = 8) -> datetime:
    base = _now().replace(hour=hour, minute=0, second=0, microsecond=0)
    return base - timedelta(days=n)


def _in_hours(h: float) -> datetime:
    return _now() + timedelta(hours=h)


def seed_demo_data(db: Session) -> None:
    if db.get(models.Farm, FARM_ID) is not None:
        print("Demo data already present — skipping (delete the DB file to reseed).")
        return

    farm = models.Farm(id=FARM_ID, name="Origami Farms", country="Lebanon", region="Bekaa Valley", timezone="Asia/Beirut", default_currency="USD")
    db.add(farm)

    users = [
        ("user-rami", "Rami Farah", "rami@origami.farm", "manager"),
        ("user-owner", "Joseph Origami", "owner@origami.farm", "owner"),
        ("user-vet-1", "Dr. Layla Haddad", "layla.vet@origami.farm", "veterinarian"),
        ("user-worker-1", "Karim Youssef", "karim.worker@origami.farm", "worker"),
        ("user-acct-1", "Nadine Saab", "nadine.acct@origami.farm", "accountant"),
    ]
    for user_id, name, email, role in users:
        db.add(models.User(id=user_id, farm_id=FARM_ID, name=name, email=email, password_hash=hash_password("farmos123"), role=role, language="en"))

    suppliers = {
        "Al Mashreq": new_id(),
        "Bekaa Hay Co.": new_id(),
        "Farm Harvest": new_id(),
        "Green Feed Co.": new_id(),
        "NutriPlus": new_id(),
        "VetCare": new_id(),
    }
    for name, sid in suppliers.items():
        db.add(models.Supplier(id=sid, farm_id=FARM_ID, name=name))

    customers = {"Beirut Fresh Market": new_id(), "Bekaa Co-op": new_id()}
    for name, cid in customers.items():
        db.add(models.Customer(id=cid, farm_id=FARM_ID, name=name))

    # ---------------------------------------------------------------- Animals
    animals = [
        dict(id="cow-744", tag="744", name="Bella", species="cow", breed="Holstein Friesian", sex="F",
             birth_years=4, status="under_treatment", location_label="North Pasture — Group A", health_score=87,
             pregnant=True, pregnancy_days=120, lactating=True, lactation_cycle=2, group_name="Dairy Herd"),
        dict(id="cow-214", tag="214", name="Luna", species="cow", breed="Holstein Friesian", sex="F",
             birth_years=5, status="healthy", location_label="North Pasture", health_score=92,
             lactating=True, group_name="Dairy Herd"),
        dict(id="goat-189", tag="189", name="Rasha", species="goat", breed="Baladi", sex="F",
             birth_years=3, status="under_treatment", location_label="North Pasture", health_score=58, group_name="Dairy Herd"),
        dict(id="goat-g032", tag="G-032", name="Mira", species="goat", breed="Damascus", sex="F",
             birth_years=2, status="under_observation", location_label="Hillside Paddock", health_score=76, group_name="Goat Group B"),
        dict(id="sheep-s045", tag="S-045", name="Daisy", species="sheep", breed="Awassi", sex="F",
             birth_years=2, status="healthy", location_label="Meadow Field", health_score=88, weight_kg=62, group_name="Sheep Group A"),
        dict(id="horse-h07", tag="H-07", name="Thunder", species="horse", breed="Arabian", sex="M",
             birth_years=6, status="healthy", location_label="Stables", health_score=90, weight_kg=480),
        dict(id="hen-247", tag="L-247", name="Hen 247", species="layer_hen", breed="Lohmann Brown", sex="F",
             birth_years=0, status="healthy", location_label="Poultry House 1", health_score=83, group_name="Layer Flock"),
        dict(id="hen-183", tag="L-183", name="Hen 183", species="layer_hen", breed="Lohmann Brown", sex="F",
             birth_years=0, status="under_treatment", location_label="Poultry House 1", health_score=45, group_name="Layer Flock"),
        dict(id="duck-012", tag="D-012", name="Duck 12", species="duck", breed="Pekin", sex="F",
             birth_years=0, status="under_observation", location_label="Pond Area", health_score=78, weight_kg=2.1, group_name="Duck Flock"),
        dict(id="goat-willow", tag="S-118", name="Willow", species="goat", breed="Saanen", sex="F",
             birth_years=3, status="under_treatment", location_label="Hillside Paddock", health_score=64,
             lactating=True, withdrawal_days=2, withdrawal_reason="Medication", group_name="Goat Group B"),
        dict(id="cow-clover", tag="381", name="Clover", species="cow", breed="Holstein", sex="F",
             birth_years=3, status="healthy", location_label="North Pasture", health_score=91, lactating=True, group_name="Dairy Herd"),
        dict(id="goat-gigi", tag="G-091", name="Gigi", species="goat", breed="Saanen", sex="F",
             birth_years=2, status="healthy", location_label="Hillside Paddock", health_score=89, lactating=True, group_name="Goat Group B"),
    ]
    for a in animals:
        db.add(models.Animal(
            id=a["id"], farm_id=FARM_ID, tag=a["tag"], name=a["name"], species=a["species"], breed=a["breed"], sex=a["sex"],
            birth_date=_now() - timedelta(days=365 * a["birth_years"] + 40), status=a["status"],
            location_label=a["location_label"], health_score=a["health_score"], pregnant=a.get("pregnant", False),
            pregnancy_days=a.get("pregnancy_days"), lactating=a.get("lactating", False), lactation_cycle=a.get("lactation_cycle"),
            withdrawal_until=_in_hours(a["withdrawal_days"] * 24) if a.get("withdrawal_days") else None,
            withdrawal_reason=a.get("withdrawal_reason"), weight_kg=a.get("weight_kg"), group_name=a.get("group_name"),
        ))

    # Bella's milk trend: declining over the last 8 sessions (triggers RULE-HEALTH-RISK).
    bella_milk = [23, 22.5, 22, 21.5, 21, 20.5, 20, 18.6]
    for i, liters in enumerate(reversed(bella_milk)):
        db.add(models.MilkRecord(id=new_id(), animal_id="cow-744", session="morning", liters=liters,
                                  destination="stored", recorded_at=_days_ago(i, hour=7), recorded_by="user-worker-1"))
    # Bella's supplemental feed trend: also declining.
    bella_feed = [18, 17.5, 17, 17.2, 16.8, 16.5, 16, 14.2]
    for i, qty in enumerate(reversed(bella_feed)):
        db.add(models.InventoryTransaction(id=new_id(), item_id="feed-dairy-mix", direction="out", quantity=qty,
                                            reason="daily_feeding", linked_entity_type="animal", linked_entity_id="cow-744",
                                            created_at=_days_ago(i, hour=6)))
    db.add(models.Observation(id=new_id(), farm_id=FARM_ID, entity_type="animal", entity_id="cow-744",
                               observation_type="fever", quality="human_observed", severity="severe",
                               observed_at=_days_ago(0, hour=6), observer_id="user-worker-1",
                               notes="Cow reluctant to be milked, udder appears swollen."))
    for i in range(2):
        db.add(models.Treatment(id=new_id(), entity_type="animal", entity_id="cow-744", diagnosis="Mastitis",
                                 medication="Intramammary antibiotic", dose="1 tube", route="Intramammary",
                                 start_at=_days_ago(30 + i * 30), end_at=_days_ago(27 + i * 30), status="resolved",
                                 responsible_user_id="user-vet-1"))

    # Steady/healthy milk history for Luna and Clover so they do NOT trigger the rule.
    for animal_id, base in [("cow-214", 32.0), ("cow-clover", 23.5)]:
        for i in range(8):
            db.add(models.MilkRecord(id=new_id(), animal_id=animal_id, session="morning", liters=base + (i % 3) * 0.3,
                                      destination="stored", recorded_at=_days_ago(i, hour=7), recorded_by="user-worker-1"))

    # -------------------------------------------------------------- Flocks
    flocks = [
        ("flock-layer", "Layer Flock", "layer_hen", 2450, "Poultry House 1-3"),
        ("flock-duck", "Duck Flock", "duck", 680, "Pond Area"),
        ("flock-turkey", "Turkey Flock", "turkey", 120, "Barn C"),
    ]
    for fid, name, species, count, loc in flocks:
        db.add(models.Flock(id=fid, farm_id=FARM_ID, name=name, species=species, count=count, status="healthy", location_label=loc))

    # Duck flock egg drop (-22%, triggers RULE-EGG-DROP); layer/turkey stay stable.
    db.add(models.EggRecord(id=new_id(), flock_id="flock-duck", total_eggs=1446, sellable_eggs=1300, broken_eggs=60,
                             consumed=40, hatched=30, wasted=16, recorded_at=_days_ago(7)))
    db.add(models.EggRecord(id=new_id(), flock_id="flock-duck", total_eggs=1128, sellable_eggs=1000, broken_eggs=50,
                             consumed=40, hatched=30, wasted=8, recorded_at=_days_ago(0)))
    db.add(models.EggRecord(id=new_id(), flock_id="flock-layer", total_eggs=4100, sellable_eggs=3700, broken_eggs=180,
                             consumed=120, hatched=60, wasted=40, recorded_at=_days_ago(7)))
    db.add(models.EggRecord(id=new_id(), flock_id="flock-layer", total_eggs=4212, sellable_eggs=3800, broken_eggs=180,
                             consumed=120, hatched=60, wasted=52, recorded_at=_days_ago(0)))
    db.add(models.EggRecord(id=new_id(), flock_id="flock-turkey", total_eggs=487, sellable_eggs=460, broken_eggs=15,
                             consumed=8, hatched=2, wasted=2, recorded_at=_days_ago(7)))
    db.add(models.EggRecord(id=new_id(), flock_id="flock-turkey", total_eggs=502, sellable_eggs=470, broken_eggs=18,
                             consumed=8, hatched=4, wasted=2, recorded_at=_days_ago(0)))

    # -------------------------------------------------------------- Fields
    fields = [
        ("field-2", "Field 2 — Tomatoes", "Tomatoes", "ripening", 420, _in_hours(20)),
        ("field-3", "Field 3 — Zucchini", "Zucchini", "flowering", 310, _in_hours(24 * 3)),
        ("field-4", "Field 4 — Cucumbers", "Cucumbers", "growing", 280, _in_hours(24 * 5)),
        ("field-herb", "Herb Garden — Basil", "Basil", "mature", 65, _in_hours(2)),
        ("field-orchard", "Orchard — Oranges", "Oranges", "developing", 1200, _in_hours(24 * 28)),
    ]
    for fid, name, crop, stage, yield_kg, harvest_date in fields:
        db.add(models.Field(id=fid, farm_id=FARM_ID, name=name, crop_type=crop, stage=stage,
                             est_yield_kg=yield_kg, expected_harvest_date=harvest_date))

    # --------------------------------------------------------- Inventory
    items = [
        ("feed-dairy-mix", "Dairy Mix", "Dairy", "kg", 3250, 2000, "Al Mashreq", 0.42),
        ("feed-alfalfa", "Alfalfa Hay", "Dairy", "kg", 4800, 3000, "Bekaa Hay Co.", 0.31),
        ("feed-corn-silage", "Corn Silage", "Dairy", "kg", 2200, 2500, "Farm Harvest", 0.18),
        ("feed-layer", "Layer Feed", "Poultry", "kg", 1150, 1500, "Al Mashreq", 0.39),
        ("feed-goat-mix", "Goat Mix", "Goats", "kg", 900, 800, "Green Feed Co.", 0.44),
        ("feed-minerals", "Minerals", "Minerals", "kg", 320, 300, "NutriPlus", 1.10),
        ("feed-medicine", "Medicine", "Medicine", "items", 14, 10, "VetCare", 12.5),
    ]
    for iid, name, category, unit, qty, reorder, supplier, cost in items:
        db.add(models.InventoryItem(id=iid, farm_id=FARM_ID, name=name, category=category, unit=unit,
                                     current_qty=qty, reorder_level=reorder, supplier_label=supplier, unit_cost=cost,
                                     last_purchase=_days_ago(20)))
    # 7 days of usage history for the two low-stock items so days_remaining is computable.
    for item_id, daily in [("feed-corn-silage", 90), ("feed-layer", 55)]:
        for i in range(7):
            db.add(models.InventoryTransaction(id=new_id(), item_id=item_id, direction="out", quantity=daily,
                                                reason="daily_feeding", created_at=_days_ago(i, hour=6)))

    # ------------------------------------------------------------- Tasks
    tasks = [
        ("task-1", "Inspect Cow 744", "Health check", _in_hours(1), "high"),
        ("task-2", "Reorder dairy mix", "Low stock alert", _in_hours(3), "medium"),
        ("task-3", "Collect duck eggs", "Main house", _in_hours(4), "medium"),
        ("task-4", "Harvest tomatoes in Field 2", "Estimated 80 kg", _in_hours(9), "medium"),
    ]
    for tid, title, category, due, priority in tasks:
        db.add(models.Task(id=tid, farm_id=FARM_ID, title=title, description=category, due_at=due, priority=priority, status="open"))

    # ----------------------------------------------------- Sales & expenses
    sales = [
        ("milk", "Milk", 340, "L", 4250, "paid"),
        ("eggs", "Eggs", 285, "dozen", 2380, "paid"),
        ("produce", "Produce", 260, "kg", 3120, "pending"),
        ("animals", "Animals", 1, "head", 2150, "paid"),
        ("farm_products", "Farm Products", 40, "units", 945, "partial"),
    ]
    for product_type, label, qty, unit, amount, payment_status in sales:
        db.add(models.Sale(id=new_id(), farm_id=FARM_ID, product_type=product_type, product_label=label,
                            quantity=qty, unit=unit, amount=amount, payment_status=payment_status, sold_at=_days_ago(0, hour=9)))

    expenses = [("feed", 1680), ("medicine", 720), ("labor", 1150), ("fuel", 420), ("other", 260)]
    for category, amount in expenses:
        db.add(models.Expense(id=new_id(), farm_id=FARM_ID, category=category, amount=amount, incurred_at=_days_ago(0, hour=8)))

    db.flush()
    seed_mouneh_demo_data(db, FARM_ID)

    db.commit()
    print(f"Seeded demo data for farm '{FARM_ID}'. Demo login: rami@origami.farm / farmos123")


if __name__ == "__main__":
    Base.metadata.create_all(bind=engine)
    with SessionLocal() as session:
        seed_demo_data(session)
