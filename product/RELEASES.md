# Releases

## v0.8.1 — The milking routine: calves, the collector, the weekly payment

How the farm works: two milkings a day, morning and afternoon; after each, the calves get their milk and the rest goes to the milk collector, who takes it after every milking and pays once a week. On the tablet and the web app:
- **After each milking** (Milk page): today's and yesterday's milkings, each with the milk that went into the tank, what went to the calves, what the collector took (and its amount), what is left, and whether it is paid. *Hand over* on a milking not handed over yet: the litres to the calves; the collector's litres fill in as the rest (they can be changed). The collector and his price come from the farm's settings, so whoever milks types litres only — an employee who records milk can hand it over, but does not set prices or take payments. The collection is a milk sale to the collector, to be paid with the week; the calves' milk leaves the tank with that reason. The same milking handed over twice is asked (*Already recorded?*); more than the tank holds is refused, except by the manager.
- **Collector & milkings** (the farm manager): the collector's name, his price per litre in USD or LBP (an LBP price is converted at the farm's rate for each day), and what the second milking is called — **Afternoon** or Evening. The app then says *Afternoon* everywhere the second milking appears: the milk form, quick entry, the cow queue, My Day, an animal's milk, corrections, the milk report.
- **Collector paid** (once a week): one form lists everything he still owes — each collection with its day and litres — ticked; it shows what is due, takes what he actually paid (USD or LBP, on its date, receipt no.), and marks every collection paid at once. If he paid less (a deduction) or more, the difference is kept on record with the payment, so the books show the money that really came in. The same *Payment from …* is on Sales & Finance → *Who owes what* for any buyer.
- The milk report shows the calves' milk (per day and in total) and names the second milking as the farm does.
- Offline: a handover and a payment made without the connection are shown at once and sent when it is back.
- Server: **migration `a2c4e6f8b0d3`** — farms: `second_milking`, `milk_collector_name`, `milk_collector_price`, `milk_collector_currency`; `milk_sales` / `milk_tank_adjustments`: `session`, `collection_day`; `sales.payment_id`; new table `customer_payments`. `GET /production/milk-handovers`, `POST /production/milk-handovers` (Milk *create*), `GET|PUT /production/milk-routine` (Milk or Finance *approve*), `GET|POST /finance/payments` (Sales or Finance *create*, or Milk *approve*). Tests: backend +7 (`test_milk_handover.py`), app +7 (`test/records/milk_handover_test.dart`); the tablet-size sweep covers the three new forms.

## v0.8.0 — Origami's financials; Sales and Stock reports; updates from the app

On the tablet and the web app (one codebase), the books kept by the server:
- **Sales & Finance is one page with tabs** — *Today* (as before), *Sales*, *Expenses & bills*, *Who owes what*, *Profit & loss* — and buttons for *Record a sale*, *Record an expense*, *Sell milk* and *Exchange rate*.
- **Any sale.** Eggs, vegetables & fruit, an animal, a farm product or anything else: quantity and unit (tray, dozen, kg, crate, head…), price per unit, the total as it is typed, the buyer (recent buyers as chips; a new one joins the farm's customers), paid now or to be paid, receipt no. Milk is still sold from the tank (*Sell milk*) and Mouneh from its shop, so their stock moves with the sale. A sale can be marked paid, or cancelled with a reason: it stays on file and a negative row undoes it — nothing is deleted. A milk sale cancelled from here also puts its milk back in the tank; Mouneh and farm-shop sales are cancelled in their own module.
- **Expenses and bills.** Labour, fuel, vet, utilities, equipment, repairs, transport, rent, taxes, packaging, seeds, fertilizer, feed, medicine, other: what for, the amount, paid to whom, paid or a bill to pay by its due date, invoice no. Feed and medicine received into stock are already counted from those deliveries (the form says so), so they are not typed twice. A bill is marked paid when paid; a mistaken expense is cancelled with a reason and leaves the totals.
- **USD and LBP.** The books are in USD. Any sale or expense can be entered in LBP: it is converted at the farm's rate for its day, or at the rate actually used, typed on the form; the LBP amount and the rate stay on the record (shown as *$6.00 (537,000 LBP)*). The farm manager sets the rate — *1 USD = 89,500 LBP from <date>* — and earlier entries keep the rate of their own day.
- **Who owes what.** What customers still owe (by buyer, oldest first, mark paid) and what the farm still owes (bills by due date, overdue in red, mark paid).
- **Profit & loss.** The last 12 months: revenue, costs, profit, cash in, cash out; per month; per activity (dairy, poultry & eggs, livestock, crops, Mouneh, farm visits, general); and where the money went. Costs include feed as it is fed (its cost, against the species it was fed to), medicine received, farm-visit costs and every expense; cash out counts feed when it is delivered.
- **Reports: Sales and Stock** (now the first two tabs of *Reports*). *Sales* — everything sold in the period: what (quantity, average price, amount), to whom, by activity, what is still to be paid, and every sale. *Stock* — what is in stock now: feed (on hand, available, days left), medicine (usable, expiring, first expiry), Mouneh products and materials, milk in the tank, every other stock item; what runs low or expires; its value at cost (for those who see money). Each part of the stock report is shown to whoever works in that area. Print, PDF and spreadsheet as for the other reports.
- **Updates from the app.** *Settings → App updates* shows this version and the newest one, with *Check now* and *Update to 0.8.N*: the tablet downloads the newest APK built from the main branch (public GitHub releases) and Android installs it over this one, keeping the farm's data. The app checks a few seconds after sign-in and then every 4 hours; a newer version shows a notice under the top bar (*Update* / *Later*) and in the notifications. In a browser the check compares with the web app deployed on the farm server and offers *Reload*. The build number is now `0.8.N` (APK and web).
- Who may do what: record a sale or mark one paid — Sales or Finance *create*; cancel a sale — Sales or Finance *approve*; record an expense or bill — Expenses or Finance *create*; cancel one — Expenses or Finance *approve*; set the rate — Finance *approve* (the manager). Every sale, payment, cancellation, expense and rate is in the audit history and the event log.
- Offline: a sale, an expense, a payment or a cancellation made without the connection is shown at once (LBP in USD at the rate given) and sent when the connection is back.
- Server: new table `exchange_rates`; new columns on `sales` and `expenses` — **migration `f7b9d1e3a5c8`** (it also marks the milk sales cancelled under v0.7.9 and their reversals, so neither is counted as owed). `GET|POST /finance/exchange-rates`, `GET|POST /finance/sales`, `POST /finance/sales/{id}/paid|cancel`, `GET|POST /finance/expenses`, `POST /finance/expenses/{id}/paid|cancel`, `GET /finance/owed`, `GET /finance/profit-loss`, `GET /reports/sales`, `GET /reports/stock`. Cancelled expenses leave the daily summary and the finance report. Tests: backend +15 (`test_finance.py`), app +21 (`test/records/finance_test.dart`, `test/app/app_update_test.dart`) and the reports tests for the new tabs; the tablet-size sweep covers the finance tabs and the three new forms.

## v0.7.9 — Sell milk from the tank; Reports

On the tablet and the web app (one codebase), worked out by the server:
- **Selling milk.** Milk recorded as *stored* could not be sold — there was no way to record a sale. The Milk page and Sales & Finance now have **Sell milk**: the day (today by default, up to 60 days back), litres (*Sell all* fills the tank), price per litre (the last price is offered), the total as it is typed, the buyer (recent buyers as chips; a new buyer is added to the farm's customers once), *Paid now* or *To be paid*, a receipt number and notes. A sale is the farm's revenue: it shows in Sales & Finance, the daily summary and the reports at once.
- **The milk tank is never typed in.** *In the tank* = milk stored − milk sold + counts and milk taken out, from the records (`GET /production/milk-tank`). Selling more than the tank holds is refused for an employee ("record the milk stored first, or ask the farm manager"); the manager may record it anyway when the milk was there. The manager can **count the tank** (the tank is set to what was measured, the difference kept as a correction) or take milk out with a reason — spoiled, fed to calves, home use, other.
- **Milk tank and sales card** (Milk page, Sales & Finance): in the tank, unpaid, last price; the last ten sales with *Mark paid* and *Cancel sale*. A cancelled sale stays on file with its reason: the revenue is reversed by a negative record and the milk counts as in the tank again. The same collection recorded twice within 30 minutes is asked as a possible duplicate.
- **Who may sell.** Sales or Finance *create*, or Milk production *approve* (the farm manager). An employee who records milk sees the tank and the sales but does not sell, count the tank, mark paid or cancel. Cancelling needs *approve* on Milk, Sales or Finance. Every sale, payment, cancellation and count is in the audit history and the event log.
- **Reports** (new menu entry *Reports*; also *Milk report* on the Milk page, *Export Report* on Animals and on the feed stock — which only said "not ready" before — and *View report* on Sales & Finance): **Milk** (produced, per day, per animal, withheld, where it went, the tank, the chart by session; with money: sold, revenue, average price, unpaid, the sales and each buyer), **Feed** (feedings, feed used and its cost, deliveries, numbered mixes, stock now with days left), **Herd** (on the farm by species, in milk, pregnant, births, animals added and that left, health cases) and **Finance** (revenue, expenses, margin, cash collected, unpaid; by product, by category, day by day, every sale). Periods: last 7 days, last 30 days, this month, last month, or chosen dates (up to a year), in the farm's own days.
- **Print, PDF and spreadsheet.** *Print / PDF* prints the report as shown (Arabic exactly as on screen); *Save PDF* saves or shares it; *Export spreadsheet (CSV)* gives a file that opens in Excel (UTF-8, Arabic included) — a download in the browser, the share sheet on the tablet.
- **Who reads which report.** The Reports permission, or the report's own area (Milk; Feed or Inventory; Animals or Animal health; Finance or Sales). Money (sales, revenue, prices) only with Reports, Finance or Sales.
- Sales & Finance: the remaining English-only text is translated (no sales yet, by revenue, margin, of revenue, the seven-day labels, product and expense names). The milk destination card's *View details* opens the milk report.
- Offline: a sale, a payment, a cancellation and a tank count made without the connection are queued and shown at once ("Waiting to be sent"); a report read once is there offline. The demo farm includes the tank and the four reports.
- A report is worked out again each time the Reports page is opened or comes back into view, so a sale or a milking recorded in between is in it (found in the browser check: the menu's Reports page had kept the answer from sign-in).
- Fixed a test that stopped passing on 23 Nov 2026 on every branch: it relied on the demo goat Willow's milk withdrawal, which in the bundled farm ended on 22 Nov; the test now sets the withdrawal from today (`test/qr/qr_workflow_test.dart`).
- Server: new tables `milk_sales`, `milk_tank_adjustments` — **migration `e6a8c0d2f4b7`**; `GET /production/milk-tank`, `GET|POST /production/milk-sales`, `POST /production/milk-sales/{id}/paid|cancel`, `GET|POST /production/milk-tank/adjustments`, `GET /reports/milk|feed|herd|finance?start&end` (one route each, so the Farm Visits profitability report keeps its own address). Tests: backend +12 (`test_milk_sales_and_reports.py`), app +26 (`test/records/milk_sales_test.dart`, `test/reports/reports_test.dart`); the tablet-size sweep covers the Reports page and the two milk forms. Checked in Chromium against the API: a sale (the tank 617.3 → 497.3 L, $66 unpaid), the milk report, its CSV and PDF, the Finance report.

## v0.7.8 — Employees enter data, the manager approves; the cow queue

On the tablet and the web app (one codebase), enforced by the server:
- **Who may do what.** An employee with Feed or Milk access records the day's milk and feedings. Buying feed, recording a numbered feed mix, changing the feed list or an animal's ration, reserving stock and correcting a record already on file are the farm manager's (Feed / Milk *approve*). Drafting a recipe or a feeding program stays open to employees — a draft does nothing until the manager activates it.
- **Buying feed — ask, manager approves.** *Ask to buy feed* (Feed page, Stock tab) sends a purchase request (feed, quantity, needed by, why). The manager approves or rejects it (with a reason). Once approved, whoever receives the delivery records it against the request — up to the approved quantity + 10% — and the stock goes up then. A delivery with no approved request is refused.
- **An employee's mix waits for the manager.** *Make feed mix* says *Send to the manager*: the mix is kept as a request; ingredients leave the stock and the mix gets its number only when the manager approves it (short stock: the manager may approve anyway).
- **Corrections.** A milk record (amount, session, day, destination) and a feeding (amounts, or undo it) can now be corrected from the animal's Milk tab and Feeding section. The manager corrects directly; an employee sends the correction with a reason and it applies when the manager approves. A milk record is corrected in place with the before/after in the audit log; a feeding is undone (its stock returns) and what was really fed recorded in its place.
- **Approvals card.** On My Day (and on the Feed and Milk pages): the manager sees what waits — mixes, corrections, purchase requests — with Approve / Reject; an employee sees their own requests and the answers, and can withdraw one still waiting. Both are notified in the bell.
- **The cow queue.** *Cow queue* (+ button, Animals, Milk page *Milking queue*, Feed intake *Feeding queue*, My Day's routine): today's morning or evening milking, or the feeding of animals on their own program, in tag order with who is done. *Follow the queue* opens the next cow and moves on after each save (with *Skip*); *Scan QR codes* records in any order — both count in the same list.
- **Milk with its date from the Milk page.** *Record milk* on the Milk page (it had no record button — the web looked as if the date could not be changed) opens the milk form with *Milked on*.
- Server: new table `approval_requests` — **migration `d5f7b9c1e3a6`**; `POST /approval-requests` (+ approve / reject / cancel), `POST /production/milk/{id}/correct`, `POST /feeding-events/{id}/correct`; purchase requests accept a feed and `submit`; deliveries take `requisition_id`. Tests: backend +11 (`test_employee_approvals.py`), app +12 (`test/records/employee_approvals_test.dart`); the tablet-size sweep covers the queue and the new forms.

## v0.7.7 — Feed, reports and module pages read at full height

On the tablet and the web app (one codebase):
- **Fixed — a tab was shown in a small window.** Feed, Mouneh and Farm Visits drew their header, figures and tab bar, and put the chosen tab in what was left under them: on a 10" tablet a mix, the day's feeding or a report scrolled inside a window a few lines tall, and a report's last rows were hard to reach. They now open as one page, like Health: the band and figures scroll away, the tab bar stays at the top of the screen, and the chosen tab is read at its full height down to its last line (`core/widgets/module_workspace.dart`, used by Feed, Health, Mouneh and Farm Visits). Choosing another tab starts it from its top; a tab keeps what was typed in it while another is shown; Farm Visits uses the same tab bar as the other modules.
- **Feed forms full screen on the tablet.** Record purchase, Record a mix, Record feeding, opening a mix (its history), and the other feed forms (new feed, delivery, reservation, formula, program, lab analysis, mixing, reconciliation, stock movement) take the whole screen on a tablet or phone: the title and a close button at the top, the form at a readable width, Cancel / Save in a bar that stays above the keyboard. On a large desktop screen they stay a dialog (`core/widgets/form_dialog.dart`). The mix and feeding rows have more room, so a row's "in stock" line no longer runs into the next row's label.
- **Layout faults the wider check found**, in tabs the tablet-size check never opened before: the pharmacy table's status column and the stock-alert buttons on an 8" tablet, and a section heading's buttons beside a long title. The check now opens every tab of every module page.
- Fixed a backend test that failed whenever it ran before 07:00 UTC (early morning in Lebanon): it dated a feeding at today's 07:00, which the server rightly refuses as a future date (`tests/test_feed_performance.py`).
- No server change, no migration. Tests: app +13 (`test/layout/module_pages_test.dart`: every tab of Feed, Health, Mouneh and Visits is one page scroll the height of the screen; the tab bar stays at the top; reports reach their last line; the feed forms open full screen with Save above the keyboard, and as a dialog on a desktop screen); the tablet-size sweep now walks every module tab.

## v0.7.6 — Milk entered for an earlier day

On the tablet and the web app (one form):
- **"Milked on"** on the milk record and in quick entry: today by default; any of the last 60 days for milk noted on paper and entered later. An earlier day is recorded at that session's usual hour (morning 07:00, midday 12:00, evening 18:00), says "Recording for <date>, not today." under the date, and does not count as today's milk. In quick entry the date stays as set from one animal to the next (a paper sheet for one day) and the same-session check looks at the chosen day.
- The server already took the date: it refuses a day in the future or before the animal's lactation began, and the same session on the same day is still asked as a possible duplicate.
- Fixed: a milk record made offline was queued without its date, and the app could not read it back until it synced; the date is now always sent.
- No migration. Tests: backend +1, app +4.

## v0.7.5 — The web version, and a sign-in fix

**Delivered:**
- **The app in a browser** — the tablet app compiled for the web (`architecture/ADR-004-WEB-CLIENT.md`): every module, form and rule, the same look, Arabic and English, against the same API and database. The farm server serves it at `/app/`, beside the API (`backend/app/web_client.py`); GitHub Pages can host it for a link. Offline storage, the outbox and the demo farm (`ali` / `ali123`) work in the browser (SQLite in WebAssembly, kept in IndexedDB). Builds come from `.github/workflows/build-web.yml` as `origami-farmos-web.zip` on a `web-v0.7.5-build-N` prerelease.
- **Fixed — sign-in did not open the farm (tablet builds 0.7.54 and 0.7.61).** v0.7.3's "Already recorded?" question kept one navigator across sign-in, so after a successful sign-in (or the demo) the sign-in screen stayed. Each signed-in account now gets its own navigator; a regression test covers the switch from sign-in to the farm.
- The farm's data now starts loading after the first frame is drawn (it notified listeners mid-build — debug builds stopped on it).
- The demo farm loads in one transaction instead of 292 separate writes — it never finished in a browser and starts faster on the tablet.
- Messages that said "this tablet" say "this device" (EN and AR), since the same app runs in a browser.
- Verified in Chromium against the live API (sign-in, My Day, Animals, the milk record and its "Already recorded?" question) and with the demo farm at 1920×1080, 1440×900 and 820×1180 portrait, Arabic and English, including reloading the page.
- No migration. Tests: backend +3 (`test_web_client.py`); Flutter +1 (sign-in replaces the sign-in screen).

## v0.7.4 — Review: contradictions, complex steps and layout faults

A review of the whole app, driven three ways: real end-to-end scenarios against the server on a fresh farm as the manager and as a worker; every main screen and form drawn at three tablet sizes in English and Arabic; a scan of the translations and of the offline labels.

**Contradictions closed (server):**
- Records dated in the future were accepted (a birth date, milk, eggs, a harvest, a feeding, a delivery, a mix, an observation) — the calendars on the tablet stopped at today but the server did not check. All refused now; backdating is unchanged.
- Milk could be recorded for a cow not marked as being milked, so her milk and her status disagreed. Milk now needs her to be in milk; the tablet asks to start her milking (with the calving date) and then opens the milk record. The record sheet's milk picker lists only animals that can be milked, those in milk first.
- Weights, treatments, medicine doses, health cases and observations could still be recorded on an animal that had been sold or had died.
- A raw grain could be fed directly; a mix could be dated before its ingredients arrived; a delivery could carry a negative cost; a harvest's waste could exceed the harvest.
- An unknown milking session, or 185 L from one milking (a slipped decimal), was accepted.
- A task could be saved with a blank title or written down twice; the same flock loss could be counted twice.
- A species change is refused once the animal has feeding records (as it already was for milk, health and breeding records).

**Glitches fixed (tablet):**
- 83 of the app's 117 dropdown lists could overflow their field when the chosen text was long (medicine, task, feed and other forms); all now shorten the text instead.
- The page header clipped its buttons on portrait and small tablets (Animals, Feed, Health, Mouneh, Employees, My Day) and ran off the edge on a 10" in landscape; buttons now fold or scroll and the band grows.
- Card titles with a long link, status tags in narrow columns and four rows (milk, animals, health, tasks) overflowed.
- Two pharmacy forms showed the raw text `enterQuantity`.
- Server validation refusals were shown as a raw technical dump; they read as sentences now.
- A feed mix or a farm-settings change made offline showed as an unnamed "Change" in the sync panel.

**Checked and left as is:** worker access follows the duties given (an observation duty includes registering animals — adjust on the employee's card if not wanted); a birth is accepted from a cow whose pregnancy was never recorded; a treatment may start in the future. The demo farm runs without a server, so the server's checks (duplicates, approvals, the above) do not show there.

- No migration.
- Tests: backend +9 (`test_record_consistency.py`); Flutter +14 (a layout sweep of 15 screens and 11 forms × 3 tablet sizes × 2 languages, the start-milking step, readable refusals).

## v0.7.3 — No duplicate entries, approval levels respected

Before more testing: every record workflow checked against the documentation for duplicate entries and approval levels (`architecture/API-STANDARDS.md`, *Duplicate entries and approvals*).

**Delivered:**
- **The same fact is not recorded twice.** Milk (same animal and session that day), eggs, harvest, feeding rounds, feed deliveries, mixes, inseminations, pregnancy checks, births, treatments and medicine doses, observations, weights, health cases, animals with the same name and Mouneh sales are checked on the server against what is already on record. The tablet asks *Already recorded?* with what is there: *No* records nothing; *Yes, record it again* records it as a confirmed repeat (in the event log). Offline entries refused this way can be *Recorded anyway* from the sync panel. A feed, group, field or raw material with the same name, or a lot code used before, is refused outright.
- **Approval levels.** Recording more feed than the stock on record needs Feed or Inventory approval (the tick is shown only to approvers; also the older stock endpoint and Mouneh batch inputs). A worker's formula or program is a draft until a manager activates it; a new farm feed's first mix (which approves its recipe) needs Feed approval and the mix form says so. A poor-grade delivery is held in quarantine until released. A death needs Animals edit; a sale, cull, slaughter or transfer needs Animals approval (the choices are greyed out otherwise). The farm calendar needs Settings configure. Correcting a calving date needs edit.
- Flow: a purchase retried after a refusal reuses the feed it already created; quick entry's *second milking* tick is sent as the confirmation, so it is not asked twice; every tablet write carries an idempotency key.
- Fixed: the demo farm seeded before 07:00 UTC held "today 07:00" feedings in the future, which skewed feed reconciliation and history.
- No migration.
- Tests: backend +13 (each duplicate check, its confirmation and audit; the hard refusals; each approval level), 8 updated; Flutter 260 (+8).

## v0.7.2 — Feed room, breeding calendar, groups, responsibilities, speed

From the second round of on-farm testing (`docs/QR-ANIMAL-QUICK-ENTRY.md`, *Second round*).

**Delivered:**
- **Feed room in the farm's order:** *Record purchase* (date, supplier, invoice, quality grade, moisture, what was seen; a new grain named in the form), *Record a mix* in one step (date, ingredients as weighed, output — a numbered mix; formula v1 from the first mix), *Record feeding*; a *Get the feed room going* card until purchase → silage & straw → mix → feeding have all happened. The standard Concentrate is farm-made so the farm's mixes make it.
- **Calving date and the breeding calendar:** calving / start of milking on the animal form (correctable, audited); farm settings for the milk peak window, the waiting period before insemination and the heat cycle (with the dry-off days); the twin shows days in milk, peak window, *inseminate from*, *watch for heat*; the herd overview lists who is ready to inseminate, who to watch for heat, who is at her peak.
- **Reproduction forms dated:** insemination, pregnancy check, loss, birth, start of milking, dry-off and exit all take their date (before, every insemination was saved as "now"). A "method not allowed" from an older server is explained in plain words.
- **Groups for cows:** *New group* on the Animals screen (the tablet had no way to create one); cattle can also be kept as counted groups; groups that follow the records (pregnant, not pregnant, in milk, dry) and a one-tap pregnant / not-pregnant pair; the demo farm has "Pregnant cows" and "Open cows".
- **Status on the farm** on the edit form: active, sold, died, culled, slaughtered, transferred — recorded as the exit with its date and reason.
- **Work responsibilities:** an employee looks after a group, an animal, a species or a field, with duties (milking, feeding, observations, health care, eggs, crop care, harvest); assigning grants the access the duties need; *My animals & duties* on My Day with today's progress.
- **Speed:** per-request read cache for the farm-wide feeding reads (today's plan 322 → 66 queries, days of cover 410 → 154, notifications 479 → 212), the reproduction overview in a handful of queries, the program list eager-loaded; the tablet loads only what recording needs at sign-in, the feed workspace figures when opened, and after a sync refreshes only the modules whose writes landed.
- Fixed: newborns can be registered with a name only (the farm number follows).
- Migration `c3e5a7b9d1f4` (calendar settings, rule groups, lot quality, responsibilities, cattle/horse group tracking) — run it with `a8d0c2e4f6b1`.
- Tests: backend +7 (purchase → mix → feed, mix refusals, calendar, calving correction, rule groups, responsibilities and their permission); Flutter 252 (+5 new, 3 updated).

## v0.7.1 — Corrections from on-farm testing

From testing the v0.7.0 build on the farm (`docs/QR-ANIMAL-QUICK-ENTRY.md`, *Corrections after on-farm testing*).

**Delivered:**
- **Add an animal with nothing to scan.** The ear tag (cattle) and microchip (horse) no longer block registration; the server gives every new animal the farm's next farm number (one sequence for all species, never reused) and the form shows its QR label to print right after saving. The Digital Twin lists an expected identifier as "Not recorded yet" until it is added. This resolves the conflict between `docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md` and `database/LIVESTOCK-SCHEMA.md` §19 in favour of "ear tag is not universally mandatory" (§4a).
- **Pregnancy and milk on the animal form**, new and existing animals: *Not pregnant / Inseminated — not confirmed / Pregnant* with the insemination date and method, the expected birth and the dry-off date; *Producing milk / Not milked — dried off*. Answers become records (breeding event, pregnancy check, lactation start, dry-off), never flags; saying she is milked opens the milk record. An answer the stage or profile does not allow adjusts them and says so (a goat with no profile → dairy). Senior females keep the adult reproduction and milk capabilities.
- **Farm setting: dry-off before birth** (days, default 60) in Settings; the twin and the reproduction overview show *dry off from* for every pregnant animal in milk and flag it when due.
- **Animal feed record fixed.** The production farm had no feed products, so the form had nothing to choose; the feeding form now opens with three optional rows — Concentrate, Corn silage, Wheat straw — each already pointing at the farm's feed (`GET /feed-products/standard-slots`), plus *Add another feed*. The farm gets the three standard feeds with an empty ledger (migration, production seed, or the form's *Set up* button). Feeding more than the stock entered is no longer a dead end: the form says so and records it only when the worker ticks *Stock not entered yet — record anyway*. The quick-entry screen uses the same rows and override.
- Fixed: the Add Animal form's dropdowns overflowed ("Female · Cow") on narrower tablets.
- Migration `a8d0c2e4f6b1` (farm setting, senior rules, standard feeds) — **run it on the server before using this build.**
- Tests: backend +13 (registration, farm numbers, pregnancy from an insemination, dry-off setting and permission, standard feeds, the stock override), four updated for the new identifier rule; Flutter 247 (+7). PostgreSQL migration parity, downgrade and re-upgrade verified, including the data step on a farm that already has a silage.

**Next:** the health requests from the same testing.

## v0.7.0 — Scan-first worker rounds (QR)

Merges PR #11's QR quick entry (withheld milk enforced server-side, medicine only through the pharmacy, no guessed routes, Arabic/Persian digits) and builds its follow-ups, from a workflow analysis of the 06:00 round (`docs/QR-ANIMAL-QUICK-ENTRY.md`).

**Delivered:**
- Camera QR scanning on the tablet, offline (ADR-003: `mobile_scanner`, `pdf`, `printing`, `barcode`); the camera permission is optional in the manifest.
- QR labels for animals and pens printed or shared as an A4 PDF from the tablet; Arabic names print correctly.
- Pen/group labels (`origami://group/{id}`) open the group's feeding round and members, never one animal.
- The worker screen shows what is already recorded today; a second milking in the same session needs a tick.
- Feed rows from the animal's own program with planned amounts as hints and *Fill planned amounts*; the worker confirms every figure.
- Rounds from My Day (morning/evening milking, individual feeding) with who is done and who is left; *Scan next automatically*.
- Entry points: *Scan an animal* on My Day and in the Record sheet opens the camera; *Print QR labels* on the Animals screen; *Quick entry* and *QR label* in the Digital Twin's Record sheet.
- Tests: Flutter 240 (+18 including PR #11's); backend unchanged and passing.

**Next:**
- Photo attachments with private storage; body-condition scoring; cross-device duplicate reconciliation; barn-light device testing of labels.

## v0.6.1 — Health and Mouneh in the V3 layout

**Delivered:**
- Health: the prototype's command centre (open cases and follow-up, withdrawal review with its caveat, the clinical record), header actions for opening a case, recording an observation and emergency triage, and real tabs in place of three "coming soon" placeholders. Health cases reach the tablet for the first time — list, detail with the veterinarian's diagnoses and plans, open / monitoring / close, offline through cache rules — and on each animal's Health tab. Fixed: the recommendations view crashed its layout on a wide tablet (`IntrinsicHeight` around a `LayoutBuilder`).
- Mouneh: every screen translated to Arabic (196 strings), the module header with *Start a batch* / *Record a sale* / *New product*, figures, underlined tabs, empty states and caveats; the add-material dialog no longer hides a refusal.
- Shared: a header band with an eyebrow over a two-line subtitle no longer overflows on the plain (no-artwork) header.
- Demo data: Bella's two earlier mastitis treatments now sit in closed health cases with the veterinarian's diagnosis and plan; the snapshot carries the cases and the farm's observations.
- Tests: Flutter 222 (+9); backend suite unchanged and passing.

## v0.6.0 — The V3 prototype's layout on the tablet

Brings the farm-wide V3 prototype's UX (`prototypes/origami-farmos-v3.html`) into the Flutter tablet on the real backend, as the prototype's own README asks, starting with animals, My Day and feed.

**Delivered:**
- Shared page anatomy: eyebrow headers on every top-level screen, section headings, dashed empty states, caution notices, record tiles, fact lists and underlined tabs (`core/widgets/ux_blocks.dart`).
- Animal Digital Twin rebuilt as header card + four figures + capability-gated tabs (Overview, Milk, Feed, Weight, Reproduction, Health & medicines, Timeline) with a grouped *Record* sheet; dated weights recorded from the tablet (offline too); a ration-readiness card that calculates nothing; a merged timeline; a missing or not-yet-loaded animal no longer crashes the screen.
- Animal registry with search by any identifier and status filters including animals that left the farm.
- My Day: today's milking, feeding and egg-collection routine, ticked off only from today's records.
- Feed & nutrition: *Make feed mix* / *Record feeding*, ledger-derived figures, the prototype's tab order, rounds recorded today per plan line. Fixed: five feed tabs hid their tap ripple behind a coloured box (a debug-mode assertion).
- Health: the AI caveat and an honest empty state.
- Demo snapshot now carries each animal's weights. 197 strings added in English and Arabic (observation types and event names among them, which were English-only).
- Tests: Flutter 213 (+17, including screens drawn over the bundled snapshot through a new test harness); analyzer unchanged at 0 errors.

**Next:**
- The prototype's Overview and Intelligence pages, Inventory / Crops / Operations / Finance restyles, and body-condition scoring (a capability with no record yet).

## v0.5.0 — The livestock record: history, groups and reproduction

Completes the generic animal model's remaining steps (docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md §13: reproduction, groups, incubation) from LIVESTOCK-SCHEMA, REPRODUCTION-SCHEMA and PRODUCTION-SCHEMA §8.

**Delivered:**
- Backend: migration `b5e7a9c1d3f8` (animal state history; group type policies, memberships, head-count ledger, relationships; breeding events, pregnancy episodes and checks, births and offspring, lactation episodes, incubation batches and hatches; species gestation / incubation days) with a backfill of existing flags, herd names and flock counts. 27 new endpoints. Pregnancy and lactation are a projection of their episodes; an exit closes memberships, lactation, pregnancy and feeding and blocks later milk and feeding; feed inheritance follows real memberships. Identifier search and lookup.
- Tablet: Reproduction & milking and Herd & family on the Digital Twin, the full reproductive record with registration of untagged newborns, Record exit, the reproduction day on the Animals screen, group sheets (members, ledger, incubator) from the Animals and Egg screens, a group picker in the animal form; Milk and Egg screens now load for animal-care staff. Offline and standalone through cache effects; 142 new AR/EN strings.
- Tests: backend 478 (SQLite; the parity and backfill tests also on PostgreSQL 16); Flutter 196.

**Next:**
- Unified production records (§13 step 9) and an admin UI for the species catalog (step 12).
- The cross-cutting move of quantities and money to `numeric`.

## v0.4.0 — Feed intelligence, farm pharmacy, emergency protocols and the specification gap closure

Adds the generic animal and feed architectures' later increments (numbered
mixes, feed performance intelligence), the medicine & pharmacy module, the
clinical decision support / emergency protocol engine, and then closes every
gap the merged database specifications (PR #10) still listed against them.

**Delivered:**
- Backend: `units_of_measure`, `farm_assets`, `notification_routes`, `scheduled_job_runs`, `health_cases`, `diagnoses`, `treatment_plans`, `animal_health_conditions`, `animal_weight_records`, `purchase_requisitions` (+ lines, approvals), `inventory_reservations` and the referencing columns on feed batches, feeding events, lots, administrations, treatments, observations and emergency tables (migration `a7c9e1f3b5d7`, downgradable). New routers: `/units-of-measure`, `/assets`, `/notification-routes`, `/scheduler`, `/health/cases`, `/animals/{id}/conditions`, `/animals/{id}/weights`, `/procurement/requisitions`; `/pharmacy/reservations`, `/pharmacy/transfers`; `/emergency/offline-runs`, `/emergency/reassessments/check`; `/feed-mix-settings`; `/feed-performance/ingredient-lots`, `/feed-performance/effective-feed-value`.
- Feed performance 2.0: lactation-curve, peer-group and production-curve baselines, the full alert catalogue with structured suggested actions, effective feed value, ingredient-lot and supplier signals, re-evaluation on every feeding, lot and context change, a daily scheduled cycle. Pharmacy: unit-referenced quantities, reservations that reduce eligible stock, paired-transaction transfers, requisitions that go through submit / approve / reject with the approving authority snapshotted and that count as incoming supply, prescription-product binding on administrations, per-person routed notifications, a daily expiry scan. Emergency: the engine opens and closes its own health cases, reads recorded allergies and open diagnoses, refuses a weight older than the protocol allows, routes its tasks by role, checks reassessments every 15 minutes, and revalidates protocols executed offline from the signed package, recording every discrepancy.
- Cross-cutting: `database/schema.sql` is rendered from the ORM (`python -m app.export_schema`), `api/openapi.yaml` exported from the application (`python -m app.export_openapi`), and both are checked by tests; `tests/test_migrations.py` proves migration ↔ ORM parity, the demo seed and a downgrade/upgrade round trip on SQLite and on PostgreSQL 16; a backend CI workflow runs the suite with a PostgreSQL service on every push. Found and fixed on the way: boolean literals in two migrations and foreign-key ordering in the seeders that only PostgreSQL rejects, a notification id column too narrow for routed copies, and SQLAlchemy 2.1's change of default PostgreSQL driver (now pinned by the application).
- Tablet: Give medicine and Assess animal from the animal profile; the care record on the Digital Twin (doses with their lots, withdrawal in force, standing conditions, latest weight, open case, live emergency); entity routes for every pharmacy, emergency, health-case, feed and procurement record, with the Health screen opening the right tab; **offline protocol execution** — triage on the device from the signed package with the server's own scoring, eligibility and dose arithmetic (`lib/emergency/offline_engine.dart`), the protocol walked step by step at the animal, and the run queued for the server's revalidation. 176 Flutter tests.

**Next:**
- Versioned statistical / AI feed-performance models behind the same assessment, evidence and confidence contract.
- Push / SMS channels on notification routes; a separate worker when the API runs as more than one process.
- Procurement beyond requisitions (purchase orders, receipts, invoices) and costing attribution.

## v0.3.0 — Farm Visits & Agri-Tourism Module

Adds the license-gated Farm Visits & Agri-Tourism module (tech spec v0.6)
on top of v0.2.0, structured the same way as the Mouneh module.

**Delivered:**
- Backend: `visit_opening_calendar`, `visit_session`, `visit_package`, `visit_activity`, `visitor_profile`, `visit_booking`, `visit_booking_activity`, `visit_staff_roster`, `visit_cost`, `visit_retail_sale`, `visitor_feedback`, `visit_incident`, `visit_events` tables (reusing the existing `module_licenses` table for the license itself) + a pure, unit-tested analytics/validation engine (`app/visits/analytics.py`) + all 15 spec API endpoints plus a few extensions (`/modules/visits/status`, `/visit-calendar`, `/visit-sessions`, `/visit-packages`, `/visit-activities`, `/visitors`, `/visit-bookings` + lifecycle actions, `/visit-staff-roster`, `/visit-costs`, `/visit-retail-sales`, `/visitor-feedback`, `/visit-incidents`, `/reports/visit-profitability`), all license-gated and RBAC-checked (`visitor_coordinator`, `activity_staff`, `cashier` roles added).
- Configurable opening calendar (never hard-coded to any specific weekday), dynamic package/activity builders (Horse Ride and Cheese Making Workshop are seeded examples only), a full booking state machine (draft → confirmed → checked_in → completed, plus cancelled/no_show/refunded) with session-capacity and activity-capacity/animal-welfare/handler-assignment checks enforced at the right step, offline-safe idempotent walk-in bookings, a Farm Shop / Visitor POS that deducts either plain inventory or Mouneh finished-goods stock and posts into core Sales & Finance, and a profitability report computing every §9 formula (visitor revenue, direct visit cost, gross margin, revenue/visitor, activity utilization, retail conversion, average basket value, package profitability) from granular components rather than a booking's stored total.
- 149 backend tests passing (30 new pure-engine tests + 28 new API tests on top of the prior 91); `database/schema.sql` and a new Alembic migration verified against real PostgreSQL 16 (upgrade + downgrade), including a cross-module demo sale that debits real Mouneh Makdous stock.
- Mobile: all 10 screens from the build prompt (Dashboard, Opening Calendar, Package Builder, Activity Manager, Booking Form, Visit-Day Briefing, Visitor Check-in, Farm Shop/POS, Staff Roster & Costs, Profitability Report) behind one new "Farm Visits" nav entry, wired to a real `VisitsProvider` + offline-first `VisitsWriteService` (SQLite + event log + sync queue, same pipeline as the rest of the app), a Dart port of the analytics engine with its own unit tests, and live cross-module POS deduction through the existing `FeedProvider`/`MounehProvider`. Verified via a green GitHub Actions APK build — see `mobile/flutter_app/README.md` "Verification status".

**Next:**
- Wire `VisitsProvider` to read its state back from SQLite on launch (currently write-only persistence, like every other provider in this build).
- Feedback & Follow-up as its own screen if a future spec revision splits it back out of Visitor Check-in.
- Non-goals explicitly deferred per the build prompt: public booking website, online payment gateway, automated WhatsApp sending, QR ticket generation, CRM campaign automation, advanced tax/accounting integrations.

## v0.2.0 — Mouneh & Farm Product Processing Module

Adds the license-gated Mouneh & Farm Product Processing module (tech spec
v0.5) on top of the v0.1.0 MVP.

**Delivered:**
- Backend: `module_licenses`, `mouneh_products`, `mouneh_recipes`, `mouneh_recipe_items`, `raw_materials`, `cost_components`, `production_batches`, `batch_input_consumptions`, `finished_goods_stock`, `mouneh_sale_lines`, `mouneh_events` tables + a pure, unit-tested costing engine (`app/mouneh/costing.py`) + 17 new API endpoints (`/modules/*`, `/mouneh/*`), all license-gated and RBAC-checked.
- Super-user module activation, dynamic product creation (no hard-coded product types — verified in tests by creating a non-Makdous product), versioned recipes (never mutated in place), planned + actual cost calculation, full batch lifecycle (create → consume → complete → finished goods), sales with automatic FIFO stock draw-down and profit calculation, and a profitability dashboard with a continue-production/slow-mover/review-pricing recommendation per product.
- Makdous seeded as example data only, via the same dynamic mechanism a manager would use — 41 new backend tests (costing engine + API), all passing; `database/schema.sql` and a new Alembic migration verified against real PostgreSQL 16 (upgrade + downgrade).
- Mobile: all 7 screens from tech spec v0.5 §6 (Dashboard, Product Builder Wizard, Recipes & Materials, Cost Preview, Production Batches, Finished Goods, Sales & Profitability) behind one new "Mouneh & Products" nav entry, wired to a real `MounehProvider` + offline-first `MounehWriteService` (SQLite + event log + sync queue, same pipeline as the rest of the app), plus a Dart port of the costing engine and its own unit tests. Not yet verified against a real Flutter build — see `mobile/flutter_app/README.md` "Verification status".

**Next:**
- Verify the Mouneh mobile UI against a real Flutter build/APK.
- Wire `MounehProvider` to read its state back from SQLite on launch (currently write-only persistence, like the rest of the app's providers — see `mobile/flutter_app/README.md`).
- Real super-user login/role switching in the mobile UI, replacing the Settings-screen `Switch` stand-in.

## v0.1.0 — Tablet MVP Prototype

First implementation pass following the AI Agent Build Prompt / Technical
Specifications v0.3 build order (design tokens → AppShell → 10 Option C
screens with mock data → local SQLite → core workflow writes → FastAPI
backend + PostgreSQL schema → sync skeleton → rule-based recommendation
engine → tests + docs).

**Delivered:**
- All 10 Option C screens (Flutter) + Animal Digital Twin detail screen, on-brand and data-driven.
- EN/AR + RTL support, offline-first local write pipeline for the core animal/task/feed workflows.
- FastAPI backend: every endpoint from tech spec §12, PostgreSQL schema + Alembic migrations (verified against real PostgreSQL 16), rule-based recommendation engine (6 rules, unit tested and wired to real seeded data), RBAC.
- 66 backend tests passing; mobile widget/unit tests written but unverified (no Flutter SDK in the build environment — see `mobile/flutter_app/README.md`).

See `backend/README.md` and `mobile/flutter_app/README.md` for the detailed
completion boundary, and `product/TRACEABILITY.md` for the requirement map.

**Next (tech spec milestones M4–M9):**
- Wire remaining dashboards (Milk/Egg/Produce/Sales trend panels) to the local SQLite repository layer instead of the static demo dataset.
- Network the sync queue to the backend's `/sync/push` / `/sync/pull` (currently simulated on-device).
- Mobile login/role-switching UI on top of the already-implemented backend RBAC.
- Pilot hardening: exports, onboarding, conflict-review UI.
