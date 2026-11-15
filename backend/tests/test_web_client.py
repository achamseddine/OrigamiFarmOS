"""The farm server serves the browser version of the app at /app/, beside
its API (app/web_client.py, architecture/ADR-004-WEB-CLIENT.md)."""
from __future__ import annotations

import pytest


@pytest.fixture()
def web_app(tmp_path, monkeypatch):
    (tmp_path / "index.html").write_text('<!DOCTYPE html><html><head><base href="/"></head><body>FarmOS</body></html>', encoding="utf-8")
    (tmp_path / "main.dart.js").write_text("console.log('farmos')", encoding="utf-8")
    (tmp_path / "sqlite3.wasm").write_bytes(b"\0asm\x01\0\0\0")
    (tmp_path / "assets").mkdir()
    (tmp_path / "assets" / "AssetManifest.bin.json").write_text("{}", encoding="utf-8")
    monkeypatch.setenv("FARMOS_WEB_DIR", str(tmp_path))
    return tmp_path


def test_the_web_app_is_served_beside_the_api(client, web_app):
    r = client.get("/app", follow_redirects=False)
    assert r.status_code == 308 and r.headers["location"] == "/app/"

    page = client.get("/app/")
    assert page.status_code == 200 and "text/html" in page.headers["content-type"]
    # One build (base "/") serves here under /app/.
    assert '<base href="/app/">' in page.text
    assert page.headers["cache-control"] == "no-cache"

    wasm = client.get("/app/sqlite3.wasm")
    assert wasm.status_code == 200 and wasm.headers["content-type"] == "application/wasm"
    js = client.get("/app/main.dart.js")
    assert js.status_code == 200 and "javascript" in js.headers["content-type"] and js.headers["cache-control"] == "no-cache"
    assert client.get("/app/assets/AssetManifest.bin.json").status_code == 200

    assert client.get("/").json()["app"] == "/app/"
    # The API is unchanged beside it.
    assert client.get("/health").json() == {"status": "ok"}


def test_nothing_outside_the_web_folder_is_served(client, web_app):
    for path in ("/app/../../etc/passwd", "/app/%2e%2e/%2e%2e/etc/passwd", "/app/missing.js"):
        assert client.get(path).status_code == 404, path


def test_without_an_installed_web_app_the_page_says_how_to_add_it(client, tmp_path, monkeypatch):
    monkeypatch.setenv("FARMOS_WEB_DIR", str(tmp_path / "nothing-here"))
    r = client.get("/app/")
    assert r.status_code == 404 and "origami-farmos-web.zip" in r.text
    assert "app" not in client.get("/").json()
