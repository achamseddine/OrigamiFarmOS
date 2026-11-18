#!/usr/bin/env bash
# Everything that must pass before a commit is pushed (CLAUDE.md, "Before
# every commit"). The tablet APK and the web app are one Flutter codebase,
# so one run checks both; the APK itself is built by CI (.github/workflows/
# build-apk.yml) because Android's SDK host is not reachable everywhere.
#
#   scripts/verify-all.sh
#
# Environment (all optional):
#   PYTHON                    backend Python with requirements.txt installed (python3)
#   FLUTTER                   flutter executable (flutter)
#   FARMOS_TEST_POSTGRES_URL  a disposable PostgreSQL database: migration parity
#                             and data backfill are then checked on PostgreSQL too
#   MAIN_REF                  the main tablet branch to check merging against
#                             (origin/claude/origami-farmos-tablet-mvp-u88i3e)
#   SKIP_WEB_BUILD=1          skip the release web build (the slowest step)
#
# Exit status is non-zero when any step fails; the summary says which.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
FLUTTER="${FLUTTER:-flutter}"
MAIN_REF="${MAIN_REF:-origin/claude/origami-farmos-tablet-mvp-u88i3e}"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/farmos-verify.XXXXXX")"
declare -a RESULTS=()
FAILED=0

step() { # name, command...
  local name="$1"; shift
  local log="$LOG_DIR/$(echo "$name" | tr ' /' '__').log"
  printf '\n=== %s\n' "$name"
  local start=$SECONDS
  if "$@" >"$log" 2>&1; then
    RESULTS+=("PASS  $name ($((SECONDS - start))s)")
    tail -n 3 "$log"
  else
    RESULTS+=("FAIL  $name ($((SECONDS - start))s) — log: $log")
    FAILED=1
    tail -n 40 "$log"
  fi
}

# --- 0. Still merges cleanly with the main tablet branch -----------------
merge_check() {
  cd "$ROOT"
  if ! git rev-parse --verify --quiet "$MAIN_REF" >/dev/null; then
    echo "$MAIN_REF is not fetched; fetch it first (git fetch origin <branch>)."; return 1
  fi
  if git merge-base --is-ancestor "$MAIN_REF" HEAD; then
    echo "HEAD already contains $MAIN_REF."; return 0
  fi
  # A merge of the main branch under way (the usual step before pushing):
  # it passes once every conflict is resolved in the work tree.
  if [[ "$(git rev-parse -q --verify MERGE_HEAD)" == "$(git rev-parse "$MAIN_REF")" ]]; then
    if [[ -z "$(git diff --name-only --diff-filter=U)" ]] && ! git grep -nE '^(<<<<<<<|>>>>>>>) ' -- . >/dev/null; then
      echo "Merge of $MAIN_REF in progress; every conflict is resolved (commit the merge)."; return 0
    fi
    echo "Merge of $MAIN_REF in progress with unresolved conflicts:"; git diff --name-only --diff-filter=U; return 1
  fi
  # A trial merge in memory only: nothing in the work tree changes.
  if git merge-tree --write-tree --name-only HEAD "$MAIN_REF" >"$LOG_DIR/merge-tree.txt"; then
    echo "Merges cleanly with $MAIN_REF (not yet merged: merge it before pushing)."; return 0
  fi
  echo "CONFLICTS with $MAIN_REF:"; sed -n '2,200p' "$LOG_DIR/merge-tree.txt"; return 1
}
step "merge check against main branch" merge_check

# --- 1. Backend ------------------------------------------------------------
backend_tests() {
  cd "$ROOT/backend"
  local parallel=()
  "$PYTHON" -c "import xdist" 2>/dev/null && parallel=(-n 4)
  "$PYTHON" -c "import app.main" && "$PYTHON" -m pytest -q tests -p no:cacheprovider "${parallel[@]}"
}
step "backend tests (SQLite, incl. OpenAPI + schema artifacts)" backend_tests

if [[ -n "${FARMOS_TEST_POSTGRES_URL:-}" ]]; then
  # One database for both: serial, not in parallel workers.
  step "backend migrations on PostgreSQL" bash -c \
    "cd '$ROOT/backend' && '$PYTHON' -m pytest -q -p no:cacheprovider tests/test_migrations.py tests/test_livestock_backfill.py"
else
  RESULTS+=("SKIP  backend migrations on PostgreSQL (set FARMOS_TEST_POSTGRES_URL)")
fi

# --- 2. The app: tablet and web from one codebase --------------------------
cd "$ROOT/mobile/flutter_app"
step "app dependencies" "$FLUTTER" pub get
step "app analyzer (errors fail; warnings as in CI)" "$FLUTTER" analyze --no-fatal-infos --no-fatal-warnings
step "app tests (tablet + web code, layout sweep EN/AR)" "$FLUTTER" test
if [[ "${SKIP_WEB_BUILD:-}" != "1" ]]; then
  step "web release build" "$FLUTTER" build web --release --base-href / --no-web-resources-cdn
else
  RESULTS+=("SKIP  web release build (SKIP_WEB_BUILD=1)")
fi

printf '\n=== Summary\n'
printf '%s\n' "${RESULTS[@]}"
printf 'Logs: %s\n' "$LOG_DIR"
[[ $FAILED -eq 0 ]] && echo "All checks passed." || echo "Some checks FAILED — do not commit."
exit $FAILED
