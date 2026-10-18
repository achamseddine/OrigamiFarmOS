"""The conversion engine for units of measure.

Quantities carry a unit code (`kg`, `items`, `l`) that is a row of
`units_of_measure` (`app/platform/units.py` is the built-in catalogue;
`services/uom_service.py` resolves a farm's own rows). This module is the
conversion arithmetic those codes resolve against: a quantity is only
ever added to, or compared with, another in the same *family*, and a
formula authored in tonnes still consumes stock kept in kilograms.
Anything outside the catalog is treated as its own family with no
conversions, so an unknown unit can never be silently mistaken for a
known one.
"""
from __future__ import annotations

# unit -> (family, factor to the family's base unit)
_UNITS: dict[str, tuple[str, float]] = {
    "mg": ("mass", 0.000001),
    "g": ("mass", 0.001),
    "kg": ("mass", 1.0),
    "t": ("mass", 1000.0),
    "lb": ("mass", 0.45359237),
    "ml": ("volume", 0.001),
    "l": ("volume", 1.0),
    "items": ("count", 1.0),
    "head": ("count", 1.0),
    "bale": ("count", 1.0),
    "bag": ("count", 1.0),
    "hour": ("time", 1 / 24),
    "minute": ("time", 1 / 1440),
    "day": ("time", 1.0),
    "ha": ("area", 10.0),
    "dunum": ("area", 1.0),
}

_ALIASES = {
    "kgs": "kg", "kilogram": "kg", "kilograms": "kg",
    "gram": "g", "grams": "g", "milligram": "mg", "milligrams": "mg",
    "ton": "t", "tonne": "t", "tonnes": "t", "mt": "t",
    "lbs": "lb", "pound": "lb", "pounds": "lb",
    "liter": "l", "liters": "l", "litre": "l", "litres": "l",
    "milliliter": "ml", "millilitre": "ml", "cc": "ml",
    "item": "items", "unit": "items", "units": "items", "pcs": "items",
    "bales": "bale", "bags": "bag", "doses": "dose", "sachets": "sachet", "tubes": "tube", "tablets": "tablet", "vials": "vial",
    "bottles": "bottle", "packs": "pack",
    "iu/ml": "iu/ml", "iu": "iu", "percent": "%", "pct": "%",
    "hours": "hour", "minutes": "minute", "min": "minute", "days": "day", "hectare": "ha", "hectares": "ha", "dunums": "dunum",
}


class IncompatibleUnits(ValueError):
    """Raised when a conversion crosses families — kilograms to litres."""


def normalise(unit: str | None) -> str:
    code = (unit or "kg").strip().lower()
    return _ALIASES.get(code, code)


def family(unit: str | None) -> str:
    code = normalise(unit)
    return _UNITS.get(code, (code, 1.0))[0]


def compatible(a: str | None, b: str | None) -> bool:
    return family(a) == family(b)


def convert(quantity: float, from_unit: str | None, to_unit: str | None) -> float:
    """Converts within a family; raises [IncompatibleUnits] across them."""
    src, dst = normalise(from_unit), normalise(to_unit)
    if src == dst:
        return quantity
    if family(src) != family(dst):
        raise IncompatibleUnits(f"cannot convert {src} to {dst}")
    factor_src = _UNITS.get(src, (src, 1.0))[1]
    factor_dst = _UNITS.get(dst, (dst, 1.0))[1]
    return quantity * factor_src / factor_dst


def describe(unit: str | None) -> str:
    """The unit as the farm writes it: `kg`, `L`, `items`."""
    code = normalise(unit)
    return "L" if code == "l" else code
