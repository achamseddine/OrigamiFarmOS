"""Exports the OpenAPI 3.1 contract to `api/openapi.yaml`.

The contract is whatever the FastAPI application serves at /openapi.json;
the committed YAML is that document, so an API client, the tablet team or
a reviewer can read the contract from the repository without running the
server. `tests/test_generated_artifacts.py` fails when the committed file
no longer matches the application, so a new endpoint or a changed schema
cannot ship without the contract moving with it.

    cd backend && python -m app.export_openapi          # rewrite the file
    cd backend && python -m app.export_openapi --check  # exit 1 if it is stale
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import yaml

# Importing the application must not start the background scheduler.
os.environ.setdefault("FARMOS_SCHEDULER", "false")

from app.main import app  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
OPENAPI_PATH = REPO_ROOT / "api" / "openapi.yaml"


def render() -> str:
    """The contract as YAML, keys in the order FastAPI emits them so a
    diff reads as the change it is."""
    spec = app.openapi()
    return yaml.safe_dump(spec, sort_keys=False, allow_unicode=True, width=100)


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    text = render()
    if "--check" in args:
        current = OPENAPI_PATH.read_text(encoding="utf-8") if OPENAPI_PATH.exists() else ""
        if current != text:
            print(f"{OPENAPI_PATH.relative_to(REPO_ROOT)} is stale; run `python -m app.export_openapi`.", file=sys.stderr)
            return 1
        print(f"{OPENAPI_PATH.relative_to(REPO_ROOT)} is current.")
        return 0
    OPENAPI_PATH.write_text(text, encoding="utf-8")
    spec = app.openapi()
    print(f"Wrote {OPENAPI_PATH.relative_to(REPO_ROOT)} ({len(spec['paths'])} paths, {len(spec['components']['schemas'])} schemas).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
