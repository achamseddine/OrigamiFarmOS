"""API smoke tests for a staging server, over synthetic farm records.

    python -m app.staging.smoke --base-url http://127.0.0.1:8770/api/v1 --state state.json
    python -m app.staging.smoke --base-url ... --verify-state state.json   # after a restart or a restore

The first form checks the server end to end against the synthetic demo
farm (`python -m app.seed`): health, the published contract, sign-in and
access, the farm's clock, writes that move money, milk and feed stock (each
made twice with the same Idempotency-Key — once on the server), the reads
the tablet starts with, that a signed-out request and a worker are refused,
and the reconciliations' dry runs (nothing is applied). It records what it
created in [--state]. The second form signs in again and finds every one of
those records: what a restart or a restore must keep.

Exit code 0 when every check passed, 1 otherwise; the JSON report says
which. It only talks to this machine or a host whose name says staging —
never a production server, never real farm data.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from urllib.parse import urlparse

import httpx

MANAGER = ("rami@origami.farm", "farmos123")  # the synthetic demo farm's accounts (app/seed.py)
WORKER = ("karim.worker@origami.farm", "farmos123")
FARM = "farm-origami"
CLEAR_COW = "cow-clover"
TAG = "STAGING-SMOKE"


class NotStaging(RuntimeError):
    pass


def ensure_staging(base_url: str, *, allow_remote_staging: bool = False) -> None:
    """Only this machine, a compose service, or (asked for) a host named staging."""
    host = (urlparse(base_url).hostname or "").lower()
    if host in ("127.0.0.1", "localhost", "::1", "api", "origami-staging-api"):
        return
    if allow_remote_staging and "staging" in host:
        return
    raise NotStaging(f"{host or base_url!r} is not a staging server: the smoke test writes synthetic records and only runs on this "
                     "machine (or, with --allow-remote-staging, a host whose name says staging).")


@dataclass
class Report:
    checks: list[dict] = field(default_factory=list)
    state: dict = field(default_factory=dict)

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        self.checks.append({"check": name, "result": "PASS" if ok else "FAIL", "detail": detail})
        return ok

    def skip(self, name: str, detail: str) -> None:
        self.checks.append({"check": name, "result": "SKIP", "detail": detail})

    @property
    def passed(self) -> bool:
        return all(c["result"] != "FAIL" for c in self.checks)

    def to_dict(self) -> dict:
        return {"passed": self.passed, "at": datetime.now(timezone.utc).isoformat(), "checks": self.checks, "state": self.state}


class Api:
    def __init__(self, client: httpx.Client, base: str):
        self.c = client
        self.base = base.rstrip("/")
        self.token: str | None = None

    def url(self, path: str) -> str:
        return f"{self.base}{path}"

    def h(self, **extra) -> dict:
        return {**({"Authorization": f"Bearer {self.token}"} if self.token else {}), **extra}

    def get(self, path: str, **params) -> httpx.Response:
        return self.c.get(self.url(path), headers=self.h(), params=params or None)

    def post(self, path: str, body: dict, *, key: str | None = None) -> httpx.Response:
        return self.c.post(self.url(path), headers=self.h(**({"Idempotency-Key": key} if key else {})), json=body)

    def login(self, who: tuple[str, str]) -> bool:
        r = self.c.post(self.url("/auth/login"), json={"email": who[0], "password": who[1]})
        self.token = r.json().get("access_token") if r.status_code == 200 else None
        return self.token is not None


def _root(base: str) -> str:
    return base.rstrip("/").removesuffix("/api/v1")


def run(client: httpx.Client, base: str) -> Report:
    """Every check, in order. [base] ends in /api/v1."""
    rep = Report()
    api = Api(client, base)

    r = client.get(f"{_root(base)}/health")
    rep.check("health", r.status_code == 200 and r.json().get("status") == "ok", f"HTTP {r.status_code}")
    r = client.get(f"{_root(base)}/openapi.json")
    paths = len(r.json().get("paths", {})) if r.status_code == 200 else 0
    rep.check("published API contract", r.status_code == 200 and paths > 200, f"{paths} paths")

    unauth = client.get(api.url("/animals"))
    rep.check("signed-out request refused", unauth.status_code == 401, f"HTTP {unauth.status_code}")

    if not rep.check("manager signs in", api.login(MANAGER), MANAGER[0]):
        return rep
    me = api.get("/auth/me").json()
    rep.check("profile and farm", me.get("farm_id") == FARM, f"farm {me.get('farm_id')}")
    access = api.get("/me/access")
    rep.check("access and modules", access.status_code == 200 and bool(access.json()), f"HTTP {access.status_code}")
    farm = api.get("/farms/me")
    tz = farm.json().get("timezone") if farm.status_code == 200 else None
    rep.check("farm settings", tz == "Asia/Beirut", f"timezone {tz}")

    for path, params in (("/animals", {"farm_id": FARM}), ("/production/milk", {"farm_id": FARM, "days": 7}), ("/feed-products", {}),
                         ("/feeding-plan/today", {}), ("/finance/expenses", {"days": 30}), ("/notifications", {})):
        r = api.get(path, **params)
        rep.check(f"read {path}", r.status_code == 200, f"HTTP {r.status_code}")

    # Writes that move money, milk and feed stock — each sent twice with one key.
    run_id = uuid.uuid4().hex[:8]
    body = {"category": "repairs", "description": f"{TAG} {run_id}: hinge on the feed store door", "amount": 12.5, "currency": "USD",
            "payment_status": "paid", "reference": f"{TAG}-{run_id}"}
    key = f"{TAG}-expense-{run_id}"
    first, again = api.post("/finance/expenses", body, key=key), api.post("/finance/expenses", body, key=key)
    ok = first.status_code == 201 and again.status_code == 201 and first.json().get("id") == again.json().get("id")
    if rep.check("expense recorded once for two identical requests", ok, f"HTTP {first.status_code}/{again.status_code}"):
        rep.state["expense_id"] = first.json()["id"]

    tank_before = api.get("/production/milk-tank").json().get("balance_l", 0.0)
    milk = {"animal_id": CLEAR_COW, "session": "morning", "liters": 7.5, "destination": "stored",
            "recorded_at": datetime.now(timezone.utc).isoformat(), "confirm_duplicate": True}
    key = f"{TAG}-milk-{run_id}"
    first, again = api.post("/production/milk", milk, key=key), api.post("/production/milk", milk, key=key)
    ok = first.status_code == 201 and again.status_code == 201 and first.json().get("id") == again.json().get("id")
    if rep.check("milk recorded once for two identical requests", ok, f"HTTP {first.status_code}/{again.status_code}"):
        rep.state["milk_record_id"] = first.json()["id"]
        saleable = first.json().get("release_status") == "saleable"
        tank_after = api.get("/production/milk-tank").json().get("balance_l", 0.0)
        rep.check("saleable milk reaches the tank once", not saleable or abs(tank_after - tank_before - 7.5) < 1e-6,
                  f"{tank_before:g} L → {tank_after:g} L ({first.json().get('release_status')})")

    products = api.get("/feed-products").json()
    product = next((p for p in products if p.get("ration_type") in ("concentrate", "raw_material", "silage", "hay_straw")), None)
    if product is None:
        rep.check("feed delivery", False, "no feed product on the synthetic farm")
    else:
        lot_body = {"feed_product_id": product["id"], "quantity": 25, "unit_cost": 0.3, "supplier_label": f"{TAG} supplier",
                    "reference": f"{TAG}-{run_id}", "lot_code": f"{TAG}-{run_id}", "confirm_duplicate": True}
        key = f"{TAG}-lot-{run_id}"
        first, again = api.post("/feed-lots/receive", lot_body, key=key), api.post("/feed-lots/receive", lot_body, key=key)
        ok = first.status_code == 201 and again.status_code == 201 and first.json().get("id") == again.json().get("id")
        if rep.check("feed delivery received once for two identical requests", ok, f"HTTP {first.status_code}/{again.status_code}"):
            rep.state["feed_lot_id"] = first.json()["id"]
            rep.state["feed_product_id"] = product["id"]

    briefing = api.get("/morning-briefing", farm_id=FARM)
    rep.check("morning briefing", briefing.status_code == 200, f"HTTP {briefing.status_code}")

    # The reconciliations' dry runs: read-only, nothing applied.
    mouneh = api.get("/finance/reconciliation/mouneh-sales")
    rep.check("Mouneh sales reconciliation (dry run)", mouneh.status_code == 200 and mouneh.json().get("dry_run") is True,
              f"HTTP {mouneh.status_code}, {len(mouneh.json().get('items', [])) if mouneh.status_code == 200 else '?'} to put in the books")
    review = api.get("/production/milk-safety/review")
    rep.check("milk safety review (read-only)", review.status_code == 200, f"HTTP {review.status_code}")
    purchases = api.get("/finance/reconciliation/purchases")
    if purchases.status_code == 404:
        rep.skip("purchases reconciliation (dry run)", "not in this server version")
    else:
        rep.check("purchases reconciliation (dry run)", purchases.status_code == 200 and purchases.json().get("dry_run") is True,
                  f"HTTP {purchases.status_code}")

    worker = Api(client, base)
    if rep.check("worker signs in", worker.login(WORKER), WORKER[0]):
        refused = worker.get("/finance/reconciliation/mouneh-sales")
        rep.check("worker refused the manager's reconciliation", refused.status_code == 403, f"HTTP {refused.status_code}")
    return rep


def verify_state(client: httpx.Client, base: str, state: dict) -> Report:
    """After a restart or a restore: every record the smoke test made is there."""
    rep = Report(state=state)
    api = Api(client, base)
    rep.check("records to look for", any(k in state for k in ("expense_id", "milk_record_id", "feed_lot_id")), ", ".join(sorted(state)) or "none")
    r = client.get(f"{_root(base)}/health")
    rep.check("health", r.status_code == 200 and r.json().get("status") == "ok", f"HTTP {r.status_code}")
    if not rep.check("manager signs in", api.login(MANAGER), MANAGER[0]):
        return rep
    if "expense_id" in state:
        ids = {e["id"] for e in api.get("/finance/expenses", days=30).json()}
        rep.check("the expense is still there", state["expense_id"] in ids, state["expense_id"])
    if "milk_record_id" in state:
        ids = {m["id"] for m in api.get("/production/milk", farm_id=FARM, days=7).json()}
        rep.check("the milk record is still there", state["milk_record_id"] in ids, state["milk_record_id"])
    if "feed_lot_id" in state:
        ids = {lot["id"] for lot in api.get("/feed-lots", feed_product_id=state.get("feed_product_id")).json()}
        rep.check("the feed lot is still there", state["feed_lot_id"] in ids, state["feed_lot_id"])
    return rep


def _wait_healthy(client: httpx.Client, base: str, seconds: float) -> None:
    deadline = time.monotonic() + seconds
    while True:
        try:
            if client.get(f"{_root(base)}/health").status_code == 200:
                return
        except httpx.HTTPError:
            pass
        if time.monotonic() > deadline:
            return
        time.sleep(1)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="python -m app.staging.smoke", description=__doc__.split("\n\n")[0])
    p.add_argument("--base-url", required=True, help="the staging API, ending in /api/v1")
    p.add_argument("--state", help="write what was created here")
    p.add_argument("--verify-state", help="check the records listed in this state file instead")
    p.add_argument("--report", help="write the JSON report here")
    p.add_argument("--wait", type=float, default=60, help="seconds to wait for /health first")
    p.add_argument("--allow-remote-staging", action="store_true")
    args = p.parse_args(argv)
    try:
        ensure_staging(args.base_url, allow_remote_staging=args.allow_remote_staging)
    except NotStaging as e:
        print(e, file=sys.stderr)
        return 2
    with httpx.Client(timeout=30) as client:
        _wait_healthy(client, args.base_url, args.wait)
        if args.verify_state:
            with open(args.verify_state) as f:
                rep = verify_state(client, args.base_url, json.load(f))
        else:
            rep = run(client, args.base_url)
            if args.state:
                with open(args.state, "w") as f:
                    json.dump(rep.state, f, indent=2)
    out = rep.to_dict()
    if args.report:
        with open(args.report, "w") as f:
            json.dump(out, f, indent=2)
    for c in out["checks"]:
        print(f"{c['result']:4}  {c['check']}" + (f" — {c['detail']}" if c["detail"] else ""))
    print("All smoke checks passed." if rep.passed else "Some smoke checks FAILED.")
    return 0 if rep.passed else 1


if __name__ == "__main__":
    sys.exit(main())
