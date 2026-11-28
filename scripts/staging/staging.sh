#!/usr/bin/env bash
# Origami FarmOS — a PostgreSQL 16 staging server you can throw away
# (master prompt Package 6, docs/runbooks/STAGING-POSTGRES.md).
#
#   scripts/staging/staging.sh all            # the whole chain, from nothing, with a report
#   scripts/staging/staging.sh up             # database, migrations, synthetic farm, API, health
#   scripts/staging/staging.sh smoke          # API smoke tests over synthetic records
#   scripts/staging/staging.sh backup         # pg_dump + checksum + table snapshot
#   scripts/staging/staging.sh restore [DUMP] # into a second database, compared with the snapshot
#   scripts/staging/staging.sh restart-check  # stop the API and PostgreSQL, start them, find the records
#   scripts/staging/staging.sh reconcile      # the reconciliation dry runs
#   scripts/staging/staging.sh down [--purge] # stop (and delete) the staging server
#
# STAGING_MODE=local (default) runs a PostgreSQL 16 cluster of its own in
# $STAGING_DIR (initdb, its own port), so it never touches another server.
# STAGING_MODE=docker uses deploy/staging/docker-compose.yml instead.
#
# Never production: it builds its own database (names contain "staging"),
# ignores DATABASE_URL and PROD_DATABASE_URL, seeds only the synthetic demo
# farm, and the smoke test refuses any server but this one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHON="${PYTHON:-python3}"
MODE="${STAGING_MODE:-local}"
DIR="${STAGING_DIR:-${TMPDIR:-/tmp}/origami-staging}"
PG_PORT="${STAGING_PG_PORT:-55440}"
API_PORT="${STAGING_API_PORT:-8770}"
RESTORE_API_PORT="${STAGING_RESTORE_API_PORT:-8771}"
DB="origami_staging"
RESTORE_DB="origami_staging_restore"
PG_USER="origami"
COMPOSE=(docker compose -f "$ROOT/deploy/staging/docker-compose.yml" --project-name origami-staging)
TS="$(date -u +%Y%m%dT%H%M%SZ)"

# Whatever the shell had, this script decides where it writes.
unset DATABASE_URL PROD_DATABASE_URL

say() { printf '\n=== %s\n' "$*"; }
die() { printf 'staging: %s\n' "$*" >&2; exit 1; }

case "$DB$RESTORE_DB" in *staging*staging*) ;; *) die "refusing: the staging databases must be named for staging";; esac
mkdir -p "$DIR/backups" "$DIR/reports"

# --- PostgreSQL 16 ---------------------------------------------------------
pg_bin() {
  if [[ -x /usr/lib/postgresql/16/bin/postgres ]]; then echo /usr/lib/postgresql/16/bin; return; fi
  local b; b="$(pg_config --bindir 2>/dev/null || true)"
  [[ -n "$b" && -x "$b/postgres" ]] || die "PostgreSQL 16 server binaries not found (install postgresql-16, or use STAGING_MODE=docker)"
  echo "$b"
}
as_pg() { if [[ "$(id -u)" == 0 ]]; then runuser -u postgres -- "$@"; else "$@"; fi; }
db_url() { echo "postgresql://$PG_USER@127.0.0.1:$PG_PORT/$1"; }
psql_() { psql -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -v ON_ERROR_STOP=1 "$@"; }

pg_up() {
  if [[ "$MODE" == docker ]]; then
    STAGING_PG_PORT="$PG_PORT" "${COMPOSE[@]}" up -d postgres > /dev/null
    for _ in $(seq 1 60); do pg_isready -h 127.0.0.1 -p "$PG_PORT" -q && { echo "PostgreSQL (container) on 127.0.0.1:$PG_PORT"; return; }; sleep 1; done
    die "the PostgreSQL container did not come up (docker compose logs postgres)"
  fi
  local bin; bin="$(pg_bin)"
  "$bin/postgres" --version | grep -q ' 16\.' || die "PostgreSQL 16 expected, found: $("$bin/postgres" --version)"
  if [[ ! -f "$DIR/pgdata/PG_VERSION" ]]; then
    mkdir -p "$DIR/pgdata"
    [[ "$(id -u)" == 0 ]] && chown -R postgres "$DIR"
    as_pg "$bin/initdb" -D "$DIR/pgdata" -U "$PG_USER" --auth=trust --encoding=UTF8 --no-locale > "$DIR/initdb.log"
  fi
  if ! as_pg "$bin/pg_ctl" -D "$DIR/pgdata" status > /dev/null 2>&1; then
    as_pg "$bin/pg_ctl" -D "$DIR/pgdata" -l "$DIR/postgres.log" -w -t 60 \
      -o "-p $PG_PORT -c listen_addresses=127.0.0.1 -k $DIR" start > /dev/null
  fi
  "$bin/pg_isready" -h 127.0.0.1 -p "$PG_PORT" -t 30 > /dev/null || die "PostgreSQL did not come up (see $DIR/postgres.log)"
  echo "PostgreSQL $("$bin/postgres" --version | awk '{print $3}') on 127.0.0.1:$PG_PORT, data in $DIR/pgdata"
}

pg_down() {
  if [[ "$MODE" == docker ]]; then "${COMPOSE[@]}" stop postgres > /dev/null && echo "PostgreSQL (container) stopped"; return; fi
  local bin; bin="$(pg_bin)"
  if [[ -f "$DIR/pgdata/PG_VERSION" ]] && as_pg "$bin/pg_ctl" -D "$DIR/pgdata" status > /dev/null 2>&1; then
    as_pg "$bin/pg_ctl" -D "$DIR/pgdata" -m fast -w stop > /dev/null
    echo "PostgreSQL stopped"
  fi
}

create_db() {
  if [[ "$(psql_ -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$1'")" != 1 ]]; then
    psql_ -d postgres -qc "CREATE DATABASE $1" && echo "database $1 created"
  fi
}

# --- the backend -------------------------------------------------------------
alembic_() { (cd "$ROOT/backend" && DATABASE_URL="$1" FARMOS_SCHEDULER=false "$PYTHON" -m alembic -c alembic.ini "${@:2}"); }

migrate() {
  alembic_ "$(db_url "$1")" upgrade head > "$DIR/reports/migrate-$1-$TS.log" 2>&1 || { cat "$DIR/reports/migrate-$1-$TS.log"; die "migrations failed on $1"; }
  check_head "$1"
}

check_head() {
  local head current
  head="$(alembic_ "$(db_url "$1")" heads 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' ')"
  current="$(alembic_ "$(db_url "$1")" current 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' ')"
  [[ -n "$head" && "$head" == "$current" ]] || die "$1 is at revision '${current}', not the head '${head}'"
  echo "$1 at the head revision: $head"
}

seed() {
  (cd "$ROOT/backend" && DATABASE_URL="$(db_url "$DB")" FARMOS_SCHEDULER=false "$PYTHON" -m app.seed) | tail -1
}

secret() {
  if [[ ! -s "$DIR/secret" ]]; then
    "$PYTHON" -c 'import secrets; print(secrets.token_urlsafe(48))' > "$DIR/secret"
    chmod 600 "$DIR/secret"
  fi
  cat "$DIR/secret"
}

api_up() {  # api_up DB PORT NAME
  local db="$1" port="$2" name="$3"
  if [[ "$MODE" == docker && "$name" == api ]]; then
    FARMOS_SECRET_KEY="$(secret)" STAGING_API_PORT="$port" STAGING_PG_PORT="$PG_PORT" "${COMPOSE[@]}" up -d --build api > /dev/null
  elif [[ -f "$DIR/$name.pid" ]] && kill -0 "$(cat "$DIR/$name.pid")" 2> /dev/null; then
    return
  else
    if curl -fsS "http://127.0.0.1:$port/health" > /dev/null 2>&1; then die "port $port is already in use by another server (STAGING_API_PORT)"; fi
    local key; key="$(secret)"
    (
      cd "$ROOT/backend"
      # The server itself in the background, so its own pid is the one kept.
      DATABASE_URL="$(db_url "$db")" FARMOS_SECRET_KEY="$key" FARMOS_SCHEDULER="${STAGING_SCHEDULER:-false}" \
        nohup "$PYTHON" -m uvicorn app.main:app --host 127.0.0.1 --port "$port" > "$DIR/$name.log" 2>&1 &
      echo $! > "$DIR/$name.pid"
    )
  fi
  for _ in $(seq 1 90); do
    if [[ -f "$DIR/$name.pid" ]] && ! kill -0 "$(cat "$DIR/$name.pid")" 2> /dev/null; then tail -20 "$DIR/$name.log"; die "the API ($name) exited"; fi
    if curl -fsS "http://127.0.0.1:$port/health" > /dev/null 2>&1; then echo "API ($name) healthy on http://127.0.0.1:$port"; return; fi
    sleep 1
  done
  tail -20 "$DIR/$name.log"; die "the API ($name) did not become healthy"
}

api_down() {  # api_down NAME
  local name="$1"
  if [[ "$MODE" == docker && "$name" == api ]]; then "${COMPOSE[@]}" stop api > /dev/null && echo "API (container) stopped"; return; fi
  if [[ -f "$DIR/$name.pid" ]]; then
    local pid; pid="$(cat "$DIR/$name.pid")"
    if kill -0 "$pid" 2> /dev/null; then kill "$pid"; for _ in $(seq 1 30); do kill -0 "$pid" 2> /dev/null || break; sleep 0.5; done; echo "API ($name) stopped"; fi
    rm -f "$DIR/$name.pid"
  fi
}

smoke_() { (cd "$ROOT/backend" && "$PYTHON" -m app.staging.smoke "$@"); }
snapshot_() { (cd "$ROOT/backend" && "$PYTHON" -m app.staging.snapshot "$@"); }

# --- steps -------------------------------------------------------------------
cmd_up() {
  say "PostgreSQL 16 ($MODE)"; pg_up
  say "database, migrations from empty, synthetic farm"
  create_db "$DB"; migrate "$DB"; seed
  say "API"; api_up "$DB" "$API_PORT" api
}

cmd_smoke() {
  say "API smoke tests (synthetic records)"
  smoke_ --base-url "http://127.0.0.1:$API_PORT/api/v1" --state "$DIR/state.json" --report "$DIR/reports/smoke-$TS.json"
}

# pg_dump and pg_restore of the server's own major version, never newer (a newer
# pg_dump writes settings the server refuses on restore): app/staging/pg_tools.py.
pg_tools_dir() {
  local major; major="$(psql_ -d postgres -tAc 'SHOW server_version_num')" || die "cannot read the server's version"
  (cd "$ROOT/backend" && "$PYTHON" -m app.staging.pg_tools "$((major / 10000))") || die "no pg_dump / pg_restore for this server's version"
}

cmd_backup() {
  say "backup"
  local dump="$DIR/backups/$DB-$TS.dump" tools; tools="$(pg_tools_dir)"
  "$tools/pg_dump" -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" --format=custom --no-owner --file "$dump" "$DB"
  snapshot_ --database-url "$(db_url "$DB")" --out "$dump.snapshot.json"
  (cd "$DIR/backups" && sha256sum "$(basename "$dump")" > "$(basename "$dump").sha256")
  ln -sfn "$dump" "$DIR/backups/latest.dump"
  echo "backup $dump ($(du -h "$dump" | cut -f1)), sha256 $(cut -c1-16 "$dump.sha256")…"
}

cmd_restore() {
  say "restore into $RESTORE_DB"
  need_state
  local dump; dump="$(readlink -f "${1:-$DIR/backups/latest.dump}")"
  [[ -f "$dump" ]] || die "no backup at $dump (run: staging.sh backup)"
  (cd "$(dirname "$dump")" && sha256sum --quiet -c "$(basename "$dump").sha256") || die "the backup's checksum does not match: $dump"
  echo "checksum verified"
  psql_ -d postgres -qc "DROP DATABASE IF EXISTS $RESTORE_DB"
  create_db "$RESTORE_DB"
  local tools; tools="$(pg_tools_dir)"
  "$tools/pg_restore" -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" --no-owner --exit-on-error -d "$RESTORE_DB" "$dump"
  snapshot_ --database-url "$(db_url "$RESTORE_DB")" --compare "$dump.snapshot.json"
  check_head "$RESTORE_DB"
  # The API on the restored copy finds what the smoke test made before the backup.
  api_up "$RESTORE_DB" "$RESTORE_API_PORT" api-restore
  local rc=0
  smoke_ --base-url "http://127.0.0.1:$RESTORE_API_PORT/api/v1" --verify-state "$DIR/state.json" --report "$DIR/reports/restore-$TS.json" || rc=$?
  api_down api-restore
  return $rc
}

need_state() { [[ -s "$DIR/state.json" ]] || die "no smoke-test records to look for ($DIR/state.json): run staging.sh smoke first"; }

cmd_restart_check() {
  say "restart: API and PostgreSQL stopped and started again"
  need_state
  api_down api; pg_down; pg_up; api_up "$DB" "$API_PORT" api
  smoke_ --base-url "http://127.0.0.1:$API_PORT/api/v1" --verify-state "$DIR/state.json" --report "$DIR/reports/restart-$TS.json"
  # Migrating again is a no-op: the server already runs the head revision.
  alembic_ "$(db_url "$DB")" upgrade head > /dev/null 2>&1 && check_head "$DB"
}

cmd_reconcile() {
  say "reconciliation dry runs"
  local out="$DIR/reports/feed-stock-$TS.json" rc=0
  (cd "$ROOT/backend" && DATABASE_URL="$(db_url "$DB")" FARMOS_SCHEDULER=false "$PYTHON" -m app.feed_stock_integrity --json) > "$out" || rc=$?
  if [[ $rc == 0 ]]; then echo "feed stock: every product consistent with its movements ($out)"; else echo "feed stock: inconsistencies reported in $out"; return 1; fi
  echo "Mouneh sales, milk safety (and purchases where the server has it): dry runs in the smoke report — nothing applied"
}

cmd_down() {
  api_down api-restore
  if [[ "$MODE" == docker ]]; then
    "${COMPOSE[@]}" down ${1:+--volumes}
  else
    api_down api; pg_down
  fi
  if [[ "${1:-}" == --purge ]]; then rm -rf "$DIR"; echo "deleted $DIR"; fi
}

cmd_all() {
  cmd_down --purge > /dev/null 2>&1 || true
  mkdir -p "$DIR/backups" "$DIR/reports"
  local results=() failed=0
  run_step() {
    # In its own shell with errexit on, outside any `if`: bash ignores
    # `set -e` inside a condition, which would pass a step whose check failed.
    local name="$1"; shift
    local t0=$SECONDS rc
    set +e
    ( set -e; "$@" )
    rc=$?
    set -e
    if [[ $rc == 0 ]]; then results+=("PASS  $name ($((SECONDS - t0))s)"); else results+=("FAIL  $name ($((SECONDS - t0))s)"); failed=1; fi
  }
  run_step "PostgreSQL 16, migrations from empty, synthetic farm, API healthy" cmd_up
  run_step "API smoke tests" cmd_smoke
  run_step "backup (pg_dump, checksum, table snapshot)" cmd_backup
  run_step "restore into a second database, identical, API finds the records" cmd_restore
  run_step "restart persistence (API and PostgreSQL restarted)" cmd_restart_check
  run_step "reconciliation dry runs" cmd_reconcile
  {
    echo "# Staging run $TS"
    echo
    echo "Commit $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?'), mode $MODE, PostgreSQL $(psql_ -d "$DB" -tAc 'SHOW server_version' 2>/dev/null || echo '?'), data in \`$DIR\`."
    echo
    printf -- '- %s\n' "${results[@]}"
  } > "$DIR/reports/summary-$TS.md"
  say "Summary"; printf '%s\n' "${results[@]}"; echo "Report: $DIR/reports/summary-$TS.md"
  return $failed
}

case "${1:-}" in
  all) cmd_all ;;
  up) cmd_up ;;
  smoke) cmd_smoke ;;
  backup) cmd_backup ;;
  restore) shift; cmd_restore "${1:-}" ;;
  restart-check) cmd_restart_check ;;
  reconcile) cmd_reconcile ;;
  down) shift; cmd_down "${1:-}" ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
