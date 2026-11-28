"""Nutrient requirements and the explainable assessment of a formula
(master prompt Package 11; database/NUTRITION-ASSESSMENT.md).

The arithmetic, all on explicit units and an explicit basis:

* an analysis is a feed nutrient profile (declared, lab or calculated; as fed
  or on dry matter). The one trusted is the newest lab result, else the
  declared one (`feed_batch_service.latest_profile`). Its DM % is what turns
  as-fed values into dry-matter values and back: a value per kg as fed is
  ``value / (DM / 100)`` per kg of dry matter;
* the mix is the formula version's actual quantities — the farm's base
  concentrate is 1,210 kg before any premix, and stays 1,210 kg; a premix is
  a what-if on top (the base kept, the inclusions recomputed over the new
  total), never written into the formula;
* a nutrient of the mix is known only when every ingredient's analysis gives
  it (with its coverage shown when not); the ration adds the forage and puts
  it all on the day's dry-matter intake per head;
* against one version of a requirement set (min / max on the ration's dry
  matter, with its source), each nutrient is met, below or above — or, when
  anything it depends on is unknown, the whole assessment is *insufficient
  data*, says exactly what is missing and recommends nothing.

An assessment is stored as computed (inputs, the analyses used, the result)
and is never recomputed: a later analysis or a later requirement version
makes a new assessment, the old one reads as it was. It never changes a
formula, a batch or a feeding program, and never predicts milk.
"""
from __future__ import annotations

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.domain import feed_models as fm
from app.domain import livestock_models, models
from app.domain import nutrition_models as nm
from app.feeding import uom
from app.repositories.base import ensure_utc, new_id, now, write_audit_log, write_event
from app.services import feed_batch_service as batches
from app.services import feed_policy_service as policy
from app.services.feed_inventory_service import FeedError

MODULE = "feed_nutrition"
NOT_NUTRIENTS = ("DM", "MOISTURE")
# An assessment for an animal this far from the set's reference weight is not one.
WEIGHT_TOLERANCE = 0.15
# The ration's dry-matter intake within this share of the set's expected intake is "as expected".
DMI_TOLERANCE = 0.10


class NutritionError(FeedError):
    pass


# ---------------------------------------------------------------- basis
def to_dry_matter(value: float, *, dm_pct: float) -> float:
    """A value per kg as fed, per kg of dry matter (8 % CP at 88 % DM is 9.09 %)."""
    if not dm_pct or dm_pct <= 0 or dm_pct > 100:
        raise NutritionError("A dry-matter share between 0 and 100 % is needed to put a value on dry matter.", 422)
    return value / (dm_pct / 100.0)


def to_as_fed(value: float, *, dm_pct: float) -> float:
    if not dm_pct or dm_pct <= 0 or dm_pct > 100:
        raise NutritionError("A dry-matter share between 0 and 100 % is needed to put a value as fed.", 422)
    return value * (dm_pct / 100.0)


def _r(x: float | None, nd: int = 3) -> float | None:
    return None if x is None else round(x, nd)


# ---------------------------------------------------------------- requirement sets
def _nutrient(db: Session, code: str) -> fm.FeedNutrient:
    n = db.get(fm.FeedNutrient, (code or "").strip().upper())
    if n is None:
        raise NutritionError(f"Unknown nutrient {code}; it must be in the nutrient catalog.", 422)
    return n


def _values(db: Session, values: list[dict]) -> list[nm.NutritionRequirementValue]:
    if not values:
        raise NutritionError("A requirement set needs at least one nutrient with a minimum or a maximum.", 422)
    out, seen = [], set()
    for v in values:
        n = _nutrient(db, v.get("nutrient_code"))
        if n.code in NOT_NUTRIENTS:
            raise NutritionError("Dry matter is not a requirement here: the intake is (expected dry-matter intake).", 422)
        if n.code in seen:
            raise NutritionError(f"{n.name_en} is given twice.", 422)
        seen.add(n.code)
        lo, hi = v.get("min_value"), v.get("max_value")
        if lo is None and hi is None:
            raise NutritionError(f"{n.name_en}: give a minimum, a maximum or both.", 422)
        if lo is not None and hi is not None and float(lo) > float(hi):
            raise NutritionError(f"{n.name_en}: the minimum {lo:g} is above the maximum {hi:g}.", 422)
        if (lo is not None and float(lo) < 0) or (hi is not None and float(hi) < 0):
            raise NutritionError(f"{n.name_en}: a requirement cannot be negative.", 422)
        out.append(nm.NutritionRequirementValue(id=new_id(), nutrient_code=n.code, min_value=None if lo is None else float(lo),
                                                max_value=None if hi is None else float(hi), unit=n.unit))
    return out


def _source(source_reference: str | None, source_type: str | None) -> tuple[str, str]:
    ref = (source_reference or "").strip()
    if not ref:
        raise NutritionError("Say where these requirements come from (the table, the nutritionist, the date): a requirement without a source is not used.", 422)
    kind = source_type or "nutritionist"
    if kind not in nm.SOURCE_TYPES:
        raise NutritionError(f"source_type must be one of {', '.join(nm.SOURCE_TYPES)}.", 422)
    return ref[:400], kind


def _positive(name: str, value: float | None) -> float | None:
    if value is None:
        return None
    if value <= 0:
        raise NutritionError(f"{name} must be more than zero.", 422)
    return float(value)


def get_set(db: Session, set_id: str, farm_id: str) -> nm.NutritionRequirementSet:
    s = db.get(nm.NutritionRequirementSet, set_id)
    if s is None or s.farm_id != farm_id:
        raise NutritionError("Requirement set not found", 404)
    return s


def create_set(db: Session, user: models.User, *, code: str, name: str, species_code: str, source_reference: str, source_type: str | None = None,
               production_stage: str | None = None, reference_body_weight_kg: float | None = None, milk_yield_kg: float | None = None,
               expected_dmi_kg: float | None = None, notes: str | None = None, values: list[dict]) -> nm.NutritionRequirementSet:
    code = (code or "").strip().upper()
    if not code or not (name or "").strip():
        raise NutritionError("A requirement set needs a code and a name.", 422)
    if db.get(livestock_models.Species, species_code) is None:
        raise NutritionError(f"Unknown species '{species_code}'.", 422)
    ref, kind = _source(source_reference, source_type)
    rows = _values(db, values)
    if db.scalar(select(nm.NutritionRequirementSet.id).where(nm.NutritionRequirementSet.farm_id == user.farm_id, nm.NutritionRequirementSet.code == code)):
        raise NutritionError(f"{code} exists: change it by a new version, so what was assessed against it stays as it was.", 409)
    s = nm.NutritionRequirementSet(id=new_id(), farm_id=user.farm_id, code=code, version=1, name=name.strip()[:200], species_code=species_code,
                                   production_stage=(production_stage or "").strip()[:60] or None,
                                   reference_body_weight_kg=_positive("The reference body weight", reference_body_weight_kg),
                                   milk_yield_kg=None if milk_yield_kg is None else max(0.0, float(milk_yield_kg)),
                                   expected_dmi_kg=_positive("The expected dry-matter intake", expected_dmi_kg), basis="dry_matter",
                                   source_type=kind, source_reference=ref, status="active", notes=(notes or "").strip() or None,
                                   created_by=user.id, created_at=now())
    s.values = rows
    db.add(s)
    db.flush()
    _recorded(db, user, s, "nutrition_requirements_recorded")
    return s


def new_version(db: Session, user: models.User, current: nm.NutritionRequirementSet, *, source_reference: str, source_type: str | None = None,
                values: list[dict] | None = None, **changes) -> nm.NutritionRequirementSet:
    """A revision: a new version beside the old one, which is retired (kept, and still what its assessments read)."""
    # The version revised is locked and read afresh: a revision made meanwhile
    # (by another manager) retired it, and this one is refused, not a second v2.
    current = db.scalar(select(nm.NutritionRequirementSet).where(nm.NutritionRequirementSet.id == current.id)
                        .with_for_update().execution_options(populate_existing=True))
    if current.status != "active":
        latest = db.scalar(select(func.max(nm.NutritionRequirementSet.version)).where(nm.NutritionRequirementSet.farm_id == current.farm_id,
                                                                                     nm.NutritionRequirementSet.code == current.code))
        raise NutritionError(f"{current.code} v{current.version} was already revised (now v{latest}): revise the current one.", 409)
    ref, kind = _source(source_reference, source_type or current.source_type)
    rows = _values(db, values) if values is not None else _values(db, [{"nutrient_code": v.nutrient_code, "min_value": v.min_value, "max_value": v.max_value}
                                                                        for v in current.values])

    def pick(key: str):
        return changes[key] if changes.get(key) is not None else getattr(current, key)

    s = nm.NutritionRequirementSet(id=new_id(), farm_id=current.farm_id, code=current.code, version=current.version + 1, name=pick("name"),
                                   species_code=current.species_code, production_stage=pick("production_stage"),
                                   reference_body_weight_kg=_positive("The reference body weight", pick("reference_body_weight_kg")),
                                   milk_yield_kg=pick("milk_yield_kg"), expected_dmi_kg=_positive("The expected dry-matter intake", pick("expected_dmi_kg")),
                                   basis="dry_matter", source_type=kind, source_reference=ref, status="active", notes=pick("notes"),
                                   created_by=user.id, created_at=now())
    s.values = rows
    current.status = "retired"
    current.retired_at = now()
    db.add(s)
    db.flush()
    _recorded(db, user, s, "nutrition_requirements_revised", previous=current)
    return s


def _recorded(db: Session, user: models.User, s: nm.NutritionRequirementSet, action: str, previous: nm.NutritionRequirementSet | None = None) -> None:
    payload = {"code": s.code, "version": s.version, "species_code": s.species_code, "source_reference": s.source_reference,
               "values": [{"nutrient_code": v.nutrient_code, "min": v.min_value, "max": v.max_value, "unit": v.unit} for v in s.values]}
    if previous is not None:
        payload["previous_id"] = previous.id
    write_event(db, farm_id=s.farm_id, entity_type="nutrition_requirement_set", entity_id=s.id, event_type=action, payload=payload, created_by=user.id)
    write_audit_log(db, farm_id=s.farm_id, user_id=user.id, action=action, entity_type="nutrition_requirement_set", entity_id=s.id, module_code=MODULE,
                    summary=f"{s.code} v{s.version} ({s.species_code}) from {s.source_reference}"[:500])


def list_sets(db: Session, farm_id: str, *, include_retired: bool = False, species_code: str | None = None) -> list[nm.NutritionRequirementSet]:
    stmt = select(nm.NutritionRequirementSet).where(nm.NutritionRequirementSet.farm_id == farm_id)
    if not include_retired:
        stmt = stmt.where(nm.NutritionRequirementSet.status == "active")
    if species_code:
        stmt = stmt.where(nm.NutritionRequirementSet.species_code == species_code)
    return list(db.scalars(stmt.order_by(nm.NutritionRequirementSet.code, nm.NutritionRequirementSet.version.desc())))


def set_dict(db: Session, s: nm.NutritionRequirementSet) -> dict:
    def label(code: str) -> tuple[str, str]:
        n = db.get(fm.FeedNutrient, code)
        return (n.name_en, n.name_ar) if n else (code, code)

    return {"id": s.id, "code": s.code, "version": s.version, "name": s.name, "species_code": s.species_code, "production_stage": s.production_stage,
            "reference_body_weight_kg": s.reference_body_weight_kg, "milk_yield_kg": s.milk_yield_kg, "expected_dmi_kg": s.expected_dmi_kg,
            "basis": s.basis, "source_type": s.source_type, "source_reference": s.source_reference, "status": s.status, "notes": s.notes,
            "created_at": ensure_utc(s.created_at).isoformat(), "retired_at": ensure_utc(s.retired_at).isoformat() if s.retired_at else None,
            "values": [{"nutrient_code": v.nutrient_code, "name": label(v.nutrient_code)[0], "name_ar": label(v.nutrient_code)[1],
                        "min_value": v.min_value, "max_value": v.max_value, "unit": v.unit} for v in sorted(s.values, key=lambda v: _order(db, v.nutrient_code))]}


def _order(db: Session, code: str) -> int:
    n = db.get(fm.FeedNutrient, code)
    return n.sort_order if n else 999


# ---------------------------------------------------------------- one feed's analysis
class _Feed:
    """One feed in the mix or the ration, with its analysis put on both bases."""

    def __init__(self, db: Session, product: fm.FeedProduct, quantity_kg: float, role: str):
        self.product, self.quantity_kg, self.role = product, quantity_kg, role
        self.profile = batches.latest_profile(db, "feed_product", product.id)
        self.dm_pct: float | None = None
        self.as_fed: dict[str, float] = {}
        self.dry: dict[str, float] = {}
        self.unit_mismatch: list[str] = []
        if self.profile is None:
            return
        raw = {v.nutrient_code.upper(): v for v in self.profile.values}
        if "DM" in raw and 0 < raw["DM"].value <= 100:
            self.dm_pct = raw["DM"].value
        for code, v in raw.items():
            if code in NOT_NUTRIENTS:
                continue
            nutrient = db.get(fm.FeedNutrient, code)
            if nutrient is not None and v.unit and v.unit != nutrient.unit:
                self.unit_mismatch.append(code)  # never added up with values in another unit
                continue
            if self.profile.basis == "dry_matter":
                self.dry[code] = v.value
                if self.dm_pct:
                    self.as_fed[code] = to_as_fed(v.value, dm_pct=self.dm_pct)
            else:
                self.as_fed[code] = v.value
                if self.dm_pct:
                    self.dry[code] = to_dry_matter(v.value, dm_pct=self.dm_pct)

    @property
    def dm_kg(self) -> float | None:
        return None if self.dm_pct is None else self.quantity_kg * self.dm_pct / 100.0

    def profile_dict(self) -> dict | None:
        p = self.profile
        if p is None:
            return None
        return {"id": p.id, "source_type": p.source_type, "basis": p.basis, "reference": p.reference, "effective_at": ensure_utc(p.effective_at).isoformat()}


def _missing(code: str, detail: str, **extra) -> dict:
    return {"code": code, "detail": detail, **extra}


def _feed_gaps(f: _Feed, needed: list[str], names: dict[str, str], *, forage: bool = False) -> list[dict]:
    name = f.product.name
    if f.profile is None:
        return [_missing("forage_profile_unknown" if forage else ("premix_analysis_unknown" if f.role == "premix" else "analysis_unknown"),
                         f"{name} has no analysis (declared or lab): its nutrients are not known.", feed_product_id=f.product.id)]
    gaps = []
    if f.dm_pct is None:
        gaps.append(_missing("forage_profile_unknown" if forage else "dry_matter_unknown",
                             f"{name}: the analysis gives no dry matter, so it cannot be put on a dry-matter basis.", feed_product_id=f.product.id))
    for code in f.unit_mismatch:
        gaps.append(_missing("unit_mismatch", f"{name}: {names.get(code, code)} is in another unit than the catalog's; it is not added up.",
                             feed_product_id=f.product.id, nutrient_code=code))
    for code in needed:
        if code not in f.as_fed and code not in f.dry and code not in f.unit_mismatch:
            gaps.append(_missing("forage_profile_unknown" if forage else "nutrient_unknown", f"{name}: the analysis gives no {names.get(code, code)}.",
                                 feed_product_id=f.product.id, nutrient_code=code))
    return gaps


# ---------------------------------------------------------------- the assessment
def _version(db: Session, version_id: str, farm_id: str) -> tuple[fm.FeedFormulaVersion, fm.FeedFormula]:
    v = db.get(fm.FeedFormulaVersion, version_id)
    formula = db.get(fm.FeedFormula, v.formula_id) if v else None
    if v is None or formula is None or formula.farm_id != farm_id:
        raise NutritionError("Formula version not found", 404)
    return v, formula


def _product(db: Session, product_id: str, farm_id: str) -> fm.FeedProduct:
    p = db.get(fm.FeedProduct, product_id)
    if p is None or p.farm_id != farm_id:
        raise NutritionError("Feed product not found", 404)
    return p


def assess(db: Session, user: models.User, *, formula_version_id: str, requirement_set_id: str, premix: dict | None = None,
           concentrate_kg_per_head: float | None = None, forages: list[dict] | None = None, no_forage: bool = False,
           body_weight_kg: float | None = None, notes: str | None = None) -> nm.NutritionAssessment:
    version, formula = _version(db, formula_version_id, user.farm_id)
    rs = get_set(db, requirement_set_id, user.farm_id)
    if rs.status != "active":
        raise NutritionError(f"{rs.code} v{rs.version} was replaced by a newer version: assess against the current one.", 409)
    if formula.species_code and formula.species_code != rs.species_code:
        raise NutritionError(f"These requirements are for {rs.species_code}; {formula.name} is made for {formula.species_code}: "
                             "other species need their own requirements.", 422)
    for label, value in (("The concentrate per head", concentrate_kg_per_head), ("The body weight", body_weight_kg)):
        if value is not None and value <= 0:
            raise NutritionError(f"{label} must be more than zero.", 422)

    names = {n.code: n.name_en for n in db.scalars(select(fm.FeedNutrient))}
    required = [v.nutrient_code for v in rs.values]

    # The mix: the formula version's own quantities (1,210 kg stays 1,210 kg), and the premix on top.
    feeds: list[_Feed] = []
    for c in version.components:
        feeds.append(_Feed(db, db.get(fm.FeedProduct, c.feed_product_id), uom.convert(c.target_quantity, c.unit, "kg"), "ingredient"))
    base_total = sum(f.quantity_kg for f in feeds)
    premix_feed = None
    if premix:
        qty = float(premix.get("quantity_kg") or 0)
        if qty <= 0:
            raise NutritionError("Say how many kg of premix go on top of the mix.", 422)
        product = _product(db, premix.get("feed_product_id") or "", user.farm_id)
        target = policy.Target(species_code=rs.species_code, label=f"nutrition assessment of {formula.name}", partial=True)
        try:
            policy.check_or_raise(db, product, target, inclusion_pct=qty / (base_total + qty) * 100, through_formula=True,
                                  context="nutrition_assessment", user_id=user.id)
        except FeedError as exc:
            raise NutritionError(f"The premix {product.name} cannot go into this feed: {exc.message}", 422) from exc
        premix_feed = _Feed(db, product, qty, "premix")
        feeds.append(premix_feed)
    total = sum(f.quantity_kg for f in feeds)

    missing: list[dict] = []
    for f in feeds:
        missing.extend(_feed_gaps(f, required, names))

    codes = list(dict.fromkeys(required + sorted({c for f in feeds for c in (*f.as_fed, *f.dry)}, key=lambda c: (c not in names, c))))
    all_dm = all(f.dm_pct is not None for f in feeds)
    mix_dm_kg = sum(f.dm_kg for f in feeds) if all_dm else None
    mix_nutrients = []
    mix_dry: dict[str, float] = {}
    for code in codes:
        have = [f for f in feeds if code in f.as_fed or code in f.dry]
        coverage = sum(f.quantity_kg for f in have) / total * 100 if total else 0
        af = (sum(f.quantity_kg * f.as_fed[code] for f in feeds) / total) if total and all(code in f.as_fed for f in feeds) else None
        dry = (sum(f.dm_kg * f.dry[code] for f in feeds) / mix_dm_kg) if mix_dm_kg and all(code in f.dry for f in feeds) else None
        if dry is not None:
            mix_dry[code] = dry
        n = db.get(fm.FeedNutrient, code)
        mix_nutrients.append({"nutrient_code": code, "name": n.name_en if n else code, "name_ar": n.name_ar if n else code, "unit": n.unit if n else None,
                              "as_fed_value": _r(af), "dry_matter_value": _r(dry), "coverage_pct": round(coverage, 1),
                              "contributions": [{"name": f.product.name, "quantity_kg": f.quantity_kg,
                                                 "share_pct": round(f.dm_kg * f.dry[code] / (dry * mix_dm_kg) * 100, 1)}
                                                for f in feeds if dry and f.dm_kg is not None and code in f.dry] if dry else []})

    def component(f: _Feed) -> dict:
        return {"feed_product_id": f.product.id, "name": f.product.name, "quantity_kg": f.quantity_kg,
                "inclusion_pct": round(f.quantity_kg / total * 100, 2) if total else 0, "dm_pct": f.dm_pct, "profile": f.profile_dict()}

    mix = {"formula_id": formula.id, "formula_name": formula.name, "formula_version_id": version.id, "formula_version": version.version,
           "species_code": formula.species_code, "base_total_kg": round(base_total, 3), "total_kg": round(total, 3),
           "premix": component(premix_feed) if premix_feed else None,
           "components": [component(f) for f in feeds if f.role == "ingredient"],
           "dry_matter_kg": _r(mix_dm_kg), "dm_pct": _r(mix_dm_kg / total * 100 if mix_dm_kg is not None and total else None),
           "nutrients": mix_nutrients}

    # The ration: the concentrate per head, the forage, the weight.
    if concentrate_kg_per_head is None:
        missing.append(_missing("intake_unknown", "How much of this concentrate each animal eats a day is not given."))
    forage_feeds: list[_Feed] = []
    for fo in forages or []:
        kg = float(fo.get("as_fed_kg") or 0)
        if kg <= 0:
            raise NutritionError("Give each forage's kg as fed per head per day.", 422)
        forage_feeds.append(_Feed(db, _product(db, fo.get("feed_product_id") or "", user.farm_id), kg, "forage"))
    if not forage_feeds and not no_forage:
        missing.append(_missing("forage_unknown", "Which forage each animal eats, and how much, is not given (or say the ration is this feed only)."))
    for f in forage_feeds:
        missing.extend(_feed_gaps(f, required, names, forage=True))
    if rs.reference_body_weight_kg:
        if body_weight_kg is None:
            missing.append(_missing("body_weight_unknown", f"The animals' weight is not given; {rs.code} is for {rs.reference_body_weight_kg:g} kg."))
        elif abs(body_weight_kg - rs.reference_body_weight_kg) / rs.reference_body_weight_kg > WEIGHT_TOLERANCE:
            missing.append(_missing("body_weight_outside_set", f"{body_weight_kg:g} kg is not what {rs.code} is for ({rs.reference_body_weight_kg:g} kg): "
                                    "use the requirements for this weight."))

    ration_feeds: list[tuple[str, float | None, dict[str, float]]] = []  # (name, dm kg, dry values)
    if concentrate_kg_per_head is not None:
        conc_dm = concentrate_kg_per_head * (mix_dm_kg / total) if mix_dm_kg is not None and total else None
        ration_feeds.append((formula.name, conc_dm, mix_dry))
    for f in forage_feeds:
        ration_feeds.append((f.product.name, f.dm_kg, f.dry))
    dmi = sum(d for _, d, _ in ration_feeds) if ration_feeds and all(d is not None for _, d, _ in ration_feeds) else None
    complete = not missing
    nutrients = []
    gaps_text = []
    for rv in sorted(rs.values, key=lambda v: _order(db, v.nutrient_code)):
        code = rv.nutrient_code
        value = None
        contributions = []
        if dmi and all(code in vals for _, _, vals in ration_feeds):
            total_amount = sum(d * vals[code] for _, d, vals in ration_feeds)
            value = total_amount / dmi
            contributions = [{"name": name, "dm_kg": round(d, 3), "share_pct": round(d * vals[code] / total_amount * 100, 1) if total_amount else 0}
                             for name, d, vals in ration_feeds]
        if not complete or value is None:
            state = "insufficient_data"
        elif rv.min_value is not None and value < rv.min_value:
            state = "below"
        elif rv.max_value is not None and value > rv.max_value:
            state = "above"
        else:
            state = "met"
        label = names.get(code, code)
        if state in ("below", "above"):
            bound = rv.min_value if state == "below" else rv.max_value
            gaps_text.append(f"{label} is {value:.2f} {rv.unit} of the ration's dry matter, {state} the {bound:g} {rv.unit} "
                             f"{'minimum' if state == 'below' else 'maximum'}")
        nutrients.append({"nutrient_code": code, "name": label, "name_ar": (db.get(fm.FeedNutrient, code).name_ar if db.get(fm.FeedNutrient, code) else code),
                          "unit": rv.unit, "min_value": rv.min_value, "max_value": rv.max_value, "value": _r(value), "status": state,
                          "contributions": contributions})
    dmi_status = None
    if dmi is not None and rs.expected_dmi_kg:
        ratio = (dmi - rs.expected_dmi_kg) / rs.expected_dmi_kg
        dmi_status = "as_expected" if abs(ratio) <= DMI_TOLERANCE else ("below" if ratio < 0 else "above")
    ration = {"concentrate_kg_per_head": concentrate_kg_per_head, "forages": [{"feed_product_id": f.product.id, "name": f.product.name,
                                                                              "as_fed_kg": f.quantity_kg, "dm_pct": f.dm_pct, "profile": f.profile_dict()}
                                                                             for f in forage_feeds],
              "no_forage": no_forage, "body_weight_kg": body_weight_kg, "dry_matter_intake_kg": _r(dmi), "expected_dmi_kg": rs.expected_dmi_kg,
              "intake_status": dmi_status, "nutrients": nutrients}

    if not complete:
        status, recommendation = "insufficient_data", None
    elif gaps_text:
        status = "does_not_meet"
        recommendation = ("; ".join(gaps_text) + f" ({rs.code} v{rs.version}: {rs.source_reference}). This is an assessment, not a ration: "
                          "review it with the nutritionist before changing the formula or the feeding.")
    else:
        status = "meets"
        recommendation = (f"Every requirement of {rs.code} v{rs.version} is met on the analyses used. This is an assessment, not a ration: "
                          "it says nothing of the milk the cows will give.")

    inputs = {"formula_version_id": version.id, "requirement_set_id": rs.id, "premix": premix, "concentrate_kg_per_head": concentrate_kg_per_head,
              "forages": forages or [], "no_forage": no_forage, "body_weight_kg": body_weight_kg, "notes": (notes or "").strip() or None}
    result = {"mix": mix, "ration": ration, "missing": missing, "recommendation": recommendation,
              "requirement_set": {"id": rs.id, "code": rs.code, "version": rs.version, "name": rs.name, "species_code": rs.species_code,
                                  "production_stage": rs.production_stage, "source_type": rs.source_type, "source_reference": rs.source_reference}}
    a = nm.NutritionAssessment(id=new_id(), farm_id=user.farm_id, formula_version_id=version.id, requirement_set_id=rs.id, status=status,
                               premix_product_id=premix_feed.product.id if premix_feed else None, premix_quantity_kg=premix_feed.quantity_kg if premix_feed else None,
                               inputs=inputs, result=result, created_by=user.id, created_at=now())
    db.add(a)
    db.flush()
    write_event(db, farm_id=a.farm_id, entity_type="feed_formula_version", entity_id=version.id, event_type="nutrition_assessed",
                payload={"assessment_id": a.id, "status": status, "requirement_set": f"{rs.code} v{rs.version}", "missing": [m["code"] for m in missing]},
                created_by=user.id)
    write_audit_log(db, farm_id=a.farm_id, user_id=user.id, action="nutrition_assessed", entity_type="nutrition_assessment", entity_id=a.id, module_code=MODULE,
                    summary=f"{formula.name} v{version.version} against {rs.code} v{rs.version}: {status.replace('_', ' ')}"[:500])
    return a


def get_assessment(db: Session, assessment_id: str, farm_id: str) -> nm.NutritionAssessment:
    a = db.get(nm.NutritionAssessment, assessment_id)
    if a is None or a.farm_id != farm_id:
        raise NutritionError("Assessment not found", 404)
    return a


def list_assessments(db: Session, farm_id: str, *, formula_version_id: str | None = None, limit: int = 50) -> list[nm.NutritionAssessment]:
    stmt = select(nm.NutritionAssessment).where(nm.NutritionAssessment.farm_id == farm_id)
    if formula_version_id:
        stmt = stmt.where(nm.NutritionAssessment.formula_version_id == formula_version_id)
    return list(db.scalars(stmt.order_by(nm.NutritionAssessment.created_at.desc()).limit(limit)))


def assessment_dict(db: Session, a: nm.NutritionAssessment) -> dict:
    who = db.get(models.User, a.created_by) if a.created_by else None
    return {"id": a.id, "status": a.status, "formula_version_id": a.formula_version_id, "requirement_set_id": a.requirement_set_id,
            "created_at": ensure_utc(a.created_at).isoformat(), "created_by": a.created_by, "created_by_name": who.name if who else None,
            "inputs": a.inputs, **(a.result or {})}


