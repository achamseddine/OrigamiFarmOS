"""The committed, generated files match the code they are generated from.

`database/schema.sql` is rendered from the ORM metadata and
`api/openapi.yaml` from the FastAPI application. Either going stale is a
documentation bug a reader cannot see; these tests make it a failing
build with the one-line fix in the message.
"""
from __future__ import annotations

from pathlib import Path

from app import export_openapi, export_schema
from app.db.base import Base
from app.domain.registry import MODEL_MODULES, import_all

REPO_ROOT = Path(__file__).resolve().parents[2]


def _first_difference(a: str, b: str) -> str:
    a_lines, b_lines = a.splitlines(), b.splitlines()
    for i, (x, y) in enumerate(zip(a_lines, b_lines), start=1):
        if x != y:
            return f"line {i}: committed {x!r} / generated {y!r}"
    return f"committed has {len(a_lines)} lines, generated has {len(b_lines)}"


def test_schema_sql_is_rendered_from_the_current_models():
    committed = (REPO_ROOT / "database" / "schema.sql").read_text(encoding="utf-8")
    generated = export_schema.render()
    assert committed == generated, (
        "database/schema.sql is stale — run `cd backend && python -m app.export_schema`. First difference: "
        + _first_difference(committed, generated)
    )


def test_schema_sql_covers_every_orm_table_with_postgresql_types():
    import_all()
    text = export_schema.render()
    assert text.count("\nCREATE TABLE ") == len(Base.metadata.tables), "one CREATE TABLE per mapped table"
    for table in Base.metadata.tables:
        assert f"CREATE TABLE {table} (" in text, table
    # The PostgreSQL dialect, not SQLite's: timezone-aware timestamps and real booleans.
    assert "TIMESTAMP WITH TIME ZONE" in text and "BOOLEAN" in text and "VARCHAR(36)" in text
    assert "DATETIME" not in text
    # The indexes the migrations create are part of the rendered shape.
    assert "CREATE INDEX ix_feeding_events_subject ON feeding_events" in text
    assert "CREATE INDEX ix_health_cases_subject ON health_cases" in text
    assert "CONSTRAINT uq_feed_batch_farm_mix_number UNIQUE (farm_id, mix_number)" in text
    assert "GENERATED FILE" in text.splitlines()[2]


def test_every_domain_module_is_registered():
    """A model module missing from the registry is a table with no
    migration, no DDL and no parity check — the list must name them all."""
    domain_dir = REPO_ROOT / "backend" / "app" / "domain"
    on_disk = {f"app.domain.{p.stem}" for p in domain_dir.glob("*_models.py")} | {"app.domain.models"}
    assert on_disk == set(MODEL_MODULES), on_disk ^ set(MODEL_MODULES)


def test_openapi_export_is_the_application_contract():
    committed = (REPO_ROOT / "api" / "openapi.yaml").read_text(encoding="utf-8")
    generated = export_openapi.render()
    assert committed == generated, (
        "api/openapi.yaml is stale — run `cd backend && python -m app.export_openapi`. First difference: "
        + _first_difference(committed, generated)
    )


def test_openapi_export_names_the_new_modules():
    spec = export_openapi.app.openapi()
    paths = set(spec["paths"])
    for p in ("/api/v1/units-of-measure", "/api/v1/assets", "/api/v1/notification-routes/{route_code}", "/api/v1/scheduler/run",
              "/api/v1/health/cases/{case_id}/diagnoses", "/api/v1/animals/{animal_id}/weights", "/api/v1/procurement/requisitions/{requisition_id}/approve",
              "/api/v1/pharmacy/reservations", "/api/v1/pharmacy/transfers", "/api/v1/emergency/offline-runs", "/api/v1/feed-mix-settings",
              "/api/v1/feed-performance/effective-feed-value", "/api/v1/feed-performance/ingredient-lots"):
        assert p in paths, p
    assert spec["openapi"].startswith("3.1")
