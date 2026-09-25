"""Demo data for the generic feed architecture.

Built the way a farm manager would build it through the API — products,
a receipt, a policy, a formula with two versions, a completed batch, a
handful of programs with rules, group and individual assignments, a week
of feeding events, a reservation, a reorder policy and an open
reconciliation — with direct service calls instead of HTTP. Nothing in
the feed module knows these names; swap "Dairy Mix 24L" for "Camel
Ration" and every screen still works.

Deterministic ids (`fp-…`, `prog-…`, `formula-…`) so tests can name them.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import feed_models as fm
from app.domain import models
from app.feeding.catalog import ensure_feed_reference_data
from app.services import feed_batch_service as batches
from app.services import feed_forecast_service as forecast
from app.services import feed_inventory_service as inv
from app.services import feed_policy_service as policy
from app.services import feeding_program_service as programs

SEED_USER = "user-manager-1"


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _days_ago(n: int, hour: int = 6) -> datetime:
    return _now().replace(hour=hour, minute=0, second=0, microsecond=0) - timedelta(days=n)


def _product_from_item(db: Session, farm_id: str, product_id: str, item_id: str, *, code: str, source_type: str, is_ingredient: bool, is_feedable: bool, category: str) -> fm.FeedProduct:
    item = db.get(models.InventoryItem, item_id)
    product = fm.FeedProduct(
        id=product_id, farm_id=farm_id, code=code, name=item.name, source_type=source_type, is_ingredient=is_ingredient,
        is_feedable=is_feedable, category=category, unit=item.unit, inventory_item_id=item.id, default_unit_cost=item.unit_cost,
        status="active", created_at=_now(),
    )
    db.add(product)
    db.flush()
    return product


def _new_product(db: Session, farm_id: str, product_id: str, item_id: str, *, code: str, name: str, name_ar: str, category: str,
                 source_type: str, is_ingredient: bool, is_feedable: bool, unit_cost: float, supplier: str, reorder_level: float) -> fm.FeedProduct:
    item = models.InventoryItem(id=item_id, farm_id=farm_id, name=name, category=category.capitalize(), unit="kg", current_qty=0,
                                reorder_level=reorder_level, supplier_label=supplier, unit_cost=unit_cost, last_purchase=_days_ago(12))
    db.add(item)
    db.flush()
    product = fm.FeedProduct(id=product_id, farm_id=farm_id, code=code, name=name, name_ar=name_ar, source_type=source_type,
                             is_ingredient=is_ingredient, is_feedable=is_feedable, category=category, unit="kg", inventory_item_id=item.id,
                             default_unit_cost=unit_cost, status="active", created_at=_now())
    db.add(product)
    db.flush()
    return product


def _pin_opening_balance(db: Session, product: fm.FeedProduct, target_qty: float) -> None:
    """The seed consumes stock through real batches and feedings; the
    opening balance is then set so the item ends on the figure the rest of
    the demo (and the tests) expect. Opening balances are exogenous — they
    carry no transaction — so this keeps the ledger consistent."""
    item = db.get(models.InventoryItem, product.inventory_item_id)
    opening = next((l for l in product.lots if l.source_type == "opening_balance"), None)
    if opening is None:
        return
    diff = target_qty - (item.current_qty or 0)
    if abs(diff) < 0.0005:
        return
    opening.quantity_on_hand += diff
    opening.received_quantity += diff
    opening.accepted_quantity += diff
    item.current_qty = target_qty
    inv.refresh_lot_status(opening)


def seed_feed_demo_data(db: Session, farm_id: str) -> None:
    if db.get(fm.FeedProduct, "fp-dairy-mix") is not None:
        return
    ensure_feed_reference_data(db)
    u = SEED_USER

    # ------------------------------------------------------------ products
    # Existing inventory items become feed products (their stock becomes an
    # opening-balance lot); the mix and a few ingredients are new.
    targets: dict[str, float] = {}
    for item in db.scalars(select(models.InventoryItem).where(models.InventoryItem.farm_id == farm_id)):
        targets[item.id] = item.current_qty or 0
    dairy_mix = _product_from_item(db, farm_id, "fp-dairy-mix", "feed-dairy-mix", code="DAIRY-MIX-24L", source_type="farm_produced", is_ingredient=False, is_feedable=True, category="complete_feed")
    dairy_mix.name, dairy_mix.name_ar = "Dairy Mix 24L", "خلطة الحليب ٢٤ ل"
    db.get(models.InventoryItem, "feed-dairy-mix").name = "Dairy Mix 24L"
    alfalfa = _product_from_item(db, farm_id, "fp-alfalfa", "feed-alfalfa", code="ALFALFA-HAY", source_type="purchased", is_ingredient=True, is_feedable=True, category="forage")
    silage = _product_from_item(db, farm_id, "fp-corn-silage", "feed-corn-silage", code="CORN-SILAGE", source_type="farm_produced", is_ingredient=True, is_feedable=True, category="forage")
    layer = _product_from_item(db, farm_id, "fp-layer-feed", "feed-layer", code="LAYER-FEED", source_type="purchased", is_ingredient=False, is_feedable=True, category="complete_feed")
    goat = _product_from_item(db, farm_id, "fp-goat-mix", "feed-goat-mix", code="GOAT-MIX", source_type="purchased", is_ingredient=False, is_feedable=True, category="complete_feed")
    minerals = _product_from_item(db, farm_id, "fp-minerals", "feed-minerals", code="MINERAL-MIX", source_type="purchased", is_ingredient=True, is_feedable=True, category="mineral")
    for p in (dairy_mix, alfalfa, silage, layer, goat, minerals):
        inv.reconcile_opening_balance(db, p, db.get(models.InventoryItem, p.inventory_item_id), created_by=u)

    barley = _new_product(db, farm_id, "fp-barley", "feed-barley", code="BARLEY", name="Barley", name_ar="شعير", category="concentrate",
                          source_type="purchased", is_ingredient=True, is_feedable=True, unit_cost=0.36, supplier="Bekaa Hay Co.", reorder_level=400)
    concentrate = _new_product(db, farm_id, "fp-dairy-concentrate", "feed-dairy-concentrate", code="DAIRY-CONC-18", name="Dairy Concentrate 18",
                               name_ar="مركّز حليب ١٨٪", category="concentrate", source_type="purchased", is_ingredient=True, is_feedable=True,
                               unit_cost=0.52, supplier="Al Mashreq", reorder_level=800)
    premix = _new_product(db, farm_id, "fp-dairy-premix", "feed-dairy-premix", code="CATTLE-DAIRY-PREMIX", name="Cattle Dairy Premix",
                          name_ar="بريمكس أبقار حليب", category="premix", source_type="purchased", is_ingredient=True, is_feedable=False,
                          unit_cost=2.40, supplier="NutriPlus", reorder_level=100)
    broiler = _new_product(db, farm_id, "fp-broiler-grower", "feed-broiler-grower", code="BROILER-GROWER", name="Broiler Grower",
                           name_ar="علف تسمين", category="complete_feed", source_type="purchased", is_ingredient=False, is_feedable=True,
                           unit_cost=0.47, supplier="Al Mashreq", reorder_level=300)
    targets.update({"feed-barley": 1200, "feed-dairy-concentrate": 2000, "feed-dairy-premix": 500, "feed-broiler-grower": 800})
    inv.receive(db, barley, quantity=1200, unit_cost=0.36, supplier_label="Bekaa Hay Co.", lot_code="BAR-2609-01", received_at=_days_ago(12), user_id=u)
    inv.receive(db, concentrate, quantity=2000, unit_cost=0.52, supplier_label="Al Mashreq", lot_code="DC18-2609-07", received_at=_days_ago(9),
                expiry_date=_now() + timedelta(days=120), reference="INV-4471", user_id=u)
    premix_lot = inv.receive(db, premix, quantity=500, unit_cost=2.40, supplier_label="NutriPlus", lot_code="PMX-2609-03", received_at=_days_ago(11),
                             expiry_date=_now() + timedelta(days=300), ordered_quantity=500, reference="PO-1180", user_id=u)
    inv.receive(db, broiler, quantity=800, unit_cost=0.47, supplier_label="Al Mashreq", lot_code="BRG-2609-02", received_at=_days_ago(6), user_id=u)

    # -------------------------------------------------------------- policy
    # §24: the premix is for dairy cattle, through an approved formula,
    # never transferred to another species. Horses and small ruminants are
    # blocked explicitly so the refusal names them.
    policy.set_policy(
        db, premix, name="Cattle dairy premix — dairy cattle only", requires_approved_formula=True, cross_species_transfer_allowed=False,
        rules=[
            {"effect": "allow", "species_code": "cow", "management_profile": "dairy"},
            {"effect": "allow", "species_code": "cow", "management_profile": "dual_purpose"},
            {"effect": "block", "species_code": "horse", "reason": "monensin-type additives are toxic to equines"},
            {"effect": "block", "species_code": "sheep", "reason": "copper level unsafe for sheep"},
            {"effect": "block", "species_code": "goat"},
            {"effect": "limit", "max_inclusion_pct": 1.5},
        ],
        notes="Manufacturer's label restriction.", user_id=u,
    )
    policy.set_policy(db, minerals, name="Mineral mix inclusion cap", rules=[{"effect": "limit", "max_inclusion_pct": 3.0}], user_id=u)

    # ----------------------------------------------------------- nutrients
    declared = {
        silage: [("DM", 33), ("CP", 8.2), ("ME", 10.8), ("NDF", 45), ("ADF", 26)],
        alfalfa: [("DM", 88), ("CP", 17), ("ME", 8.6), ("NDF", 42), ("CA", 1.3)],
        barley: [("DM", 89), ("CP", 11.5), ("ME", 12.8), ("NDF", 19), ("FAT", 2.1)],
        concentrate: [("DM", 88), ("CP", 18), ("ME", 12.2), ("FAT", 4.0), ("CA", 0.9), ("P", 0.6)],
        premix: [("DM", 96), ("CA", 18), ("P", 6), ("MG", 4), ("VIT_A", 400000), ("VIT_D", 80000)],
        layer: [("DM", 89), ("CP", 16.5), ("ME", 11.4), ("CA", 3.8), ("P", 0.45)],
        goat: [("DM", 88), ("CP", 16), ("ME", 11.6)],
        broiler: [("DM", 89), ("CP", 20), ("ME", 12.6)],
    }
    for product, values in declared.items():
        batches.record_profile(db, farm_id, subject_type="feed_product", subject_id=product.id, basis="as_fed", source_type="declared",
                               values=[{"nutrient_code": c, "value": v} for c, v in values], user_id=u)
    batches.record_profile(db, farm_id, subject_type="feed_product", subject_id=alfalfa.id, basis="as_fed", source_type="lab", reference="LAB-2026-0912",
                           effective_at=_days_ago(13), values=[{"nutrient_code": "DM", "value": 87.1}, {"nutrient_code": "CP", "value": 16.2}, {"nutrient_code": "NDF", "value": 43.5}], user_id=u)

    # -------------------------------------------------------------- formula
    # v1 was used by a completed batch and is locked; v2 is what the farm
    # mixes today (§6).
    formula = batches.create_formula(
        db, farm_id, code="DAIRY-MIX-24L", name="Dairy Mix 24L", feed_product_id=dairy_mix.id, species_code="cow",
        description="Total mixed ration for lactating dairy cows at ~24 L/day.", batch_size=1000, unit="kg",
        components=[
            {"feed_product_id": silage.id, "target_quantity": 400}, {"feed_product_id": alfalfa.id, "target_quantity": 200},
            {"feed_product_id": concentrate.id, "target_quantity": 350}, {"feed_product_id": barley.id, "target_quantity": 40},
            {"feed_product_id": premix.id, "target_quantity": 10},
        ],
        activate=True, user_id=u,
    )
    formula.id  # noqa: B018 — keep the reference
    v1 = formula.versions[0]
    batch = batches.start_batch(db, farm_id, formula_version_id=v1.id, formula_id=None, batch_code="MIX-2609-01", target_quantity=1000, unit="kg",
                                notes="Morning mix, mixer wagon 2.", user_id=u)
    batch.started_at = _days_ago(10, hour=5)
    batches.complete_batch(
        db, batch, actual_quantity=1000, produced_at=_days_ago(10, hour=6),
        actuals=[
            {"feed_product_id": silage.id, "actual_quantity": 398}, {"feed_product_id": alfalfa.id, "actual_quantity": 205},
            {"feed_product_id": concentrate.id, "actual_quantity": 347}, {"feed_product_id": barley.id, "actual_quantity": 40},
            {"feed_product_id": premix.id, "actual_quantity": 10, "lot_id": premix_lot.id},
        ],
        user_id=u,
    )
    v2 = batches.add_version(
        db, formula, batch_size=1000, unit="kg", notes="More hay, less silage while the new clamp settles.",
        components=[
            {"feed_product_id": silage.id, "target_quantity": 380}, {"feed_product_id": alfalfa.id, "target_quantity": 220},
            {"feed_product_id": concentrate.id, "target_quantity": 350}, {"feed_product_id": barley.id, "target_quantity": 40},
            {"feed_product_id": premix.id, "target_quantity": 10},
        ],
        activate=True, user_id=u,
    )
    v2.effective_from = _days_ago(3)
    open_batch = batches.start_batch(db, farm_id, formula_version_id=v2.id, formula_id=None, batch_code="MIX-2609-02", target_quantity=800, unit="kg", notes=None, user_id=u)
    open_batch.id  # noqa: B018

    # ------------------------------------------------------------ programs
    def program(pid: str, code: str, name: str, name_ar: str, category: str, components: list[dict], rules: list[dict], feedings: int = 2, description: str | None = None):
        return programs.create_program(db, farm_id, code=code, name=name, name_ar=name_ar, category=category, description=description,
                                       feedings_per_day=feedings, components=components, rules=rules, activate=True, program_id=pid, user_id=u)

    dairy_high = program("prog-dairy-high", "DAIRY-HIGH", "High-production dairy", "حليب إنتاج عالي", "dairy",
                         [{"feed_product_id": dairy_mix.id, "quantity_per_head": 10, "frequency": "per_feeding"},
                          {"feed_product_id": alfalfa.id, "quantity_per_head": 3, "frequency": "per_feeding"},
                          {"feed_product_id": concentrate.id, "quantity_per_head": 3, "frequency": "per_feeding"}],
                         [{"species_code": "cow", "sex": "F", "life_stage": "adult", "management_profile": "dairy", "lactation_state": "lactating",
                           "production_metric": "milk_l_per_day", "production_min": 20, "priority": 10}],
                         description="Lactating cows giving 20 L/day or more.")
    program("prog-dairy-medium", "DAIRY-MEDIUM", "Medium-production dairy", "حليب إنتاج متوسط", "dairy",
            [{"feed_product_id": dairy_mix.id, "quantity_per_head": 8, "frequency": "per_feeding"},
             {"feed_product_id": alfalfa.id, "quantity_per_head": 3, "frequency": "per_feeding"},
             {"feed_product_id": concentrate.id, "quantity_per_head": 2, "frequency": "per_feeding"}],
            [{"species_code": "cow", "sex": "F", "life_stage": "adult", "management_profile": "dairy", "lactation_state": "lactating",
              "production_metric": "milk_l_per_day", "production_min": 10, "production_max": 20, "priority": 10}])
    program("prog-dairy-lactating", "DAIRY-LACTATING", "Lactating dairy (no yield data)", "حليب — بدون بيانات إنتاج", "dairy",
            [{"feed_product_id": dairy_mix.id, "quantity_per_head": 9, "frequency": "per_feeding"},
             {"feed_product_id": alfalfa.id, "quantity_per_head": 3, "frequency": "per_feeding"}],
            [{"species_code": "cow", "sex": "F", "life_stage": "adult", "management_profile": "dairy", "lactation_state": "lactating", "priority": 0}],
            description="Falls back when a lactating cow has no milk records yet.")
    program("prog-dry-cow", "DRY-COW", "Dry cow", "بقرة جافة", "dairy",
            [{"feed_product_id": alfalfa.id, "quantity_per_head": 10}, {"feed_product_id": silage.id, "quantity_per_head": 8},
             {"feed_product_id": minerals.id, "quantity_per_head": 0.1}],
            [{"species_code": "cow", "sex": "F", "life_stage": "adult", "lactation_state": "dry", "priority": 5}])
    program("prog-calf-starter", "CALF-STARTER", "Calf starter", "علف عجول", "growth",
            [{"feed_product_id": concentrate.id, "quantity_per_head": 1.5}, {"feed_product_id": alfalfa.id, "quantity_per_head": 1}],
            [{"species_code": "cow", "life_stage": "young", "priority": 5}])
    program("prog-breeding-bull", "BREEDING-BULL", "Breeding bull maintenance", "ثور تربية", "breeding",
            [{"feed_product_id": alfalfa.id, "quantity_per_head": 12}, {"feed_product_id": barley.id, "quantity_per_head": 2}],
            [{"species_code": "cow", "sex": "M", "life_stage": "adult", "priority": 5}])
    program("prog-goat-dairy", "GOAT-DAIRY", "Lactating dairy goat", "ماعز حلوب", "dairy",
            [{"feed_product_id": goat.id, "quantity_per_head": 1.2}, {"feed_product_id": alfalfa.id, "quantity_per_head": 2}],
            [{"species_code": "goat", "sex": "F", "lactation_state": "lactating", "priority": 5}])
    program("prog-goat-dry", "GOAT-DRY", "Dry goat", "ماعز جاف", "dairy",
            [{"feed_product_id": alfalfa.id, "quantity_per_head": 2.5}],
            [{"species_code": "goat", "sex": "F", "lactation_state": "dry", "priority": 5}])
    program("prog-ewe-gestation", "EWE-GESTATION", "Pregnant ewe", "نعجة حامل", "reproduction",
            [{"feed_product_id": alfalfa.id, "quantity_per_head": 2}, {"feed_product_id": barley.id, "quantity_per_head": 0.4}],
            [{"species_code": "sheep", "sex": "F", "reproductive_state": "pregnant", "priority": 5}])
    program("prog-ewe-lactation", "EWE-LACTATION", "Lactating ewe", "نعجة مرضعة", "dairy",
            [{"feed_product_id": alfalfa.id, "quantity_per_head": 2.5}, {"feed_product_id": barley.id, "quantity_per_head": 0.8}],
            [{"species_code": "sheep", "sex": "F", "lactation_state": "lactating", "priority": 6}])
    program("prog-mare-pregnant", "MARE-PREGNANT", "Pregnant mare", "فرس حامل", "reproduction",
            [{"feed_product_id": alfalfa.id, "quantity_per_head": 10}, {"feed_product_id": barley.id, "quantity_per_head": 2}],
            [{"species_code": "horse", "sex": "F", "reproductive_state": "pregnant", "priority": 6}])
    program("prog-mare-lactating", "MARE-LACTATING", "Lactating mare", "فرس مرضعة", "dairy",
            [{"feed_product_id": alfalfa.id, "quantity_per_head": 12}, {"feed_product_id": barley.id, "quantity_per_head": 3}],
            [{"species_code": "horse", "sex": "F", "lactation_state": "lactating", "priority": 7}])
    program("prog-horse-growth", "HORSE-GROWTH", "Foal / yearling growth", "مهر — نمو", "growth",
            [{"feed_product_id": alfalfa.id, "quantity_per_head": 6}, {"feed_product_id": barley.id, "quantity_per_head": 1.5}],
            [{"species_code": "horse", "life_stage": "young", "priority": 5}])
    program("prog-horse-maintenance", "HORSE-MAINTENANCE", "Horse maintenance", "حصان — صيانة", "maintenance",
            [{"feed_product_id": alfalfa.id, "quantity_per_head": 10}, {"feed_product_id": barley.id, "quantity_per_head": 1}],
            [{"species_code": "horse", "priority": 0}])
    layer_prog = program("prog-layer", "LAYER", "Layer ration", "علف بيّاض", "eggs",
                         [{"feed_product_id": layer.id, "quantity_per_head": 0.12}],
                         [{"species_code": "layer_hen", "management_profile": "layer", "priority": 5},
                          {"species_code": "duck", "management_profile": "layer", "priority": 5},
                          {"species_code": "turkey", "management_profile": "layer", "priority": 5}], feedings=1)
    program("prog-broiler-grower", "BROILER-GROWER", "Broiler grower", "تسمين — نمو", "growth",
            [{"feed_product_id": broiler.id, "quantity_per_head": 0.11}],
            [{"management_profile": "broiler", "priority": 5}], feedings=1)

    # --------------------------------------------------------- assignments
    # The dairy herd is a group; its cows inherit. Bella gets a supplement
    # on top (§9) and the layer flock is on the layer ration.
    cows = db.scalars(select(models.Animal).where(models.Animal.farm_id == farm_id, models.Animal.species == "cow", models.Animal.group_name == "Dairy Herd")).all()
    herd = models.Flock(id="grp-dairy-herd", farm_id=farm_id, name="Dairy Herd", species="cow", group_type="herd", count=len(cows),
                        sex_composition="female", life_stage="adult", management_profile="dairy", status="healthy", location_label="North Pasture")
    db.add(herd)
    db.flush()
    programs.assign(db, farm_id, "group", herd, assignment_type="explicit", program_id=dairy_high.id, reason="Herd average above 20 L/day", user_id=u)
    bella = db.get(models.Animal, "cow-744")
    if bella is not None:
        programs.assign(db, farm_id, "animal", bella, assignment_type="supplement", feed_product_id=concentrate.id, quantity_per_head=2, unit="kg",
                        reason="Vet: recovering, +2 kg concentrate for 10 days", valid_to=_now() + timedelta(days=7), user_id=u)
    layer_flock = db.get(models.Flock, "flock-layer")
    if layer_flock is not None:
        programs.assign(db, farm_id, "group", layer_flock, assignment_type="explicit", program_id=layer_prog.id, user_id=u)
    # Everyone else: whatever the resolver says, assigned explicitly so the
    # daily plan is complete — a manager would do the same from the review.
    for animal in db.scalars(select(models.Animal).where(models.Animal.farm_id == farm_id, models.Animal.active.is_(True))):
        if programs.effective_program(db, "animal", animal)[0] is not None:
            continue
        state = programs.subject_state(db, "animal", animal)
        best = programs.resolve_state(db, state)["best"]
        if best:
            programs.assign(db, farm_id, "animal", animal, assignment_type="explicit", program_version_id=best["version_id"], reason="Seeded from resolver", user_id=u)

    # ---------------------------------------------------------- feedings
    # A week of morning and evening deliveries to the herd and the flock.
    # The opening lots are sized for that week first — the demo's end
    # figures are what the items table says, so the farm must have started
    # the week with that much more.
    herd_plan = programs.effective_plan(db, "group", herd, with_events=False)
    flock_plan = programs.effective_plan(db, "group", layer_flock, with_events=False) if layer_flock is not None else None
    planned: dict[str, float] = {}
    for t in herd_plan["daily_targets"]:
        planned[t["feed_product_id"]] = planned.get(t["feed_product_id"], 0) + t["daily_total"] * 6.5
    if flock_plan is not None:
        for t in flock_plan["daily_targets"]:
            planned[t["feed_product_id"]] = planned.get(t["feed_product_id"], 0) + t["daily_total"] * 7
    planned[concentrate.id] = planned.get(concentrate.id, 0) + 2
    for product in (dairy_mix, alfalfa, silage, layer, goat, minerals):
        if product.id in planned:
            item = db.get(models.InventoryItem, product.inventory_item_id)
            _pin_opening_balance(db, product, (item.current_qty or 0) + planned[product.id] + 1)
    for day in range(6, -1, -1):
        for hour, label in ((6, "morning"), (17, "evening")):
            if day == 0 and hour == 17:
                continue
            programs.record_feeding(
                db, farm_id, subject_type="group", subject=herd, event_type="delivered", occurred_at=_days_ago(day, hour), notes=f"{label} feeding",
                components=[{"feed_product_id": t["feed_product_id"], "quantity_offered": round(t["daily_total"] / 2, 2)} for t in herd_plan["daily_targets"]],
                user_id="user-worker-1",
            )
    if flock_plan is not None:
        for day in range(6, -1, -1):
            programs.record_feeding(
                db, farm_id, subject_type="group", subject=layer_flock, event_type="delivered", occurred_at=_days_ago(day, 7),
                components=[{"feed_product_id": t["feed_product_id"], "quantity_offered": t["daily_total"]} for t in flock_plan["daily_targets"]],
                user_id="user-worker-1",
            )
    if bella is not None:
        programs.record_feeding(db, farm_id, subject_type="animal", subject=bella, event_type="delivered", occurred_at=_days_ago(0, 7),
                                components=[{"feed_product_id": concentrate.id, "quantity_offered": 2}], notes="Supplement", user_id="user-worker-1")

    # --------------------------------------------------------- allocation
    # §25: most of the premix is reserved for the lactating dairy cows.
    inv.allocate(db, premix, quantity=400, unit="kg", lot_id=premix_lot.id, species_code="cow", feeding_program_id=dairy_high.id,
                 purpose="Lactating dairy cows — high-production ration", transferable=False, user_id=u)

    # ------------------------------------------------------ replenishment
    for product, pol in (
        (premix, dict(minimum_stock=50, reorder_point=100, safety_stock=50, preferred_reorder_quantity=500, maximum_stock=1000, lead_time_days=7)),
        (layer, dict(minimum_stock=800, reorder_point=1500, safety_stock=300, preferred_reorder_quantity=2000, lead_time_days=5)),
        (silage, dict(minimum_stock=1500, reorder_point=2500, safety_stock=500, preferred_reorder_quantity=5000, lead_time_days=3)),
        (concentrate, dict(minimum_stock=500, reorder_point=800, safety_stock=200, preferred_reorder_quantity=2000, lead_time_days=7)),
        (dairy_mix, dict(minimum_stock=500, reorder_point=1000, safety_stock=300, preferred_reorder_quantity=1000, lead_time_days=1)),
    ):
        db.add(fm.FeedReorderPolicy(farm_id=farm_id, feed_product_id=product.id, unit="kg", active=True, **pol))
    db.flush()

    # Pin the opening balances so the items end on the figures the demo
    # narrative uses (the batch and the week of feedings drew them down).
    for product in (dairy_mix, alfalfa, silage, layer, goat, minerals):
        _pin_opening_balance(db, product, targets[product.inventory_item_id])

    # ------------------------------------------------------ reconciliation
    # §27: the premix count is 25 kg short of the ledger — a variance, open.
    forecast.reconcile(db, farm_id, premix, lot=premix_lot, period_from=_days_ago(14), period_to=_now(),
                       counted_closing_quantity=round(premix_lot.quantity_on_hand - 25, 1), explanation=None, user_id=u)
    db.flush()
