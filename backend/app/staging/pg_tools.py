"""The PostgreSQL client tools a backup and a restore may use
(master prompt Package 6; docs/runbooks/STAGING-POSTGRES.md).

`pg_dump` and `pg_restore` must be the **server's own major version**. A
newer `pg_dump` writes settings the older server does not know into the
dump — pg_dump 17 writes `SET transaction_timeout`, which a PostgreSQL 16
server refuses — so the restore fails (`--exit-on-error`) or, without that
flag, silently skips statements. An older one cannot read the newer
server's catalogue. So the tools are looked for by version, not by PATH
order: the server's version directory first (`/usr/lib/postgresql/16/bin`
on Debian and Ubuntu, `/usr/pgsql-16/bin` on RHEL, Homebrew's
`postgresql@16`), then `$PG_BIN`, then the PATH; the first `pg_dump` and
`pg_restore` reporting that major version are used.

    python -m app.staging.pg_tools 16      # prints the directory, or exits 1 saying why
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

TOOLS = ("pg_dump", "pg_restore")


class ToolsMissing(RuntimeError):
    pass


def candidate_dirs(server_major: int, *, path: str | None = None) -> list[str]:
    dirs = [f"/usr/lib/postgresql/{server_major}/bin", f"/usr/pgsql-{server_major}/bin", f"/opt/homebrew/opt/postgresql@{server_major}/bin",
            f"/usr/local/opt/postgresql@{server_major}/bin"]
    if os.environ.get("PG_BIN"):
        dirs.append(os.environ["PG_BIN"])
    dirs += [d for d in (path if path is not None else os.environ.get("PATH", "")).split(os.pathsep) if d]
    seen: list[str] = []
    for d in dirs:
        if d not in seen:
            seen.append(d)
    return seen


def tool_major(executable: str) -> int | None:
    """`pg_dump (PostgreSQL) 16.15 (Ubuntu …)` → 16; None when it does not answer like one."""
    try:
        out = subprocess.run([executable, "--version"], capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"\(PostgreSQL\)\s+(\d+)", out)
    return int(m.group(1)) if m else None


def find(server_major: int, *, search: list[str] | None = None) -> dict[str, str]:
    """{tool: path} for pg_dump and pg_restore of exactly `server_major`, from one directory."""
    seen: list[str] = []
    for folder in (search if search is not None else candidate_dirs(server_major)):
        paths = {t: os.path.join(folder, t) for t in TOOLS}
        if not all(os.path.isfile(p) and os.access(p, os.X_OK) for p in paths.values()):
            continue
        majors = {t: tool_major(p) for t, p in paths.items()}
        if all(m == server_major for m in majors.values()):
            return paths
        seen.append(f"{folder} ({', '.join(f'{t} {m}' for t, m in majors.items())})")
    found = "; found " + ", ".join(seen) if seen else "; none found"
    raise ToolsMissing(f"pg_dump and pg_restore of PostgreSQL {server_major} are needed for a backup of a PostgreSQL {server_major} server"
                       f"{found}. Install postgresql-client-{server_major} (or set PG_BIN).")


def main(argv: list[str]) -> int:
    if len(argv) != 2 or not argv[1].isdigit():
        print("usage: python -m app.staging.pg_tools SERVER_MAJOR", file=sys.stderr)
        return 2
    try:
        print(os.path.dirname(find(int(argv[1]))["pg_dump"]))
    except ToolsMissing as exc:
        print(exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
