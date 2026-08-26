from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.db.base import Base, get_db
from app.domain import models  # noqa: F401 - ensures all tables are registered on Base
from app.main import app
from tests.sample_data import seed_test_data


@pytest.fixture()
def db_session(tmp_path):
    db_path = tmp_path / "test.db"
    engine = create_engine(f"sqlite:///{db_path}", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

    session = TestingSessionLocal()
    seed_test_data(session)
    session.commit()

    try:
        yield session, TestingSessionLocal
    finally:
        session.close()


@pytest.fixture()
def client(db_session):
    session, session_factory = db_session

    def _override_get_db():
        db = session_factory()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = _override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.clear()


def login(client: TestClient, email: str = "rami@origami.farm", password: str = "farmos123") -> str:
    r = client.post("/api/v1/auth/login", json={"email": email, "password": password})
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


def auth_headers(client: TestClient, email: str = "rami@origami.farm", password: str = "farmos123") -> dict:
    token = login(client, email, password)
    return {"Authorization": f"Bearer {token}"}
