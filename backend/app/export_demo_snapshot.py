"""Builds the tablet's standalone demo dataset.

The tablet app can run with no server at all: it ships an on-device
SQLite database pre-loaded with a whole farm, signs in locally, and lets
someone add animals, record a harvest or take a booking exactly as they
would against the real backend. This script produces the dataset that
build starts from.

Rather than hand-authoring fixture JSON — which drifts from the API the
moment a schema changes — it seeds a throwaway database with the same
demo data the backend already ships, starts the real app in-process, and
records the genuine response of every endpoint the tablet reads. The
snapshot is therefore correct by construction: every field the Dart
entities parse is present, and in the shape the server would really send.

    python -m app.export_demo_snapshot

Writes `mobile/flutter_app/assets/demo/snapshot.json`, a map of
`"GET <path>?<sorted query>"` to the response body, matching the cache
keys `LocalStore.cacheKey` builds on the tablet.
"""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from app.core.security import hash_password
from app.db.base import Base, get_db
from app.domain import models
from app.domain import mouneh_models  # noqa: F401 - registers Mouneh tables
from app.domain import visits_models  # noqa: F401 - registers Visits tables
from app.main import app
from app.seed import FARM_ID, seed_demo_data

# The one account the standalone build signs in as. A demo credential,
# not a security boundary: the tablet checks it locally because there is
# no server to ask. See mobile/flutter_app/lib/data/local/demo_mode.dart.
DEMO_USERNAME = "ali"
DEMO_EMAIL = "ali@origamifarms.com"
DEMO_PASSWORD = "ali123"
DEMO_NAME = "Ali"
DEMO_USER_ID = "user-ali-demo"

OUTPUT = Path(__file__).resolve().parents[2] / "mobile" / "flutter_app" / "assets" / "demo" / "snapshot.json"


def _cache_key(path: str, query: dict | None = None) -> str:
    """Mirrors `LocalStore.cacheKey` on the tablet — same key, same sort."""
    if not query:
        return f"GET {path}"
    parts = sorted(f"{k}={_qs(v)}" for k, v in query.items() if v is not None)
    return f"GET {path}?{'&'.join(parts)}" if parts else f"GET {path}"


def _qs(value) -> str:
    # Dart's `.toString()` on a bool gives "true"/"false", same as Python's
    # lowercase form — but Python's bool str() is "True", so map explicitly.
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def _seed(db: Session) -> None:
    seed_demo_data(db)
    db.add(
        models.User(
            id=DEMO_USER_ID,
            farm_id=FARM_ID,
            name=DEMO_NAME,
            email=DEMO_EMAIL,
            password_hash=hash_password(DEMO_PASSWORD),
            # Owner, so the demo shows the whole farm and every "Add"
            # button — the point of the standalone build is to let someone
            # walk through all of it.
            role="owner",
            language="en",
            job_title="Farm Owner",
        )
    )
    db.commit()


def _requests(db: Session) -> list[tuple[str, dict | None]]:
    """Every GET the tablet makes, including the per-record detail calls."""
    animal_ids = [a.id for a in db.query(models.Animal).all()]
    product_ids = [p.id for p in db.query(mouneh_models.MounehProduct).all()]
    farm = {"farm_id": FARM_ID}

    paths: list[tuple[str, dict | None]] = [
        ("/auth/me", None),
        ("/me/access", None),
        ("/modules/catalog", None),
        ("/modules", None),
        ("/modules/visits/status", None),
        ("/farms/me", None),
        ("/users", None),
        ("/employees", {"include_inactive": False}),
        ("/employees", {"include_inactive": True}),
        ("/notifications", None),
        ("/priorities", None),
        ("/morning-briefing", farm),
        ("/tasks", farm),
        ("/animals", farm),
        ("/health/treatments", farm),
        ("/recommendations", {**farm, "refresh": True}),
        ("/feed/items", farm),
        ("/production/fields", farm),
        ("/production/milk", {**farm, "days": 30}),
        ("/production/eggs", {**farm, "days": 30}),
        ("/production/harvest", {**farm, "days": 90}),
        ("/crops", None),
        ("/crop-plantings", None),
        ("/sales", farm),
        ("/expenses", farm),
        ("/reports/daily-summary", farm),
        ("/audit", {"limit": 100}),
        ("/mouneh/products", None),
        ("/mouneh/raw-materials", None),
        ("/mouneh/batches", None),
        ("/mouneh/finished-goods", None),
        ("/mouneh/sales", None),
        ("/visit-calendar", None),
        ("/visit-sessions", None),
        ("/visit-packages", None),
        ("/visit-activities", None),
        ("/visit-bookings", None),
        ("/visit-staff-roster", None),
        ("/visit-costs", None),
        ("/visit-retail-sales", None),
        ("/visit-incidents", None),
        ("/visitor-feedback", None),
        ("/visitors", None),
    ]
    paths += [(f"/animals/{animal_id}", None) for animal_id in animal_ids]
    paths += [(f"/mouneh/products/{product_id}", None) for product_id in product_ids]
    return paths


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        engine = create_engine(f"sqlite:///{Path(tmp) / 'snapshot.db'}", connect_args={"check_same_thread": False})
        Base.metadata.create_all(bind=engine)
        SessionFactory = sessionmaker(autocommit=False, autoflush=False, bind=engine)

        db = SessionFactory()
        _seed(db)

        def _override_get_db():
            session = SessionFactory()
            try:
                yield session
            finally:
                session.close()

        app.dependency_overrides[get_db] = _override_get_db
        snapshot: dict[str, object] = {}
        missing: list[str] = []

        try:
            with TestClient(app) as client:
                login = client.post("/api/v1/auth/login", json={"email": DEMO_EMAIL, "password": DEMO_PASSWORD})
                if login.status_code != 200:
                    print(f"Demo login failed: {login.status_code} {login.text}", file=sys.stderr)
                    return 1
                headers = {"Authorization": f"Bearer {login.json()['access_token']}"}

                for path, query in _requests(db):
                    response = client.get(f"/api/v1{path}", params=query, headers=headers)
                    if response.status_code != 200:
                        missing.append(f"{path} -> {response.status_code} {response.text[:140]}")
                        continue
                    snapshot[_cache_key(path, query)] = response.json()
        finally:
            app.dependency_overrides.clear()
            db.close()

    # The demo account is the one thing the tablet needs that no endpoint
    # returns: the profile to sign in as, since there is no server to ask.
    snapshot["__demo_account__"] = {
        "username": DEMO_USERNAME,
        "password": DEMO_PASSWORD,
        "user": snapshot.get(_cache_key("/auth/me")),
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(snapshot, indent=1, sort_keys=True), encoding="utf-8")

    size_kb = OUTPUT.stat().st_size / 1024
    print(f"Wrote {len(snapshot) - 1} endpoint responses to {OUTPUT} ({size_kb:.0f} KB)")
    if missing:
        print(f"\n{len(missing)} endpoint(s) did not return 200 and are absent from the snapshot:", file=sys.stderr)
        for line in missing:
            print(f"  {line}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
