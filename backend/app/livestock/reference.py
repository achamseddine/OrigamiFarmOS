"""Loads the catalog into a database, idempotently.

Two callers, one source of truth:

* `ensure_reference_data(db)` — the dev seed and the production seed,
  through the ORM. Safe to run on every start: rows that exist are
  updated to the catalog's current labels, rows that don't are added,
  nothing is deleted (a farm may have added its own species or rules,
  and those are theirs).
* `migration_rows()` — the Alembic migration, which inserts the same data
  with plain `op.bulk_insert` because a migration must not depend on the
  ORM models matching the schema at that point in history.
"""
from __future__ import annotations

import uuid

from sqlalchemy.orm import Session

from app.domain import livestock_models as lm
from app.livestock import catalog


def _rule_key(r: dict) -> tuple:
    return (r["species_code"], r["capability_code"], r["sex"], r["life_stage"], r["management_profile"])


def ensure_reference_data(db: Session) -> None:
    for row in catalog.SPECIES:
        species = db.get(lm.Species, row["code"])
        if species is None:
            db.add(lm.Species(**row))
        else:
            for k, v in row.items():
                if k != "code":
                    setattr(species, k, v)
    db.flush()

    for code, species_code, label_en, label_ar, sort in catalog.LIFE_STAGES:
        stage = db.get(lm.LifeStage, code)
        if stage is None:
            db.add(lm.LifeStage(code=code, species_code=species_code, label_en=label_en, label_ar=label_ar, sort_order=sort))
        else:
            stage.label_en, stage.label_ar, stage.sort_order = label_en, label_ar, sort

    for code, species_code, label_en, label_ar in catalog.MANAGEMENT_PROFILES:
        profile = db.get(lm.ManagementProfile, code)
        if profile is None:
            db.add(lm.ManagementProfile(code=code, species_code=species_code, label_en=label_en, label_ar=label_ar))
        else:
            profile.label_en, profile.label_ar = label_en, label_ar

    for code, category, label_en, label_ar in catalog.CAPABILITIES:
        cap = db.get(lm.Capability, code)
        if cap is None:
            db.add(lm.Capability(code=code, category=category, label_en=label_en, label_ar=label_ar, active=True))
        else:
            cap.category, cap.label_en, cap.label_ar = category, label_en, label_ar
    db.flush()

    existing_breeds = {(b.species_code, b.name) for b in db.query(lm.Breed).all()}
    for species_code, name, name_ar in catalog.BREEDS:
        if (species_code, name) not in existing_breeds:
            db.add(lm.Breed(species_code=species_code, name=name, name_ar=name_ar))

    existing_rules = {
        _rule_key({
            "species_code": r.species_code, "capability_code": r.capability_code,
            "sex": r.sex, "life_stage": r.life_stage, "management_profile": r.management_profile,
        }): r
        for r in db.query(lm.SpeciesCapabilityRule).all()
    }
    for row in catalog.RULES:
        current = existing_rules.get(_rule_key(row))
        if current is None:
            db.add(lm.SpeciesCapabilityRule(**row))
        else:
            current.enabled = row["enabled"]
            current.required = row["required"]
            current.configuration_json = row["configuration_json"]
            current.priority = row["priority"]
    db.flush()


def migration_rows() -> dict[str, list[dict]]:
    """The catalog as plain dicts keyed by table, ids generated here so the
    migration is one bulk insert per table."""
    return {
        "species": [dict(r) for r in catalog.SPECIES],
        "life_stages": [
            {"code": c, "species_code": s, "label_en": en, "label_ar": ar, "sort_order": o}
            for c, s, en, ar, o in catalog.LIFE_STAGES
        ],
        "management_profiles": [
            {"code": c, "species_code": s, "label_en": en, "label_ar": ar}
            for c, s, en, ar in catalog.MANAGEMENT_PROFILES
        ],
        "capabilities": [
            {"code": c, "category": cat, "label_en": en, "label_ar": ar, "active": True}
            for c, cat, en, ar in catalog.CAPABILITIES
        ],
        "breeds": [
            {"id": str(uuid.uuid4()), "species_code": s, "name": n, "name_ar": ar, "active": True}
            for s, n, ar in catalog.BREEDS
        ],
        "species_capability_rules": [{"id": str(uuid.uuid4()), **r} for r in catalog.RULES],
    }
