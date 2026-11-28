# Next-session handoff (2026-11-28)

## Released
Integrated release **v0.8.20**: PRs #34–#43 merged through `claude/release-integration` into
`claude/origami-farmos-tablet-mvp-u88i3e`, which has Packages 1–7 and 11–13. The APK and web zip are built by
`build-apk.yml` / `build-web.yml` on push to that branch (see the GitHub pre-releases `tablet-v0.8.20-build-*` and
`web-v0.8.20-build-*`). The migration merge revision is `e5a7c9b1d3f6`.

## Not released: work that exists, unmerged
| Package | Branch | State |
|---|---|---|
| 8 Corn silage | `claude/p8-corn-silage` (local worktree only, **not pushed**) | verify-all passed on the retry (the first run hit one flaky `test_migrations[postgresql]` race). Uncommitted: a P7 snapshot commit is its base. Re-stack on `cefc7ed` (P7), commit, push, PR. Migration `e3f5a7c9b1d4` must then revise `e5a7c9b1d3f6`'s chain (re-point onto the current head). |
| 9 Equipment maintenance | `claude/p9-equipment-maintenance` (local only) | Code, app and tests complete; full verify not finished (interrupted). Migration `f1b3d5a7c9e2`. |
| 10 Animal photos | `claude/p10-animal-photos` (local only) | Code, app and tests complete; full verify not run. Adds `Pillow` and `image_picker`. Physical camera test NOT RUN. |
| Group F integration journey | `claude/f-integration-acceptance` (local only) | `backend/tests/test_integration_journey_pg.py` and `docs/FINAL-ACCEPTANCE.md` include P8–P10; port the journey without steps 6–7 if those stay out. |

The local worktrees live in this container only (`/home/user/OrigamiFarmOS-p8`, `-p9`, `-p10`, `-f`); they are lost when the
container is reclaimed. To keep P8–P10, the next session should push them first (branches above), even as drafts.

## Known issues
- `tests/test_migrations.py::...[postgresql]` failed once under the parallel suite (`NoSuchTableError` while
  inspecting); it passed 3/3 alone and in the dedicated PostgreSQL step. Likely another test sharing the PostgreSQL
  test database's `public` schema. Investigate before relying on CI as a merge gate.
- GitHub's `ubuntu-latest` is Ubuntu 26.04: `postgresql-client-16` is not in its sources; CI takes `pg_dump` /
  `pg_restore` from the `postgres:16` image (PR #38).
- `scripts/verify-all.sh` runs the Mouneh PostgreSQL tests twice (its own step and the money step): harmless, ~2 min.

## Not done (needs a person or outside access)
- A physical Android tablet: install the APK, offline sign-in after restart, offline milk, QR, outbox after a day offline.
- Real farm acceptance, the farm's nutritionist's requirements, lab analyses, real prices.
- Any production deployment or reconciliation `--apply` on real data.
