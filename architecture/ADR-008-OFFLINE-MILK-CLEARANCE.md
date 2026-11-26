# ADR-008 — Milk entered offline is cleared by the server; the farm's clock on the tablet

- Status: accepted (v0.8.11)
- Audit: 2026-11-25 I-11 (P1) and I-16 (P2)
- Amends: ADR-005 §3 (the answer to milk a recorded withdrawal covers, for an entry made offline)
- Related: architecture/OFFLINE-SYNC.md, ADR-005-MILK-SAFETY-AT-THE-MILKING-TIME.md

## Context

**I-11.** Tablet A loses the farm server. The veterinarian records a treatment with a milk withdrawal on tablet B. Tablet A still holds the animal as it was: its quick entry picks *stored* from the cached `withdrawal_until`, the record is queued, and the tablet's own lists show it as stored milk. When tablet A reconnects, the server judges the milking at its own time (ADR-005) and answers **422** — *record this milk as withheld*. The record is lost (the outbox keeps a refused write in the sync panel, nothing more), nobody who decides is told, and the milk may already be in the bulk tank.

The refusal is right at the parlour: the person sees it and withholds the milk. For a write replayed hours later nobody sees it, and refusing it throws away the one fact that matters — 10 L of milk under withdrawal went somewhere.

**I-16.** The app suggested the morning or the afternoon milking from the device's hour (`milkSessionForHour(DateTime.now().hour)`) and dated milk entered for an earlier day at the device's 07:00 / 18:00. A tablet or a browser set to another zone (a manager abroad, a tablet left on UTC) suggested the wrong milking and dated it in the wrong session.

## Decision

1. **A replayed write says when it was recorded offline.** The outbox replays every queued write with `X-Offline-Recorded-At: <when it was recorded on the tablet, UTC>` (`ApiClient.replay`). Live writes never carry it. The server reads it (`app/core/offline.py`); a value that is not a time, or is in the future, is ignored and the write is judged as a live one.

2. **The server clears milk entered offline from its own records.** `POST /production/milk` (and the older `POST /sync/push`) judge the milking at its own time from the treatment history, exactly as a live entry (ADR-005). The answers:

   | The milking | Live entry | Entered offline |
   |---|---|---|
   | clear | saleable | saleable |
   | uncertain withdrawal | kept, held for review | kept, held for review |
   | **recorded withdrawal, not recorded as withheld** | **refused (422)** — the person withholds it | **kept as entered, held**: `withdrawal_check = withdrawal`, `release_status = held`, a safety note saying it was entered offline, before the tablet knew of the withdrawal, and that the tank may hold it |
   | recorded withdrawal, recorded as withheld | not for sale | not for sale |
   | a milking she cannot have given (dried off, between lactations, not on the farm, not a milk animal) | refused | **refused** — the tablet keeps showing it |

   Milk entered offline under a recorded withdrawal is **never saleable**: held milk is out of the tank, the collector's handover and every sale (ADR-005 §4), and the held-milk review refuses to release milk a recorded window covers (409) — it can only be withheld, with a reason on file. Where the milk went (`destination`) stays what the person recorded: production and disposition are facts; saleability is the status.

3. **The people who decide are told.** The manager, the owner and the veterinarian get a high-priority *milk safety* notification (*10 L of Bella's milk under withdrawal entered offline as stored*), and so does the person who recorded it, who saw *saved* on the tablet. The record carries `milk_recorded` (with `recorded_offline_at`) and `milk_held_for_review` events and a `milk_held_offline_under_withdrawal` audit entry.

4. **On the tablet, milk recorded offline is nobody's milk yet.** The queued record is shown at once (no second entry) with `release_status = awaiting_check`, a status only the tablet uses: it is not counted as stored on the Milk page, the animal's milk tab shows *Waiting for check*, and the Milk page's **Milk waiting for the farm server's safety check** card lists it. The tank, the collector's handover and the sales are the server's figures and never include it. The forms say so when the server cannot be asked (*Offline: … the milk will wait for the server's safety check*). After the sync, the server's own record — saleable, held or not for sale — replaces the tablet's.

5. **What the server refused stays in view.** A milk write the server refused stays on the same card — the cow, the day, the milking, the litres and the server's reason — with **Try again** and **Discard** (asked first), not only in the sync panel.

6. **The farm's clock.** `GET /farms/me` adds `clock`: the farm's time zone and its offset from UTC from two days ago to 400 days ahead, one entry per daylight-saving change from the minute it takes effect. The app keeps it (`FarmClock`, cached for offline like any read) and suggests the morning milking before 13:00 **on the farm's clock**; milk entered for an earlier day is dated at that milking's farm hour (morning 07:00, midday 12:00, evening 18:00). Until the farm's clock is known (a first start offline, the demo farm), the device's own clock is used, as before. No new dependency: the server, which has the time-zone database, works out the offsets.

## Consequences

- The mandatory scenario holds: 10 L recorded offline on tablet A after the vet recorded a withdrawal on tablet B wait on tablet A, reach the server once (idempotency key), keep their milking time, and are held — never in the saleable tank, the collector's handover or revenue (`backend/tests/test_offline_milk_clearance.py`, the same on PostgreSQL 16 in `test_offline_milk_clearance_pg.py`; the tablet side in `mobile/flutter_app/test/production/offline_milk_test.dart`).
- The reverse order — tablet A's milk synced first, the treatment backdated later — is held by ADR-005 §6, as before.
- A client could send the header on a live entry: the milk would be held and the reviewers told instead of refused. It can never make milk saleable that a live entry would not, so the header is not an authority.
- No migration. The offline time is kept in the safety note, the event payload and the audit entry, not in a column.
- **Not covered:** the bulk tank as a physical container is not modelled (ADR-005 *Not covered*). The server holds the record and says the tank may hold milk under withdrawal; whether the tank is emptied is the people's decision, recorded when they withhold the milk. A tank-level quarantine that blocks every sale until someone clears the tank would be the next step.
