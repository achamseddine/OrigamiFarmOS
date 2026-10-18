"""The units-of-measure catalogue (FOUNDATION-SCHEMA uom / uom_dimension).

Units are rows, not an enum: a farm that buys a medicine in 250 mL
bottles adds "bottle" under Settings → Units and every receipt, policy
and dose can use it. The rows here are what every farm ships with;
`ensure_units` upserts them and never deletes, so a farm's own units
survive a redeploy, and `migration_rows` gives the Alembic migration the
same data without depending on the ORM.

Conversions: units of one dimension that name a base unit convert
through their factor (g → kg, ml → l). Count-like units (dose, sachet,
bag, head) deliberately carry no base: a sachet is never silently a dose.
"""
from __future__ import annotations

from sqlalchemy.orm import Session

from app.domain import platform_models as plm

# (code, name_en, name_ar, dimension, base_unit_code, factor_to_base, sort_order)
UNITS: tuple[tuple[str, str, str, str, str | None, float, int], ...] = (
    # mass
    ("kg", "Kilogram", "كيلوغرام", "mass", None, 1.0, 10),
    ("g", "Gram", "غرام", "mass", "kg", 0.001, 11),
    ("mg", "Milligram", "ميليغرام", "mass", "kg", 0.000001, 12),
    ("t", "Tonne", "طن", "mass", "kg", 1000.0, 13),
    ("lb", "Pound", "رطل", "mass", "kg", 0.45359237, 14),
    # volume
    ("l", "Litre", "لتر", "volume", None, 1.0, 20),
    ("ml", "Millilitre", "ميليلتر", "volume", "l", 0.001, 21),
    # count-like: each its own family, no cross conversion
    ("items", "Items", "قطع", "count", None, 1.0, 30),
    ("head", "Head", "رأس", "count", None, 1.0, 31),
    ("bale", "Bale", "بالة", "count", None, 1.0, 32),
    ("bag", "Bag", "كيس", "count", None, 1.0, 33),
    ("dose", "Dose", "جرعة", "count", None, 1.0, 34),
    ("sachet", "Sachet", "ظرف", "count", None, 1.0, 35),
    ("tube", "Tube", "أنبوب", "count", None, 1.0, 36),
    ("tablet", "Tablet", "قرص", "count", None, 1.0, 37),
    ("bolus", "Bolus", "بلعة", "count", None, 1.0, 38),
    ("vial", "Vial", "قارورة", "count", None, 1.0, 39),
    ("bottle", "Bottle", "زجاجة", "count", None, 1.0, 40),
    ("pack", "Pack", "عبوة", "count", None, 1.0, 41),
    ("dozen", "Dozen", "دزينة", "count", None, 1.0, 42),
    # concentration / strength
    ("mg/ml", "Milligram per millilitre", "ملغ/مل", "concentration", None, 1.0, 50),
    ("iu/ml", "International units per millilitre", "وحدة دولية/مل", "concentration", None, 1.0, 51),
    ("%", "Percent", "بالمئة", "concentration", None, 1.0, 52),
    ("mg/g", "Milligram per gram", "ملغ/غ", "concentration", None, 1.0, 53),
    ("g/l", "Gram per litre", "غ/ل", "concentration", None, 1.0, 54),
    ("iu", "International units", "وحدة دولية", "concentration", None, 1.0, 55),
    # dose rates (per kilogram live weight)
    ("mg/kg", "Milligram per kilogram", "ملغ/كغ", "dose_rate", None, 1.0, 60),
    ("ml/kg", "Millilitre per kilogram", "مل/كغ", "dose_rate", None, 1.0, 61),
    ("iu/kg", "International units per kilogram", "وحدة دولية/كغ", "dose_rate", None, 1.0, 62),
    # energy
    ("mj", "Megajoule", "ميغاجول", "energy", None, 1.0, 70),
    ("mj/kg", "Megajoule per kilogram", "ميغاجول/كغ", "energy", None, 1.0, 71),
    # time
    ("day", "Day", "يوم", "time", None, 1.0, 80),
    ("hour", "Hour", "ساعة", "time", "day", 1 / 24, 81),
    ("minute", "Minute", "دقيقة", "time", "day", 1 / 1440, 82),
    # area
    ("dunum", "Dunum", "دونم", "area", None, 1.0, 90),
    ("ha", "Hectare", "هكتار", "area", "dunum", 10.0, 91),
)

UNIT_CODES = tuple(u[0] for u in UNITS)


def migration_rows() -> list[dict]:
    return [
        {"code": code, "name_en": name_en, "name_ar": name_ar, "dimension": dimension, "base_unit_code": base, "factor_to_base": factor,
         "active": True, "sort_order": sort_order}
        for code, name_en, name_ar, dimension, base, factor, sort_order in UNITS
    ]


def ensure_units(db: Session) -> None:
    """Idempotent upsert of the catalogue; a farm's own units are left alone."""
    for code, name_en, name_ar, dimension, base, factor, sort_order in UNITS:
        row = db.get(plm.UnitOfMeasure, code)
        if row is None:
            db.add(plm.UnitOfMeasure(code=code, name_en=name_en, name_ar=name_ar, dimension=dimension, base_unit_code=base,
                                     factor_to_base=factor, active=True, sort_order=sort_order))
        else:
            row.name_en, row.name_ar, row.dimension, row.base_unit_code, row.factor_to_base, row.sort_order = name_en, name_ar, dimension, base, factor, sort_order
    db.flush()
