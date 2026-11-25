"""Feed stock reconciliation from the command line (v0.8.4).

    python -m app.feed_stock_integrity                    # every farm, report only
    python -m app.feed_stock_integrity --farm farm-x      # one farm
    python -m app.feed_stock_integrity --json             # machine-readable
    python -m app.feed_stock_integrity --rebuild --as user-id   # see below

Reads DATABASE_URL like the server. For every feed product it compares
the two stored figures — the stock line (`inventory_items.current_qty`)
and each lot's quantity — with the sum of their movements, and the stock
issued with no lot with the open stock exceptions. Exit code 0 when every
product is consistent, 1 when any is not (so a deployment step can stop).

`--rebuild` sets an inconsistent product's stored figures back to what its
movements say (INVENTORY-SCHEMA §1: balances are rebuildable projections).
It posts no movement and changes no history; the audit log keeps each
figure's old value under the user named by `--as`. It does not touch the
untraced balance or the exceptions — those are reconciled by the manager
(a count, or POST /feed-inventory/exceptions/{id}/resolve). The procedure:
docs/runbooks/FEED-STOCK-RECONCILIATION.md.
"""
from __future__ import annotations

import argparse
import json
import sys

from sqlalchemy import select

from app.db.base import SessionLocal
from app.domain import feed_models as fm
from app.domain import models
from app.domain.registry import import_all
from app.services import feed_inventory_service as inv


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.feed_stock_integrity", description=__doc__.split("\n\n")[0])
    parser.add_argument("--farm", help="one farm id (default: every farm)")
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    parser.add_argument("--rebuild", action="store_true", help="rebuild the stored figures of inconsistent products from their movements")
    parser.add_argument("--as", dest="user_id", help="the user the rebuild is audited under (required with --rebuild)")
    args = parser.parse_args(argv)
    if args.rebuild and not args.user_id:
        parser.error("--rebuild needs --as <user id>: the audit log names who rebuilt the figures")
    import_all()
    db = SessionLocal()
    try:
        farms = [args.farm] if args.farm else list(db.scalars(select(models.Farm.id).order_by(models.Farm.id)))
        reports = {farm: inv.integrity_report(db, farm) for farm in farms}
        rebuilt = []
        if args.rebuild:
            for farm, report in reports.items():
                for product_id in report["inconsistent"]:
                    product = db.get(fm.FeedProduct, product_id)
                    rebuilt.append(inv.rebuild_projections(db, product, user_id=args.user_id))
            db.commit()
            reports = {farm: inv.integrity_report(db, farm) for farm in farms}
        db.rollback()  # a read leaves nothing behind
    finally:
        db.close()
    consistent = all(r["consistent"] for r in reports.values())
    if args.json:
        print(json.dumps({"consistent": consistent, "farms": reports, "rebuilt": rebuilt}, default=str, indent=2))
    else:
        for farm, report in reports.items():
            products = report["products"]
            open_total = sum(p["open_exceptions"] for p in products)
            print(f"{farm}: {len(products)} feed products, {len(report['inconsistent'])} inconsistent, "
                  f"{sum(1 for p in products if p['untraced'] > 0)} with feed issued with no lot ({open_total:g} open)")
            for p in products:
                if not p["consistent"]:
                    print(f"  ✗ {p['name']} ({p['feed_product_id']}): " + "; ".join(p["problems"]))
                elif p["untraced"] > 0:
                    print(f"  • {p['name']}: {p['untraced']:g} {p['unit']} issued with no lot, open — reconcile it")
        for r in rebuilt:
            print(f"rebuilt {r['feed_product_id']}: {r['changes']}")
        print("CONSISTENT" if consistent else "INCONSISTENT")
    return 0 if consistent else 1


if __name__ == "__main__":
    sys.exit(main())
