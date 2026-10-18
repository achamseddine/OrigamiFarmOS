"""Units of measure as references (FOUNDATION-SCHEMA uom).

`app/feeding/uom.py` is the conversion engine over the built-in
catalogue; this service is the authority on *which* unit codes exist for
a farm — the rows of `units_of_measure`, built-in plus the farm's own —
and converts through them, so a custom unit with a declared dimension
and factor converts like a built-in one. A unit a document names must
exist here: a medicine's strength, a lot's unit, a dose unit, a
requisition line's unit are references, never free text.
"""
from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import platform_models as plm
from app.feeding import uom
from app.platform.units import ensure_units
from app.repositories.base import write_event
from app.services.feed_inventory_service import FeedError


class UnitError(FeedError):
    """An unknown or incompatible unit."""


def normalise(code: str | None) -> str | None:
    if code is None:
        return None
    return uom.normalise(code)


def get(db: Session, code: str | None) -> plm.UnitOfMeasure | None:
    if code is None:
        return None
    return db.get(plm.UnitOfMeasure, normalise(code))


def require(db: Session, code: str | None, *, what: str = "unit") -> str:
    """The canonical code for `code`, or a refusal naming where to add it."""
    if code is None or not str(code).strip():
        raise UnitError(f"A {what} is required.")
    key = normalise(code)
    row = db.get(plm.UnitOfMeasure, key)
    if row is None:
        ensure_units(db)
        row = db.get(plm.UnitOfMeasure, key)
    if row is None or not row.active:
        raise UnitError(f"Unknown {what} '{code}'. Add it under Settings → Units of measure (GET/POST /units-of-measure) before using it.")
    return row.code


def optional(db: Session, code: str | None, *, what: str = "unit") -> str | None:
    return None if code is None or not str(code).strip() else require(db, code, what=what)


def compatible(db: Session, a: str | None, b: str | None) -> bool:
    ra, rb = get(db, a), get(db, b)
    if ra is None or rb is None:
        return uom.compatible(a, b)
    if ra.code == rb.code:
        return True
    # Units convert only inside a dimension that has a base unit; count
    # units (dose, sachet, bag) have none, so they never convert into
    # each other.
    return ra.dimension == rb.dimension and _base(ra) is not None and _base(ra) == _base(rb)


def _base(row: plm.UnitOfMeasure) -> str | None:
    return row.code if row.base_unit_code is None and row.dimension in ("mass", "volume", "time", "area") else row.base_unit_code


def convert(db: Session, quantity: float, from_unit: str | None, to_unit: str | None) -> float:
    ra, rb = get(db, from_unit), get(db, to_unit)
    if ra is None or rb is None:
        return uom.convert(quantity, from_unit, to_unit)
    if ra.code == rb.code:
        return quantity
    if not compatible(db, ra.code, rb.code):
        raise uom.IncompatibleUnits(f"cannot convert {ra.code} to {rb.code}")
    return quantity * (ra.factor_to_base or 1.0) / (rb.factor_to_base or 1.0)


def list_units(db: Session, *, include_inactive: bool = False) -> list[plm.UnitOfMeasure]:
    ensure_units(db)
    stmt = select(plm.UnitOfMeasure)
    if not include_inactive:
        stmt = stmt.where(plm.UnitOfMeasure.active.is_(True))
    return list(db.scalars(stmt.order_by(plm.UnitOfMeasure.dimension, plm.UnitOfMeasure.sort_order, plm.UnitOfMeasure.code)))


def create_unit(db: Session, *, code: str, name_en: str, name_ar: str | None, dimension: str, base_unit_code: str | None, factor_to_base: float,
                farm_id: str, user_id: str) -> plm.UnitOfMeasure:
    """A farm's own unit. Units are shared reference data (one catalogue),
    so adding one is a configure action and is written to the event log."""
    key = normalise(code)
    if not key or len(key) > 30:
        raise UnitError("A unit code is 1–30 characters.")
    if dimension not in plm.UOM_DIMENSIONS:
        raise UnitError(f"dimension must be one of {list(plm.UOM_DIMENSIONS)}")
    if db.get(plm.UnitOfMeasure, key) is not None:
        raise UnitError(f"Unit '{key}' already exists.")
    base = None
    if base_unit_code:
        base_row = db.get(plm.UnitOfMeasure, normalise(base_unit_code))
        if base_row is None or base_row.dimension != dimension:
            raise UnitError("The base unit must exist and be of the same dimension.")
        if factor_to_base <= 0:
            raise UnitError("factor_to_base must be greater than zero.")
        base = base_row.code
    row = plm.UnitOfMeasure(code=key, name_en=name_en.strip(), name_ar=name_ar, dimension=dimension, base_unit_code=base,
                            factor_to_base=factor_to_base if base else 1.0, active=True, sort_order=500)
    db.add(row)
    db.flush()
    write_event(db, farm_id=farm_id, entity_type="unit_of_measure", entity_id=key, event_type="unit_of_measure_created",
                payload={"code": key, "dimension": dimension, "base_unit_code": base, "factor_to_base": row.factor_to_base}, created_by=user_id)
    return row


def unit_dict(u: plm.UnitOfMeasure) -> dict:
    return {"code": u.code, "name_en": u.name_en, "name_ar": u.name_ar, "dimension": u.dimension, "base_unit_code": u.base_unit_code,
            "factor_to_base": u.factor_to_base, "active": u.active, "sort_order": u.sort_order}
