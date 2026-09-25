"""Reference data for the feed domain: the nutrient catalog.

Nutrients are rows, not columns (§8 of the feed architecture): a farm that
starts sending samples to a lab that reports lignin adds a row here — the
profile tables carry (nutrient, value, unit, basis) and never need a new
column. This is the set the demo farm ships with; `ensure_feed_reference_data`
upserts it and never deletes, so a farm's own additions survive a redeploy.
"""
from __future__ import annotations

import uuid

from sqlalchemy.orm import Session

from app.domain import feed_models as fm

# (code, name_en, name_ar, unit, category, sort_order)
NUTRIENTS: tuple[tuple[str, str, str, str, str, int], ...] = (
    ("DM", "Dry matter", "المادة الجافة", "%", "composition", 10),
    ("MOISTURE", "Moisture", "الرطوبة", "%", "composition", 11),
    ("CP", "Crude protein", "البروتين الخام", "%", "protein", 20),
    ("ME", "Metabolisable energy", "الطاقة الأيضية", "MJ/kg", "energy", 30),
    ("NEL", "Net energy for lactation", "طاقة الإدرار الصافية", "MJ/kg", "energy", 31),
    ("NDF", "Neutral detergent fibre", "الألياف NDF", "%", "fibre", 40),
    ("ADF", "Acid detergent fibre", "الألياف ADF", "%", "fibre", 41),
    ("CF", "Crude fibre", "الألياف الخام", "%", "fibre", 42),
    ("FAT", "Crude fat", "الدهون الخام", "%", "fat", 50),
    ("ASH", "Ash", "الرماد", "%", "minerals", 60),
    ("CA", "Calcium", "الكالسيوم", "%", "minerals", 61),
    ("P", "Phosphorus", "الفوسفور", "%", "minerals", 62),
    ("NA", "Sodium", "الصوديوم", "%", "minerals", 63),
    ("MG", "Magnesium", "المغنيسيوم", "%", "minerals", 64),
    ("VIT_A", "Vitamin A", "فيتامين أ", "IU/kg", "vitamins", 70),
    ("VIT_D", "Vitamin D", "فيتامين د", "IU/kg", "vitamins", 71),
    ("VIT_E", "Vitamin E", "فيتامين هـ", "mg/kg", "vitamins", 72),
)

# Values are stored as-fed or on a dry-matter basis; the profile says which.
BASES = ("as_fed", "dry_matter")
PROFILE_SOURCES = ("declared", "calculated", "lab")
PROFILE_SUBJECTS = ("feed_product", "formula_version", "feed_lot", "feed_batch")

# Assignment kinds (§9). `inherited` is never stored — it is what an animal
# gets from its group when it has no explicit assignment of its own.
ASSIGNMENT_TYPES = ("explicit", "supplement", "override", "restriction")
SUBJECT_TYPES = ("animal", "group")
FEEDING_EVENT_TYPES = ("offered", "delivered", "consumed_estimate", "refusal")
LOT_STATUSES = ("active", "quarantined", "blocked", "recalled", "expired", "depleted")
# Lot states that make stock unusable without an authorised exception (§16).
LOT_UNUSABLE = ("quarantined", "blocked", "recalled", "expired")
POLICY_EFFECTS = ("allow", "block", "limit")
PRODUCT_SOURCES = ("purchased", "farm_produced")


def ensure_feed_reference_data(db: Session) -> None:
    """Idempotent upsert of the nutrient catalog."""
    for code, name_en, name_ar, unit, category, sort_order in NUTRIENTS:
        row = db.get(fm.FeedNutrient, code)
        if row is None:
            db.add(fm.FeedNutrient(code=code, name_en=name_en, name_ar=name_ar, unit=unit, category=category, sort_order=sort_order))
        else:
            row.name_en, row.name_ar, row.unit, row.category, row.sort_order = name_en, name_ar, unit, category, sort_order
    db.flush()


def nutrient_rows() -> list[dict]:
    """The catalog as plain dicts, for the migration's bulk insert."""
    return [
        {"code": code, "name_en": name_en, "name_ar": name_ar, "unit": unit, "category": category, "sort_order": sort_order}
        for code, name_en, name_ar, unit, category, sort_order in NUTRIENTS
    ]


def new_id() -> str:
    return str(uuid.uuid4())
