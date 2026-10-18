"""The one list of ORM modules.

Every table must be registered on `Base.metadata` before anything reads
it as a whole — `create_all` at startup, Alembic autogenerate, the
PostgreSQL DDL export, the migration parity test. Each of those used to
carry its own import list and they drifted (a module missing from one of
them is a table that silently never gets a migration or never appears in
the rendered schema). They all call `import_all()` now.
"""
from __future__ import annotations

import importlib
from types import ModuleType

MODEL_MODULES: tuple[str, ...] = (
    "app.domain.models",             # farm, users, permissions, animals/flocks, milk, eggs, health, inventory, tasks, events, idempotency
    "app.domain.livestock_models",   # species, breeds, life stages, management profiles, capability rules, identifiers, animal groups
    "app.domain.feed_models",        # feed products, lots, formulas, numbered mixes, programs, feeding events, forecasts, performance intelligence
    "app.domain.mouneh_models",      # Mouneh module
    "app.domain.visits_models",      # Farm visits & agri-tourism module
    "app.domain.pharmacy_models",    # medicine products, inventory lots, reservations, pharmacy policies and alerts, administrations
    "app.domain.emergency_models",   # emergency protocols, versions, assessments, runs
    "app.domain.platform_models",    # units of measure, farm assets, notification routes, scheduled job runs
    "app.domain.health_models",      # health cases, diagnoses, treatment plans, conditions, weight records
    "app.domain.procurement_models", # purchase requisitions, lines, approvals
)


def import_all() -> list[ModuleType]:
    """Import every ORM module so `Base.metadata` holds the whole schema."""
    return [importlib.import_module(name) for name in MODEL_MODULES]
