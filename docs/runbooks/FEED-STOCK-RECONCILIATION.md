# Feed stock: integrity rules and the reconciliation procedure (v0.8.4)

Audit 2026-11-25 (default branch `9acaba3`), issues **I-1** (a named lot that
held too little was made up silently from no lot), **I-2** (after an approved
override the stock line and the lots disagreed for good) and **I-13**
(concurrent issues of the last stock — unverified). Fixed by migration
`d6f8a0c2e4b7` and the rewrite of `backend/app/services/feed_inventory_service.py`.

## 1. One derivation of the quantity

The rows are the stock (`database/INVENTORY-SCHEMA.md` §1: *On Hand = SUM(posted
transactions)*; balances are rebuildable projections):

```
lot balance       = Σ movements naming the lot                 never below zero
untraced balance  = Σ movements of the item naming no lot       never above zero
on hand           = Σ every movement of the item
                  = Σ lot balances + untraced balance           the stock line
available         = usable lot stock (not quarantined / blocked / recalled / expired)
                    − untraced not yet reconciled (open exceptions)
                    − reserved for another purpose
```

- `inventory_items.current_qty` and `feed_lots.quantity_on_hand` are
  **projections**. One function writes them, `_post`, in the same transaction
  as the movement it posts; nothing else assigns a feed quantity.
- Every screen, report and check reads the same numbers:
  `GET /feed-products/{id}` → `availability` = `on_hand`, `lot_on_hand`,
  `untraced`, `open_exceptions`, `unusable`, `reserved`, `available`.
- A movement names no lot only in three cases: stock recorded before the feed
  had lots, the carry-over of that stock into its opening lot
  (`opening_balance`, a correlated pair), and a **stock exception**.

Worked example (audit test `test_NEW2`): count 10 kg → feed 60 kg with an
approved override → receive 100 kg. Stock line **50**, lots **100**, fed with no
lot **50** (open), available **50**. One number on every screen (50) and its two
parts named; nothing says 100 against 50 without saying why.

## 2. Issuing: a named lot, FIFO, holds, reservations

| Case | Result |
|---|---|
| A lot is named and holds enough (less what others reserved on it) | Issued from that lot only. |
| A lot is named and holds too little | **422**, nothing posted: *"…it holds 20 kg, 50 kg requested. A named lot is never made up from another lot…"* — never a second lot, never no lot. |
| No lot named | FIFO by received date over usable lots, each up to its free quantity. |
| A lot quarantined / blocked / recalled / expired | Never issued; naming it is refused; FIFO skips it. |
| Reservations of another purpose | A lot reservation holds back stock of that lot only (nothing on a held lot); a product reservation holds back one pool. Before v0.8.4 the pool was subtracted from every lot, so an issue the arithmetic allowed came out partly with no lot, silently (test `test_a_product_reservation_holds_its_kilos_back…`). |
| More than is available | **422** with the arithmetic, unless an approved override (§3). |

## 3. The override: an explicit stock exception

`allow_negative: true` is accepted only from someone with Feed or Inventory
**approve** (403 otherwise) and only with `override_reason` (422 when the
override is used without one). What no lot covers is posted as one `out` with no
lot, tagged `stock_exception_id`, and recorded in **`feed_stock_exceptions`**:

| Field | Meaning |
|---|---|
| `quantity`, `resolved_quantity`, `status` | the untraced gap; `open` until reconciled (`resolved`, or `reversed`) |
| `reason` | the manager's words |
| `requested_by`, `approved_by`, `approval_request_id` | who recorded it, who authorised it; the same person when a manager records it, the employee and the manager when it came through an approval request |
| `source_entity_type/id`, `lot_id` | the feeding or mix it was for; the named lot that held too little |
| `resolution`, `resolution_lot_id`, `resolution_note`, `resolved_by/at`, `detail.resolutions[]` | how it was reconciled, each step kept |

Audit log `feed_stock_exception_opened` / `_resolved`; events
`feed_stock_exception_opened` / `_resolved`. Every movement now carries
`actor_user_id`.

### Reconciling (the manager: Feed or Inventory approve)

| How | Endpoint | Movements posted (tagged, correlated) | Effect |
|---|---|---|---|
| **It came from lot X** (a delivery or mix entered after the feeding) | `POST /feed-inventory/exceptions/{id}/resolve` `{"resolution": "assigned_to_lot", "lot_id": …, "note": …}` | `out` on X + `in` with no lot | X gives the kilos up now; on hand unchanged; untraced → 0. Refused if X arrived more than a day after the feeding (lineage), or holds less. The feeding's own record keeps *no lot* — history is not rewritten; the exception names X and `GET /feed-lots/{id}/trace` lists it. |
| **The stock was there, never entered** | same, `"confirmed_unrecorded_stock"` | `in` with no lot | on hand rises by the gap. |
| **Count the stock** | `POST /feed-inventory/counts` | count corrections on the lots + `in` with no lot per open exception | the count becomes the stock; every open exception of the feed is settled (`resolution: count`). |
| **Undo the feeding** | `POST /feeding-events/{id}/reverse` (or a correction) | `in` with no lot | the exception is `reversed`. |

A second reconciliation of the same exception is refused (409). On the tablet
and the web app: Feed → *Raw materials & lots* → the feed shows **Fed with no
lot 30 kg**; *Reconcile* (managers) lists each exception with who, when and
why, and offers *It came from a lot*, *The stock was there* or *Count the stock
instead*. The count form says it also settles them.

## 4. Every path that changes feed stock

| Path | Before v0.8.4 | Now |
|---|---|---|
| Receipt — `POST /feed-lots/receive`, mix output, `POST /feed/transactions` `in`, seed | lot created at its quantity + `in` row; stock line `+=` | lot created empty, `in` posted by `_post` under the row lock |
| Issue — feeding (`/feeding-events`, quick entry, queue, programs), mix ingredients (`/feed-mixes`, `/feed-batches/{id}/complete`, approved mix requests), `POST /feed/transactions` `out` | named short lot → rest from no lot, **no override** (I-1); product reservation pool → silent no-lot draws; stock line `-=` qty | §2–3: refused or an explicit exception |
| Negative exception | `out` with no lot, untagged; stock line and lots apart for good (I-2) | `feed_stock_exceptions` + tagged `out`; reconciled per §3 |
| Reversal / correction of a feeding | no-lot part returned to no lot, untagged | closes its exception (`reversed`); if already reconciled, back to the lot it was reconciled to |
| Count — `POST /feed-inventory/counts` | corrections on lots, then **stock line overwritten** (`current_qty = counted`) | corrections posted; open exceptions settled by posted movements; the stock line follows the rows (INVENTORY-SCHEMA §6: a count never overwrites a balance) |
| Correction / waste / supplier return — `POST /feed-inventory/adjustments`, reconciliation close | could take a lot below zero; a gain with no lot posted no-lot stock | never below zero (422); a loss with no lot named comes oldest first; a gain goes to the named lot, the newest usable one, or a lot of its own (`<code>-ADJ`) |
| Quarantine / block / recall / release — `PATCH /feed-lots/{id}/status`, `/feed-batches/{id}/quarantine` | status only | status only, decided under the same lock as issues |
| Reservation — `/feed-allocations` create / release / transfer | could over-reserve under concurrency | under the lock; a reservation on a held lot holds back nothing usable |
| Opening balance (an item that predates lots) | lot created with the quantity, **no movement** | correlated pair (lot `in`, no-lot `out`); a stock-line figure with no movement behind it is first made explicit (`opening_balance`) |
| Visitor shop — `POST /visit-retail-sales` on a feed item | stock line `-=` qty, no lot | issued FIFO from the lots; refused when not there |
| Device sync — `POST /sync/push` `inventory_item` on a feed item | stock line changed, **no movement**, clamped at zero | rejected for feed (`status: rejected`); non-feed unchanged |
| Demo seed — opening balances pinned | lot and stock line edited directly | `opening_balance` movement on the opening lot |

Not feed, not in this PR (same pattern to apply later): pharmacy lots
(`pharmacy_service`: consume/adjust write `current_qty` without a row lock),
produce from the harvest (`agriculture.py`), the visitor shop and sync push on
non-feed items, Mouneh finished goods.

## 5. Concurrency (I-13)

Every stock-changing operation first takes the product's inventory-item row
`SELECT … FOR UPDATE` (`lock_stock`), in item-id order when several feeds move
together (a feeding of three feeds, a mix and its output), then re-reads the
lots and reservations. The second of two simultaneous feedings waits for the
first to commit and decides on what it left. SQLite takes one write lock for the
whole database, so it serialises writers by construction; the proof is on
PostgreSQL 16 (`backend/tests/test_feed_stock_concurrency_pg.py`, real threads,
real connections, a barrier and a transaction held open):

| Test | Result |
|---|---|
| two feedings of the last 10 kg (FIFO) | one succeeds, one refused *"0.0 kg available"*; lot 0, stock line 0, 10 kg issued |
| two feedings naming the last lot | one succeeds, one refused naming the lot |
| two approved overrides at once | both recorded; lot 0 (never −10); the second's 10 kg an open exception; stock line −10 = ledger |
| A-then-B and B-then-A at once | no deadlock, both succeed |
| **control:** the same race with the lock replaced by a plain read | **both succeed, 20 kg leave a 10 kg lot, the stored figures disagree with the ledger** — the race is real on this server; the lock is what prevents it |

## 6. Upgrading a farm server to v0.8.4

1. **Back up the database** (`pg_dump -Fc`), as before any migration.
2. `alembic upgrade head` (or the *Migrate staging* workflow). Migration
   `d6f8a0c2e4b7` creates `feed_stock_exceptions`, adds the two columns, and
   backfills per feed product — **inserting** movements only; no stored stock
   line changes, no existing movement is touched (the migration test asserts
   both):
   - a lot whose stored quantity has no movements behind it (an opening balance
     carried before v0.8.4, a seed figure) gets a `ledger_carry_over` pair: the
     difference on the lot, the opposite on no lot;
   - a stock line that differs from its movements gets one `ledger_carry_over`
     movement on no lot for the difference;
   - a lot below zero is brought to zero by a pair; its shortfall joins the
     no-lot balance;
   - the no-lot balance then: above zero → carried into a new lot
     `<code>-CARRIED` (`<code>-OPENING` for a feed with no lot yet); below zero
     → **one open `legacy_untraced` exception** for the gap, listing every
     no-lot movement since the feed's first lot (id, date, quantity, reason,
     what it was for, who recorded the feeding) and the lots that were below
     zero. Approval was not recorded before v0.8.4: `approved_by` is empty and
     the reason says so.
3. **Check:** `python -m app.feed_stock_integrity` (exit 0 = consistent), or
   `GET /feed-inventory/integrity`, or the SQL in
   [`feed-stock-reconciliation.sql`](feed-stock-reconciliation.sql) — Q1–Q5
   must return no rows; Q6 is the manager's list of open exceptions.
4. **Reconcile** what Q6 lists (§3) — usually one physical count of each feed
   concerned, on the tablet: Feed → *Stock* → *Count stock*.
5. If Q1/Q2 (a stored figure ≠ its movements) ever return rows after the
   upgrade, that is a defect or a hand edit, not a farm event: record what was
   found, then `python -m app.feed_stock_integrity --rebuild --as <manager
   user id>` sets the figures back to their movements (no movement posted; the
   old values in the audit log `feed_stock_projection_rebuilt`) and report the
   defect.

Never "fix" a total by editing `current_qty`, `quantity_on_hand` or a posted
movement: every correction is a new movement (a count, an adjustment with its
explanation, a reconciliation).

## 7. Evidence

Local run, 2026-11-25, PostgreSQL **16.15**, SQLite, Python 3.13 venv (CI:
Python 3.11 + `postgres:16` service, `backend-tests.yml`, which runs every test
below with `FARMOS_TEST_POSTGRES_URL` set).

| Suite | Result |
|---|---|
| `tests/test_feed_stock_integrity.py` (21: NEW1, NEW2, override, reconcile ×3, count, reversal, lineage, permissions, FIFO + named lot, holds, reservations ×2, return/waste/gain, approval names both people, sync push, visitor shop, untagged movements, rebuild) | 21 passed |
| `tests/test_feed_stock_concurrency_pg.py` on PostgreSQL 16 | 6 passed (incl. the control) |
| `tests/test_feed_stock_migration.py` on SQLite and PostgreSQL 16 | 2 passed |
| `scripts/verify-all.sh` with `FARMOS_TEST_POSTGRES_URL` (PostgreSQL 16.15) | **all checks passed**: backend 617 passed (SQLite, incl. OpenAPI + schema artifacts); PostgreSQL step 13 passed (migration parity, livestock backfill, feed-stock migration, the six concurrency tests); app analyzer clean of errors; app 410 passed (incl. layout sweep EN/AR); web release build |
| app `test/records/stock_integrity_test.dart` + updated `status_and_feed_forms_test.dart` | 18 passed |
| browser (web release build against a live server, demo farm migrated with one approved 30 kg override) | Feed → *Raw materials & lots*: *Fed with no lot 30 kg*, *In lots 0 kg*, *Fed with no lot (to reconcile) − 30 kg*, available 0; *Reconcile* lists who recorded and approved it and why; *The stock was there* + note → the warning is gone |

Reconciliation SQL on PostgreSQL 16 (schema migrated to head, demo farm seeded,
then one approved 30 kg override on wheat straw):

```
Q1: 0 row(s)   Q2: 0 row(s)   Q3: 0 row(s)   Q4: 0 row(s)   Q5: 0 row(s)
Q6: 1 row(s)  ('Q6', 'fp-wheat-straw', 'untraced_issue', 30.0, …)
```

After planting a 7 kg drift on the corn silage stock line:

```
Q1: 1 row(s)  ('Q1', 'fp-corn-silage', 'Corn Silage', 2207.0, 2200.0)
$ python -m app.feed_stock_integrity
farm-origami: 11 feed products, 1 inconsistent, 1 with feed issued with no lot (30 open)
  ✗ Corn Silage (fp-corn-silage): stock line 2207 ≠ ledger 2200
  • Wheat straw: 30 kg issued with no lot, open — reconcile it
INCONSISTENT                                  (exit 1)
$ python -m app.feed_stock_integrity --rebuild --as user-rami
rebuilt fp-corn-silage: {'stock_line': {'from': 2207.0, 'to': 2200.0}}
CONSISTENT                                    (exit 0)
Q1–Q5: 0 row(s)
```
