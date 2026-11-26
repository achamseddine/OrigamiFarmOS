"""What a database holds, to prove a restore matches its backup.

    python -m app.staging.snapshot --database-url URL --out counts.json
    python -m app.staging.snapshot --database-url URL --compare counts.json

Records, for every table, the row count and a checksum of the rows (the
md5 of the table's rows in primary-key order), and the Alembic revision.
`--compare` exits 1 and names each table that differs. PostgreSQL only
for the checksums (SQLite gets the counts). Read-only.
"""
from __future__ import annotations

import argparse
import json
import sys

from sqlalchemy import create_engine, inspect, text

from app.core.config import normalize_database_url


def take(url: str) -> dict:
    engine = create_engine(normalize_database_url(url))
    try:
        insp = inspect(engine)
        tables = sorted(insp.get_table_names())
        out: dict = {"tables": {}, "alembic": []}
        postgres = engine.dialect.name == "postgresql"
        with engine.connect() as conn:
            for t in tables:
                count = conn.execute(text(f'SELECT count(*) FROM "{t}"')).scalar()
                entry: dict = {"rows": int(count)}
                if postgres:
                    pk = insp.get_pk_constraint(t).get("constrained_columns") or [c["name"] for c in insp.get_columns(t)]
                    order = ", ".join(f'r."{c}"' for c in pk)
                    entry["md5"] = conn.execute(text(
                        f"SELECT md5(coalesce(string_agg(r::text, '|' ORDER BY {order}), '')) FROM \"{t}\" r")).scalar()
                out["tables"][t] = entry
            if "alembic_version" in tables:
                out["alembic"] = sorted(r[0] for r in conn.execute(text("SELECT version_num FROM alembic_version")))
        return out
    finally:
        engine.dispose()


def differences(a: dict, b: dict) -> list[str]:
    out = []
    for t in sorted(set(a["tables"]) | set(b["tables"])):
        if a["tables"].get(t) != b["tables"].get(t):
            out.append(f"{t}: {a['tables'].get(t)} != {b['tables'].get(t)}")
    if a.get("alembic") != b.get("alembic"):
        out.append(f"alembic_version: {a.get('alembic')} != {b.get('alembic')}")
    return out


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="python -m app.staging.snapshot", description=__doc__.split("\n\n")[0])
    p.add_argument("--database-url", required=True)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--out")
    g.add_argument("--compare")
    args = p.parse_args(argv)
    snap = take(args.database_url)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(snap, f, indent=2, sort_keys=True)
        rows = sum(t["rows"] for t in snap["tables"].values())
        print(f"{len(snap['tables'])} tables, {rows} rows, revision {', '.join(snap['alembic']) or '-'}")
        return 0
    with open(args.compare) as f:
        diff = differences(json.load(f), snap)
    for d in diff:
        print("DIFFERS", d)
    print("Identical to the backup." if not diff else f"{len(diff)} table(s) differ from the backup.")
    return 0 if not diff else 1


if __name__ == "__main__":
    sys.exit(main())
