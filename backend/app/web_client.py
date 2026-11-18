"""The web version of the app, served by the farm server beside its API
(architecture/ADR-004-WEB-CLIENT.md).

The browser app is the tablet app compiled for the web — the same screens,
rules and Arabic layout. Served from here it is on the same address as the
API, so it needs no server address typed in and no cross-origin setup:
open `https://<farm server>/app/` and sign in.

Where the files come from: `FARMOS_WEB_DIR`, or `backend/web_app/` when that
folder exists — the unzipped `origami-farmos-web.zip` from a web release
(`.github/workflows/build-web.yml`). Without them `/app/` says how to add
them; the API is unaffected either way.

The build is made with base href "/" and this module serves its
`index.html` with the base rewritten to `/app/`, so one build serves here,
on GitHub Pages or behind any other prefix.
"""
from __future__ import annotations

import mimetypes
import os
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request, status
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from starlette.staticfiles import StaticFiles

WEB_PREFIX = "/app"
_DEFAULT_DIR = Path(__file__).resolve().parent.parent / "web_app"

# The SQLite engine of the offline store and CanvasKit are WebAssembly: a
# browser refuses to stream-compile them under any other type.
mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("text/javascript", ".js")
mimetypes.add_type("text/javascript", ".mjs")

# Files whose name stays the same from one build to the next: always asked
# again (a 304 when unchanged), so a new build is picked up on the next load.
_REVALIDATE = ("index.html", "flutter_bootstrap.js", "flutter_service_worker.js", "main.dart.js", "version.json", "manifest.json",
               "sqflite_sw.js")

router = APIRouter(include_in_schema=False)
_static: dict[str, StaticFiles] = {}


def web_dir() -> Path | None:
    """The folder holding the built web app, or None when none is installed."""
    configured = os.environ.get("FARMOS_WEB_DIR", "").strip()
    folder = Path(configured) if configured else _DEFAULT_DIR
    return folder if (folder / "index.html").is_file() else None


def _files(folder: Path) -> StaticFiles:
    key = str(folder)
    if key not in _static:
        _static[key] = StaticFiles(directory=folder, html=True, check_dir=False)
    return _static[key]


@router.api_route(WEB_PREFIX, methods=["GET", "HEAD"])
def web_root_redirect() -> RedirectResponse:
    # The app's relative paths resolve against a folder: /app → /app/.
    return RedirectResponse(f"{WEB_PREFIX}/", status_code=status.HTTP_308_PERMANENT_REDIRECT)


@router.api_route(WEB_PREFIX + "/{path:path}", methods=["GET", "HEAD"])
async def web_file(path: str, request: Request) -> Response:
    folder = web_dir()
    if folder is None:
        return HTMLResponse(
            "<!doctype html><meta charset='utf-8'><title>Origami FarmOS</title>"
            "<body style='font-family:system-ui;background:#F7F5F0;color:#1F2320;padding:40px'>"
            "<h2>The web app is not installed on this server yet</h2>"
            "<p>Download <code>origami-farmos-web.zip</code> from the latest <b>web</b> release, unzip it into "
            "<code>backend/web_app/</code> (or set <code>FARMOS_WEB_DIR</code> to its folder) and reload. "
            "The API itself is running: <a href='/docs'>/docs</a>.</p></body>",
            status_code=status.HTTP_404_NOT_FOUND,
        )
    name = path.rsplit("/", 1)[-1] if path else "index.html"
    if path in ("", "index.html"):
        html = (folder / "index.html").read_text(encoding="utf-8")
        html = html.replace('<base href="/">', f'<base href="{WEB_PREFIX}/">', 1)
        return HTMLResponse(html, headers={"Cache-Control": "no-cache"})
    try:
        response = await _files(folder).get_response(path, request.scope)
    except HTTPException:
        raise
    except Exception:  # noqa: BLE001 - a malformed path is simply not found
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Not found") from None
    if name in _REVALIDATE:
        response.headers["Cache-Control"] = "no-cache"
    else:
        response.headers.setdefault("Cache-Control", "public, max-age=3600")
    return response
