"""Least-cost formulation drafts (master prompt Package 12;
database/LEAST-COST-FORMULATION.md, architecture/ADR-010-LEAST-COST-SOLVER.md).

The problem, on the same analyses and the same arithmetic as the nutrition
assessment (Package 11):

* the variables are the kg of each allowed ingredient in one batch of the
  concentrate (the base formula's size — 1,210 kg for the farm's base mix —
  unless another is given): ``Σ xᵢ = B``, each within the manager's limits and
  the feed usage policy's maximum inclusion;
* the animal eats ``C`` kg of the concentrate a day (and its forage, and a
  premix on top when one is given): its dry matter and each nutrient on dry
  matter are linear in ``x`` once multiplied out by the intake, so every
  requirement ``min ≤ nutrient ≤ max`` is a linear row;
* the cost is ``Σ priceᵢ · xᵢ`` at **today's** price of each ingredient, kept
  with the run.

Up to three drafts are solved: **A** the cheapest; **B** the cheapest with a
safety margin inside every bound; **C** the closest to the current formula
(least kg changed) that meets the requirements. A draft that cannot be met
is said to be infeasible, with the limits that cannot be met; nothing is run
when an ingredient's analysis, dry matter, a required nutrient or its price
is unknown (*insufficient data*). A blocked ingredient or premix is refused.

A draft is a plan: no stock moves, no formula changes. A manager approves one
draft (audited, once per run): it becomes a new **draft** version of the
formula, activated later by the usual formula approval.
"""
from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import feed_models as fm
from app.domain import formulation_models as fmm
from app.domain import models
from app.feeding import lp, uom
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event
from app.services import feed_batch_service as batches
from app.services import feed_inventory_service as inv
from app.services import feed_policy_service as policy
from app.services import nutrition_service as nut
from app.services.feed_inventory_service import FeedError
from app.services.nutrition_service import NutritionError

MODULE = "feed_nutrition"
DEFAULT_MARGIN_PCT = 3.0
MAX_CANDIDATES = 25
# Every bound is solved this far inside (%), so a draft rounded to 0.1 kg still meets the bound it is reported against.
GUARD_PCT = 0.1


def price_of(db: Session, product: fm.FeedProduct) -> tuple[float | None, dict]:
    """Today's price of a kg as fed and where it comes from: the lot that
    would be used next (FIFO, its supplier and cost), else the feed's price."""
    usable = sorted((l for l in product.lots if inv.lot_usable(l) and l.quantity_on_hand > 0), key=lambda l: l.received_at)
    lot = usable[0] if usable and usable[0].unit_cost is not None else None
    cost = inv.current_unit_cost(db, product)
    if cost is None:
        return None, {"source": None}
    per_kg = cost / uom.convert(1.0, product.unit, "kg") if product.unit and product.unit != "kg" else cost
    if lot is not None:
        return per_kg, {"source": "lot", "lot_id": lot.id, "lot_code": lot.lot_code, "supplier": lot.supplier_label}
    return per_kg, {"source": "price"}


def _rounded(xs: list[float], total: float) -> list[float]:
    """To 0.1 kg, the rounding put on the largest so the batch still adds up."""
    out = [round(x, 1) for x in xs]
    if out:
        i = max(range(len(out)), key=lambda k: out[k])
        out[i] = round(out[i] + (total - sum(out)), 1)
    return out


def run(db: Session, user: models.User, *, requirement_set_id: str, base_formula_version_id: str | None = None, candidates: list[dict] | None = None,
        batch_size_kg: float | None = None, concentrate_kg_per_head: float | None = None, forages: list[dict] | None = None, no_forage: bool = False,
        body_weight_kg: float | None = None, premix: dict | None = None, margin_pct: float | None = None, notes: str | None = None) -> fmm.FormulationRun:
    rs = nut.get_set(db, requirement_set_id, user.farm_id)
    if rs.status != "active":
        raise NutritionError(f"{rs.code} v{rs.version} was replaced by a newer version: use the current one.", 409)
    base = formula = None
    if base_formula_version_id:
        base, formula = nut._version(db, base_formula_version_id, user.farm_id)
        if formula.species_code and formula.species_code != rs.species_code:
            raise NutritionError(f"These requirements are for {rs.species_code}; {formula.name} is made for {formula.species_code}: "
                                 "other species need their own requirements.", 422)
    margin = DEFAULT_MARGIN_PCT if margin_pct is None else float(margin_pct)
    if not 0 <= margin <= 20:
        raise NutritionError("The safety margin is between 0 and 20 %.", 422)

    # The batch and what may go in it.
    base_kg = {c.feed_product_id: uom.convert(c.target_quantity, c.unit, "kg") for c in base.components} if base else {}
    size = float(batch_size_kg) if batch_size_kg else (sum(base_kg.values()) if base_kg else None)
    if not size or size <= 0:
        raise NutritionError("Give the batch size in kg (or a base formula to take it from).", 422)
    if candidates is None:
        if not base:
            raise NutritionError("Say which ingredients may go in (or give a base formula to take them from).", 422)
        candidates = [{"feed_product_id": pid} for pid in base_kg]
    if not candidates:
        raise NutritionError("Allow at least one ingredient.", 422)
    if len(candidates) > MAX_CANDIDATES:
        raise NutritionError(f"At most {MAX_CANDIDATES} ingredients in one run.", 422)
    seen: set[str] = set()
    target = policy.Target(species_code=rs.species_code, label=f"least-cost formulation for {rs.code}", partial=True)
    names = {n.code: n.name_en for n in db.scalars(select(fm.FeedNutrient))}
    required = [v.nutrient_code for v in rs.values]
    feeds: list[nut._Feed] = []
    limits: list[tuple[float, float]] = []
    prices: list[float | None] = []
    origins: list[dict] = []
    missing: list[dict] = []
    for c in candidates:
        product = nut._product(db, c.get("feed_product_id") or "", user.farm_id)
        if product.id in seen:
            raise NutritionError(f"{product.name} is given twice.", 422)
        seen.add(product.id)
        lo = float(c.get("min_pct") or 0)
        hi = float(c["max_pct"]) if c.get("max_pct") is not None else 100.0
        if lo < 0 or hi > 100 or lo > hi:
            raise NutritionError(f"{product.name}: the limits must be 0–100 % with the minimum below the maximum.", 422)
        try:
            decision = policy.check_or_raise(db, product, target, through_formula=True, context="least_cost_formulation", user_id=user.id)
        except FeedError as exc:
            raise NutritionError(f"{product.name} cannot go into a {rs.species_code} feed: {exc.message}", 422) from exc
        if decision.max_inclusion_pct is not None:
            hi = min(hi, decision.max_inclusion_pct)
        f = nut._Feed(db, product, 0.0, "ingredient")
        feeds.append(f)
        limits.append((lo, hi))
        price, origin = price_of(db, product)
        prices.append(price)
        origins.append(origin)
        missing.extend(nut._feed_gaps(f, required, names))
        if price is None:
            missing.append(nut._missing("price_unknown", f"{product.name} has no price: it cannot be costed.", feed_product_id=product.id))

    premix_feed = None
    premix_kg = 0.0
    if premix:
        premix_kg = float(premix.get("quantity_kg") or 0)
        if premix_kg <= 0:
            raise NutritionError("Say how many kg of premix go on top of the batch.", 422)
        product = nut._product(db, premix.get("feed_product_id") or "", user.farm_id)
        try:
            policy.check_or_raise(db, product, target, inclusion_pct=premix_kg / (size + premix_kg) * 100, through_formula=True,
                                  context="least_cost_formulation", user_id=user.id)
        except FeedError as exc:
            raise NutritionError(f"The premix {product.name} cannot go into this feed: {exc.message}", 422) from exc
        premix_feed = nut._Feed(db, product, premix_kg, "premix")
        missing.extend(nut._feed_gaps(premix_feed, required, names))
        premix_price, _origin = price_of(db, product)
        if premix_price is None:
            missing.append(nut._missing("price_unknown", f"{product.name} has no price: it cannot be costed.", feed_product_id=product.id))
    else:
        premix_price = 0.0

    if concentrate_kg_per_head is None:
        missing.append(nut._missing("intake_unknown", "How much of this concentrate each animal eats a day is not given."))
    elif concentrate_kg_per_head <= 0:
        raise NutritionError("The concentrate per head must be more than zero.", 422)
    forage_feeds = []
    for fo in forages or []:
        kg = float(fo.get("as_fed_kg") or 0)
        if kg <= 0:
            raise NutritionError("Give each forage's kg as fed per head per day.", 422)
        forage_feeds.append(nut._Feed(db, nut._product(db, fo.get("feed_product_id") or "", user.farm_id), kg, "forage"))
    if not forage_feeds and not no_forage:
        missing.append(nut._missing("forage_unknown", "Which forage each animal eats, and how much, is not given (or say the ration is this feed only)."))
    for f in forage_feeds:
        missing.extend(nut._feed_gaps(f, required, names, forage=True))
    if rs.reference_body_weight_kg:
        if body_weight_kg is None:
            missing.append(nut._missing("body_weight_unknown", f"The animals' weight is not given; {rs.code} is for {rs.reference_body_weight_kg:g} kg."))
        elif abs(body_weight_kg - rs.reference_body_weight_kg) / rs.reference_body_weight_kg > nut.WEIGHT_TOLERANCE:
            missing.append(nut._missing("body_weight_outside_set", f"{body_weight_kg:g} kg is not what {rs.code} is for ({rs.reference_body_weight_kg:g} kg)."))

    inputs = {"requirement_set_id": rs.id, "base_formula_version_id": base.id if base else None, "candidates": candidates, "batch_size_kg": size,
              "concentrate_kg_per_head": concentrate_kg_per_head, "forages": forages or [], "no_forage": no_forage, "body_weight_kg": body_weight_kg,
              "premix": premix, "margin_pct": margin, "notes": (notes or "").strip() or None}
    price_list = [{"feed_product_id": f.product.id, "name": f.product.name, "price_per_kg": p, **o} for f, p, o in zip(feeds, prices, origins)]
    result: dict = {"requirement_set": {"id": rs.id, "code": rs.code, "version": rs.version, "name": rs.name, "species_code": rs.species_code,
                                        "source_reference": rs.source_reference},
                    "base": ({"formula_id": formula.id, "formula_name": formula.name, "version": base.version, "batch_size_kg": sum(base_kg.values())}
                             if base else None),
                    "batch_size_kg": size, "prices": price_list, "priced_at": now().isoformat(), "missing": missing, "drafts": [], "infeasible": []}

    if missing:
        status = "insufficient_data"
    else:
        status = _solve_drafts(db, result, rs, feeds, limits, prices, size, concentrate_kg_per_head, forage_feeds, premix_feed, premix_kg, premix_price or 0.0,
                               margin, base_kg)
    r = fmm.FormulationRun(id=new_id(), farm_id=user.farm_id, requirement_set_id=rs.id, base_formula_version_id=base.id if base else None, status=status,
                           inputs=inputs, result=result, created_by=user.id, created_at=now())
    db.add(r)
    db.flush()
    write_event(db, farm_id=r.farm_id, entity_type="formulation_run", entity_id=r.id, event_type="least_cost_formulated",
                payload={"status": status, "requirement_set": f"{rs.code} v{rs.version}", "drafts": [d["key"] for d in result["drafts"]],
                         "missing": [m["code"] for m in missing]}, created_by=user.id)
    write_audit_log(db, farm_id=r.farm_id, user_id=user.id, action="least_cost_formulated", entity_type="formulation_run", entity_id=r.id, module_code=MODULE,
                    summary=f"Least-cost run against {rs.code} v{rs.version}: {status.replace('_', ' ')}, {len(result['drafts'])} draft(s)"[:500])
    return r


def _solve_drafts(db: Session, result: dict, rs, feeds, limits, prices, size, conc, forage_feeds, premix_feed, premix_kg, premix_price, margin, base_kg) -> str:
    n = len(feeds)
    k = conc / (size + premix_kg)  # kg of the batch's mix each animal eats per kg of batch
    fdm = sum(f.dm_kg for f in forage_feeds)
    pdm = k * premix_feed.dm_kg if premix_feed else 0.0
    fixed_dm = fdm + pdm

    def fixed(code: str) -> float:
        out = sum(f.dm_kg * f.dry[code] for f in forage_feeds)
        if premix_feed:
            out += k * premix_feed.dm_kg * premix_feed.dry[code]
        return out

    dmf = [f.dm_pct / 100.0 for f in feeds]
    bounds = [(lo * size / 100, hi * size / 100) for lo, hi in limits]

    def rows(m: float) -> tuple[list[list[float]], list[float], list[tuple[str, str, float]]]:
        A, b, labels = [], [], []
        m = m + GUARD_PCT
        for v in rs.values:
            code = v.nutrient_code
            if v.min_value is not None:
                lo = v.min_value * (1 + m / 100)
                A.append([-k * dmf[i] * (feeds[i].dry[code] - lo) for i in range(n)])
                b.append(fixed(code) - lo * fixed_dm)
                labels.append((code, "min", v.min_value * (1 + (m - GUARD_PCT) / 100)))
            if v.max_value is not None:
                hi = v.max_value * (1 - m / 100)
                A.append([k * dmf[i] * (feeds[i].dry[code] - hi) for i in range(n)])
                b.append(hi * fixed_dm - fixed(code))
                labels.append((code, "max", v.max_value * (1 - (m - GUARD_PCT) / 100)))
        return A, b, labels

    def draft(key: str, label: str, x: list[float]) -> dict:
        xs = _rounded(x, size)
        cost = sum(p * q for p, q in zip(prices, xs)) + premix_price * premix_kg
        total = size + premix_kg
        dmi = sum(k * dmf[i] * xs[i] for i in range(n)) + fixed_dm
        nutrients = []
        for v in rs.values:
            code = v.nutrient_code
            value = (sum(k * dmf[i] * xs[i] * feeds[i].dry[code] for i in range(n)) + fixed(code)) / dmi
            state = "below" if v.min_value is not None and value < v.min_value - 1e-6 else ("above" if v.max_value is not None and value > v.max_value + 1e-6 else "met")
            nutrients.append({"nutrient_code": code, "name": nut_names.get(code, code), "unit": v.unit, "min_value": v.min_value, "max_value": v.max_value,
                              "value": round(value, 3), "status": state})
        return {"key": key, "label": label, "components": [
                    {"feed_product_id": f.product.id, "name": f.product.name, "quantity_kg": q, "inclusion_pct": round(q / total * 100, 2),
                     "price_per_kg": p, "cost": round(p * q, 2)} for f, q, p in zip(feeds, xs, prices) if q > 0],
                "premix": ({"feed_product_id": premix_feed.product.id, "name": premix_feed.product.name, "quantity_kg": premix_kg,
                            "price_per_kg": premix_price, "cost": round(premix_price * premix_kg, 2)} if premix_feed else None),
                "batch_kg": size, "total_kg": total, "cost": round(cost, 2), "cost_per_kg": round(cost / total, 4),
                "dry_matter_intake_kg": round(dmi, 3), "nutrients": nutrients}

    nut_names = {}
    for v in rs.values:
        row = db.get(fm.FeedNutrient, v.nutrient_code)
        nut_names[v.nutrient_code] = row.name_en if row else v.nutrient_code

    price = list(prices)
    eq_a, eq_b = [[1.0] * n], [size]
    A, b, labels = rows(0.0)
    cheapest = lp.solve(price, A_ub=A, b_ub=b, A_eq=eq_a, b_eq=eq_b, bounds=bounds)
    if cheapest.status != "optimal":
        result["infeasible"] = _why_infeasible(n, bounds, eq_a, eq_b, A, b, labels, nut_names)
        return "infeasible"
    result["drafts"].append(draft("A", "least_cost", cheapest.x))
    if margin > 0:
        Am, bm, _ = rows(margin)
        safer = lp.solve(price, A_ub=Am, b_ub=bm, A_eq=eq_a, b_eq=eq_b, bounds=bounds)
        if safer.status == "optimal":
            result["drafts"].append(draft("B", "with_margin", safer.x))
        else:
            result["notes"] = result.get("notes", []) + [f"No draft with a {margin:g} % margin inside every bound: the ingredients and limits do not allow it."]
    if base_kg:
        scale = size / sum(base_kg.values())
        target = [base_kg.get(f.product.id, 0.0) * scale for f in feeds]
        # min Σ dᵢ with dᵢ ≥ |xᵢ − targetᵢ|: variables x (n) then d (n).
        c2 = [0.0] * n + [1.0] * n
        A2 = [row + [0.0] * n for row in A]
        b2 = list(b)
        for i in range(n):
            up = [0.0] * (2 * n)
            up[i], up[n + i] = 1.0, -1.0
            down = [0.0] * (2 * n)
            down[i], down[n + i] = -1.0, -1.0
            A2 += [up, down]
            b2 += [target[i], -target[i]]
        closest = lp.solve(c2, A_ub=A2, b_ub=b2, A_eq=[[1.0] * n + [0.0] * n], b_eq=[size], bounds=bounds + [(0.0, None)] * n)
        if closest.status == "optimal":
            d = draft("C", "least_change", closest.x[:n])
            d["changed_kg"] = round(sum(abs(q - t) for q, t in zip([c["quantity_kg"] for c in _all(d, feeds)], target)) / 2, 1)
            result["drafts"].append(d)
        current_cost = sum(p * t for p, t in zip(price, target)) + premix_price * premix_kg
        result["base"]["cost_today"] = round(current_cost, 2)
        for dft in result["drafts"]:
            dft["saving"] = round(current_cost - dft["cost"], 2)
    return "drafts"


def _all(d: dict, feeds) -> list[dict]:
    by = {c["feed_product_id"]: c for c in d["components"]}
    return [by.get(f.product.id, {"quantity_kg": 0.0}) for f in feeds]


def _why_infeasible(n, bounds, eq_a, eq_b, A, b, labels, names) -> list[dict]:
    """Each bound that cannot be met even alone (with the batch size and the limits); else that they cannot all be met together."""
    alone = []
    for row, rhs, (code, side, value) in zip(A, b, labels):
        if lp.solve([0.0] * n, A_ub=[row], b_ub=[rhs], A_eq=eq_a, b_eq=eq_b, bounds=bounds).status != "optimal":
            alone.append({"nutrient_code": code, "name": names.get(code, code), "bound": side, "value": round(value, 3),
                          "detail": f"{names.get(code, code)} {'≥' if side == 'min' else '≤'} {value:g}: not reachable with these ingredients and limits."})
    if not alone:
        if lp.solve([0.0] * n, A_eq=eq_a, b_eq=eq_b, bounds=bounds).status != "optimal":
            return [{"nutrient_code": None, "detail": "The ingredients' limits cannot add up to the batch size."}]
        return [{"nutrient_code": None, "detail": "Each requirement can be met alone, but not all of them together with these ingredients and limits."}]
    return alone


# ---------------------------------------------------------------- reading and approval
def get_run(db: Session, run_id: str, farm_id: str, *, lock: bool = False) -> fmm.FormulationRun:
    stmt = select(fmm.FormulationRun).where(fmm.FormulationRun.id == run_id)
    if lock:
        stmt = stmt.with_for_update().execution_options(populate_existing=True)
    r = db.scalar(stmt)
    if r is None or r.farm_id != farm_id:
        raise NutritionError("Formulation run not found", 404)
    return r


def list_runs(db: Session, farm_id: str, *, limit: int = 30) -> list[fmm.FormulationRun]:
    return list(db.scalars(select(fmm.FormulationRun).where(fmm.FormulationRun.farm_id == farm_id).order_by(fmm.FormulationRun.created_at.desc()).limit(limit)))


def approve(db: Session, user: models.User, r: fmm.FormulationRun, *, draft_key: str, note: str | None = None, formula_id: str | None = None) -> fm.FeedFormulaVersion:
    """One draft of the run becomes a new draft version of the formula (never activated here); once per run."""
    r = get_run(db, r.id, r.farm_id, lock=True)
    if r.approved_draft:
        raise NutritionError(f"Draft {r.approved_draft} of this run was already approved.", 409)
    if r.status != "drafts":
        raise NutritionError("This run has no draft to approve.", 409)
    d = next((x for x in r.result.get("drafts", []) if x["key"] == (draft_key or "").upper()), None)
    if d is None:
        raise NutritionError(f"This run has no draft {draft_key}.", 404)
    if not (note or "").strip():
        raise NutritionError("Say why this draft is approved (the nutritionist's review, the trial…).", 422)
    rs = nut.get_set(db, r.requirement_set_id, r.farm_id)
    if r.base_formula_version_id:
        _base, formula = nut._version(db, r.base_formula_version_id, r.farm_id)
    elif formula_id:
        formula = db.get(fm.FeedFormula, formula_id)
        if formula is None or formula.farm_id != r.farm_id:
            raise NutritionError("Formula not found", 404)
    else:
        raise NutritionError("Say which formula the draft becomes a version of.", 422)
    components = [{"feed_product_id": c["feed_product_id"], "target_quantity": c["quantity_kg"], "unit": "kg"} for c in d["components"]]
    if d.get("premix"):
        components.append({"feed_product_id": d["premix"]["feed_product_id"], "target_quantity": d["premix"]["quantity_kg"], "unit": "kg"})
    try:
        version = batches.add_version(db, formula, batch_size=d["total_kg"], unit="kg", components=components, activate=False, user_id=user.id,
                                      notes=f"Least-cost draft {d['key']} ({d['label'].replace('_', ' ')}) of run {r.id[:8]} against {rs.code} v{rs.version}, "
                                            f"USD {d['cost']:.2f} at the prices of {r.result.get('priced_at', '')[:10]}. {note.strip()}"[:2000])
    except FeedError as exc:
        raise NutritionError(exc.message, exc.status_code) from exc
    r.approved_draft = d["key"]
    r.approved_by = user.id
    r.approved_at = now()
    r.approval_note = note.strip()[:2000]
    r.approved_formula_version_id = version.id
    db.flush()
    write_event(db, farm_id=r.farm_id, entity_type="formulation_run", entity_id=r.id, event_type="least_cost_draft_approved",
                payload={"draft": d["key"], "formula_id": formula.id, "formula_version_id": version.id, "version": version.version, "cost": d["cost"],
                         "note": r.approval_note}, created_by=user.id)
    write_audit_log(db, farm_id=r.farm_id, user_id=user.id, action="least_cost_draft_approved", entity_type="formulation_run", entity_id=r.id, module_code=MODULE,
                    summary=f"Draft {d['key']} approved as {formula.name} v{version.version} (draft, not active): {r.approval_note}"[:500])
    return version


def run_dict(db: Session, r: fmm.FormulationRun) -> dict:
    who = db.get(models.User, r.created_by) if r.created_by else None
    approver = db.get(models.User, r.approved_by) if r.approved_by else None
    return {"id": r.id, "status": r.status, "requirement_set_id": r.requirement_set_id, "base_formula_version_id": r.base_formula_version_id,
            "created_at": ensure_utc(r.created_at).isoformat(), "created_by": r.created_by, "created_by_name": who.name if who else None,
            "inputs": r.inputs, **(r.result or {}),
            "approval": ({"draft": r.approved_draft, "by": r.approved_by, "by_name": approver.name if approver else None,
                          "at": ensure_utc(r.approved_at).isoformat() if r.approved_at else None, "note": r.approval_note,
                          "formula_version_id": r.approved_formula_version_id} if r.approved_draft else None)}
