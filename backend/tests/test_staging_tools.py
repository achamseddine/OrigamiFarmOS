"""The staging tools' own guards (master prompt Package 6): the smoke test
writes synthetic records, so it only talks to a staging server; a restore
is compared with its backup table by table."""
from __future__ import annotations

import pytest

from app.staging import smoke, snapshot


def test_the_smoke_test_only_talks_to_a_staging_server():
    for ok in ("http://127.0.0.1:8770/api/v1", "http://localhost:8000/api/v1", "http://api:8000/api/v1"):
        smoke.ensure_staging(ok)
    smoke.ensure_staging("https://origami-staging.example.org/api/v1", allow_remote_staging=True)
    for refused in ("https://farm.example.org/api/v1", "https://leb-container-test.azurewebsites.net/api/v1"):
        with pytest.raises(smoke.NotStaging):
            smoke.ensure_staging(refused, allow_remote_staging=True)
    with pytest.raises(smoke.NotStaging):
        smoke.ensure_staging("https://origami-staging.example.org/api/v1")


def test_a_restore_that_lost_or_changed_rows_is_named():
    backup = {"tables": {"animals": {"rows": 12, "md5": "a"}, "milk_records": {"rows": 300, "md5": "b"}}, "alembic": ["a3c5e7f9b1d2"]}
    same = {"tables": {"animals": {"rows": 12, "md5": "a"}, "milk_records": {"rows": 300, "md5": "b"}}, "alembic": ["a3c5e7f9b1d2"]}
    assert snapshot.differences(backup, same) == []
    lost = {"tables": {"animals": {"rows": 12, "md5": "a"}, "milk_records": {"rows": 299, "md5": "c"}}, "alembic": ["a3c5e7f9b1d2"]}
    assert [d.split(":")[0] for d in snapshot.differences(backup, lost)] == ["milk_records"]
    older = {"tables": dict(backup["tables"]), "alembic": ["e8a0c2e4b6d9"]}
    assert snapshot.differences(backup, older) and "alembic_version" in snapshot.differences(backup, older)[0]
