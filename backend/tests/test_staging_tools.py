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


# --- the backup tools must be the server's own major version ------------------
def _fake_tool(folder, name: str, version: str):
    folder.mkdir(parents=True, exist_ok=True)
    tool = folder / name
    tool.write_text(f"#!/bin/sh\necho '{name} (PostgreSQL) {version}'\n")
    tool.chmod(0o755)
    return tool


def test_a_newer_pg_dump_is_never_used_on_an_older_server(tmp_path):
    """pg_dump 17 writes `SET transaction_timeout` into the dump, which a
    PostgreSQL 16 server refuses on restore (the CI failure on PR #38)."""
    from app.staging import pg_tools

    newer, same = tmp_path / "pg17", tmp_path / "pg16"
    for name in ("pg_dump", "pg_restore"):
        _fake_tool(newer, name, "17.2 (Ubuntu 17.2-1.pgdg24.04+1)")
        _fake_tool(same, name, "16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)")
    # The newer tools come first on the PATH; the server's own are found anyway.
    found = pg_tools.find(16, search=[str(newer), str(same)])
    assert found == {"pg_dump": str(same / "pg_dump"), "pg_restore": str(same / "pg_restore")}
    # Only newer tools: refused, saying which versions were seen.
    with pytest.raises(pg_tools.ToolsMissing) as err:
        pg_tools.find(16, search=[str(newer)])
    assert "16" in str(err.value) and "17" in str(err.value)
    # The server's major on a standard Debian/Ubuntu layout comes before the PATH.
    assert pg_tools.candidate_dirs(16, path="/usr/bin")[:1] == ["/usr/lib/postgresql/16/bin"]
