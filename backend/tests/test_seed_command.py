"""`python -m app.seed` works as the README and the staging chain run it
(Package 6 finding): as a script, not only imported by the tests.

The command's `if __name__ == "__main__"` block sat above a helper the
seed calls, so running it as a script failed with NameError after the
reference data and before the farm: an empty farm nobody could sign in to,
while every test (importing the module) passed.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from sqlalchemy import create_engine, text

BACKEND_DIR = Path(__file__).resolve().parents[1]


def test_the_seed_command_builds_the_demo_farm_and_can_run_twice(tmp_path):
    url = f"sqlite:///{tmp_path / 'seeded.db'}"
    env = {**os.environ, "DATABASE_URL": url, "FARMOS_SCHEDULER": "false"}
    first = subprocess.run([sys.executable, "-m", "app.seed"], cwd=BACKEND_DIR, env=env, capture_output=True, text=True, timeout=600)
    assert first.returncode == 0, first.stderr[-2000:]
    assert "Demo login: rami@origami.farm" in first.stdout
    engine = create_engine(url)
    with engine.connect() as conn:
        assert conn.execute(text("SELECT count(*) FROM users WHERE email = 'rami@origami.farm'")).scalar() == 1
        assert conn.execute(text("SELECT count(*) FROM animals")).scalar() > 0
    engine.dispose()
    again = subprocess.run([sys.executable, "-m", "app.seed"], cwd=BACKEND_DIR, env=env, capture_output=True, text=True, timeout=600)
    assert again.returncode == 0, again.stderr[-2000:]
    assert "already present" in again.stdout
