# Releases

## v0.8.14 — Crop cycles: a greenhouse from planting to its actual margin

Master prompt Package 7 (database/CROPS-SCHEMA.md §2, §4–§6, §8; status in its new §11). On the tablet and the web app (Produce & Harvest → a field's **Manage cycle**), enforced by the server. Built on the existing fields, crops, plantings, harvests, stock and Sales & Finance — no second crop or stock model.
- **Growing units.** A field is an open field, a greenhouse, a tunnel or an orchard (`unit_type`).
- **A crop cycle** is a planting: one crop in one growing unit from planting to its last harvest, with a farm-wide code (`CHER-2026-001`) and what it is grown for (sale, feed, seed, mixed). A field keeps every cycle it had.
- **The work on a cycle:** planting, fertilising, spraying, weeding, pruning, irrigation work, harvest preparation, with its labour hours and their cost, and the seeds, fertiliser, plant treatments or supplies it used.
  - Each input leaves stock by its own movement at the item's cost. More than is in stock is refused: the stock line is locked and read afresh, so two people cannot both take the last of it.
  - Feed, medicine and produce are not crop inputs.
  - Work recorded by mistake is reversed by a manager: its inputs return to stock and it stays on file.
  - Work queued on a tablet keeps the time it was done (a tablet clock a few minutes fast is accepted, a date in the future is not).
- **Water:** each irrigation, how much (m³ or L), from which source, and the pumping cost when it is known.
- **Harvest into stock:** a harvest names its cycle and why some was lost; the sellable part goes into the produce stock as before. A closed cycle takes no more work, water or harvest; its produce in stock can still be sold.
- **Sold:** the cycle's produce sold from its sheet is a sale of the farm (Sales & Finance, *Crops*), in USD or LBP, paid now or owed, and leaves the produce stock. More than is in stock is refused, under the same lock.
- **Its actual margin:** what its produce sold for, against its inputs, labour, pumping and the expenses linked to it; harvested, lost, sold, and the cost per kg harvested.
  - A cost that is not known (an input with no price, labour not priced, pumping not metered) is named as unknown, never counted as free.
  - It is read from the records each time; nothing is kept on the side.
- **The acceptance case** (test): a 400 m² greenhouse of cherry tomatoes.
  - Planted with 2 packets of seed (USD 10) and 6 h of labour (USD 30); fertilised with 20 kg of NPK (USD 30) and 2 h (USD 10); 12 m³ of well water (USD 8 pumping).
  - 500 kg harvested, 20 kg lost to split fruit, 480 kg into stock; 400 kg sold at USD 1.20.
  - Revenue USD 480, known costs USD 88, **margin USD 392**, USD 0.176 per kg harvested.
- **Who:** the field team (Agriculture or Produce & Harvest) records work and water; Sales or Finance sell; whoever reads the farm's money (Finance, Sales or Reports) sees the margin; closing needs Agriculture edit, reversing work Agriculture approval. Another farm sees nothing.
- Server: **migration `d9b1c3e5f7a2`** (after `c7e9a1b3d5f8`).
  - Schema: `fields.unit_type`; `crop_plantings.cycle_code` (unique per farm), `production_purpose`, `closed_at`; tables `field_operations`, `field_operation_inputs`, `irrigation_events`; `harvest_records.crop_planting_id`, `loss_reason`; `sales.crop_planting_id`.
  - Endpoints: `GET /crop-inputs`; `GET/POST /crop-plantings/{id}/operations`, `POST …/operations/{op}/reverse`; `GET/POST …/irrigation`; `POST …/sales`; `GET …/margin`; `POST …/close`.
  - Events: `field_operation_completed`, `field_operation_reversed`, `irrigation_recorded`, `crop_produce_sold`, `crop_cycle_closed`; audit entries for work, reversals and closing.
- Tests: backend +10 (`test_crop_cycles.py`) and the same on PostgreSQL 16 with two-thread races for the last fertiliser and the last produce (`test_crop_cycles_pg.py`, a new step in `scripts/verify-all.sh`); app +13 (`test/records/crop_cycles_test.dart`).
- Not in this release: seeds and fertiliser are traced to their stock line and its movement, not to a supplier lot (generic stock has no lots yet); planned work; field observations (§7); labour from the employees' time sheets.

## v0.8.12 — Buying feed: suppliers' prices, purchase orders, deliveries against them, and what is still owed

Master prompt Package 2 (database/PROCUREMENT-SCHEMA.md §4, §7, §8). On the tablet and the web app (Feed → **Buying**), enforced by the server. Builds on v0.8.9's supplier bills.
- **Suppliers' prices.** Several suppliers can sell the same ingredient at different prices. Each supplier's quote is kept per item (the manager sets it; a new price replaces the quote and the old one stays in the audit log). The list is cheapest first in USD at today's rate, with what each supplier's last delivery cost.
- **Purchase orders.**
  - An order goes to one supplier at a price per line — the supplier's quote when none is given, and an LBP quote never prices a USD order.
  - It is placed direct, or from an approved purchase request (which becomes *ordered*, then *received*).
  - A worker drafts it and the manager places it: the approval and the authority behind it are kept. Orders are numbered `PO-000001` per farm.
  - Orders are in USD or LBP at an agreed rate, paid on each delivery or on credit.
- **Deliveries against an order**, partial or whole: what came, what was rejected (with the reason) and the quality seen, numbered `GR-000001`.
  - The accepted goods become a feed lot through the stock ledger, with the supplier, the price ordered, the day, the delivery note and the quality. A poor delivery is held until released.
  - The supplier's bill is posted for what was accepted.
  - More than 10% over what was ordered is refused. An order with goods received is closed short (the rest is not coming), not cancelled.
  - Two people receiving the last of an order at once cannot both take it (the order's row is locked).
- **The match** (*Ordered vs delivered*): per line and for the order, it shows:
  - ordered, received, accepted, rejected and still to come;
  - the value accepted at the price ordered, against what was billed, paid and is still owed;
  - any difference, named, never hidden.

  Payments are made on the bills, in parts (v0.8.9).
- **A mix stays traceable to its suppliers.** A lot's trace and a mix's ingredient lots now show each lot's supplier, cost, day, quality and the order, receipt and delivery note it came on.
- Server: **migration `c7e9a1b3d5f8`** — tables `supplier_items`, `purchase_orders`, `purchase_order_lines`, `goods_receipts` and `goods_receipt_lines` (accepted + rejected ≤ received, checked by the database).
  - Endpoints, under `/procurement`: `GET/POST supplier-items`; `GET/POST purchase-orders`; `GET purchase-orders/{id}`; `POST purchase-orders/{id}/approve | cancel | close | receive`; `GET purchase-orders/{id}/match`.
  - Events: `purchase_order_created`, `purchase_order_approved`, `purchase_order_cancelled`, `purchase_order_closed`, `goods_received`, `goods_rejected`, `supplier_price_set`.
- Tests: backend +10 (`test_procurement_orders.py`), and the same on PostgreSQL 16 with a two-thread receipt race (`test_procurement_orders_pg.py`); app +4 (`test/records/purchase_orders_test.dart`).
- Not in this release: medicines on purchase orders (they keep v0.8.9's receipt with its bill); supplier contacts and addresses; a supplier-return document (returns stay v0.8.9's *Return to supplier* on a lot, credited on its bill).

## v0.8.9 — Purchases in the books: what was accepted is stock, what is owed is owed, cash is what was paid

Audit 2026-11-25 (I-9, I-14). On the tablet and the web app, enforced by the server:
- **Stock is what was accepted.** 500 kg of corn delivered, 20 kg rejected, at USD 0.50: 480 kg in stock worth **USD 240** — the lot, the stock report and the supplier's bill all say 240, never 250.
- **Each priced delivery has its supplier's bill** (feed and medicine), for what was accepted, in the invoice's currency (an LBP invoice keeps its LBP and the rate of the delivery's day; the stock is valued in dollars). *Paid on delivery*, *On credit* or *Part paid now* is chosen on the delivery form.
- **Cash is what was actually paid, on its day.** Bought on credit: cash out USD 0, USD 240 owed. USD 100 paid later: cash out USD 100, **USD 140 still owed** (*Who owes what*), the stock untouched. A bill is paid in parts from Sales & Finance (*Pay…*, any amount, USD or LBP at the day's rate — an LBP bill paid in LBP is settled in LBP whatever the rate did; *Mark paid* pays the rest). More than is owed is refused; a retried request is recorded once, a repeat is asked; two people paying the same bill at once can't pay it twice, and two reversing the same payment at once reverse it once.
- **Never counted twice.** A bill for stock is not a cost: feed is a cost when it is fed, medicine when it is received (for what was accepted) — the farm's one policy; a delivery no longer also counts as cash out on arrival. Reports' expenses leave stock bought out.
- **Returns, refunds, corrections.** Goods sent back (*Return to supplier* on the lot, or a stock return naming the lot) leave the lot's stock and are credited on its bill; when the bill was already paid, the supplier's refund is recorded as money back. A payment recorded by mistake is reversed by a negative row and stays on file; a bill with payments is cancelled only once they are reversed. Every step is audited.
- **Deliveries from before this release** have no bill. Profit and loss no longer assumes they were paid on arrival; a manager reviews them once (`GET` / `POST /finance/reconciliation/purchases`, docs/runbooks/PURCHASES-RECONCILIATION.md): the expense that already paid for one is linked (it stops being a second cost), or the manager says it was paid on arrival or is still owed. Nothing is paid on the farm's behalf; nothing already recorded is rewritten.
- Server: **migration `b5d7f9a1c3e6`** — table `supplier_payments` (payments, refunds, credit notes; reversal links), unique bill per delivery on `expenses (linked_entity_type, linked_entity_id)`; expenses gain `partial`. `POST /feed-lots/receive` and `POST /pharmacy/lots/receive` take `payment` (paid | credit | partial), `paid_amount`, `due_date`, `invoice_reference`, `currency`, `exchange_rate` and answer with the `bill`; lots add `accepted_value`; `POST /feed-lots/{id}/return`; `POST /finance/expenses/{id}/payments` (+ `GET`), `POST /finance/supplier-payments/{id}/reverse`; expenses add `amount_paid`, `balance_due`, `balance_original`, `credited`, `stock_purchase`, `lot_id`. Tests: backend +18 (`test_purchase_payables.py`) and the same 18 plus two-thread races on PostgreSQL 16 — two payments of one bill, two reversals of one payment (`test_purchase_payables_pg.py`), app +4 (`test/records/purchase_payables_test.dart`).

## v0.8.8 — Mouneh sales in the farm's books: one sale, its revenue once, its cash when paid

Audit 2026-11-25 (I-8). On the tablet and the web app, enforced by the server:
- **Every Mouneh sale is in Sales & Finance.** Before, a $7 jar sold in the Mouneh shop showed $7 in Mouneh and nothing in Sales, *Who owes what*, the Sales and Finance reports or profit and loss (the demo farm's $265 of Makdous sales were missing from its P&L). Now each sale is one sale in the books, *Mouneh* activity, linked to the Mouneh sale: the product, quantity, buyer, the moment it was sold, the currency (an LBP sale keeps its LBP amount and the rate) and what the jars cost to make. A $7 sale adds exactly $7 to revenue, Mouneh revenue and cash in — once; a retried request records one sale, a repeat typed in again is asked about.
- **Paid now, not paid yet, or part paid.** A sale not paid in full names its buyer and is owed until paid: *Mark paid*, or *Receive payment* in Sales & Finance — what is due is the balance, and *A part payment — the rest is still owed* keeps the rest owed instead of booking a deduction. Each part is its own receipt, counted as cash on the day it is received.
- **Cancel a Mouneh sale** (manager: Mouneh, Sales or Finance approval), in Mouneh or in Sales & Finance: the jars go back on the shelf, the revenue is undone by a negative row, what was received is refunded; the sale stays on file with its reason. A jar sold in the farm shop during a visit is in that visit's purchase (once) and is cancelled in Farm visits.
- **A sale made offline keeps its time:** the tablet sends the moment of the sale, so one that waited for the network is revenue on its own day.
- **Sales from before this release** are put in the books by a reconciliation the manager runs once — a dry run, then apply (`GET` / `POST /finance/reconciliation/mouneh-sales`, docs/runbooks/MOUNEH-SALES-RECONCILIATION.md): each posted once on the day it was sold (paid then, or still owed), farm-shop jars linked to their purchase instead of posted twice, nothing on a line rewritten, every step audited; running it again changes nothing. Mouneh's own profitability leaves cancelled sales out.
- Server: **migration `a3c5e7f9b1d2`** — `mouneh_sale_lines.status` (recorded | cancelled), `cancel_reason`, `cancelled_at`, `cancelled_by`, an index on `sale_id`; `customer_payments.sale_id` (a receipt toward one sale). `POST /mouneh/sales` takes `sold_at`, `payment_status` (paid | pending | partial), `amount_paid`, `buyer_name`, `currency`, `exchange_rate`; `POST /mouneh/sales/{id}/cancel`; `POST /finance/payments` takes `part_payment`; sales add `amount_paid`, `balance_due`, `mouneh_sale_id`, `cost_of_goods`; *Who owes what* and the reports count balances. The Mouneh production cost is kept on each sale and in Mouneh's profitability, not booked a second time as a P&L cost (the ingredients bought are the expenses). Inventory movement, revenue and cash receipt stay three records. Tests: backend +19 (`test_mouneh_revenue.py`) and the same 19 on PostgreSQL 16 (`test_mouneh_revenue_pg.py`), app +9 (`test/mouneh/mouneh_sales_books_test.dart`).

## v0.8.7 — Feeding records you can trust: eaten never exceeds given, one round counted once

Audit 2026-11-25 (I-7, I-12). On the tablet and the web app, enforced by the server:
- **What was eaten cannot be more than what was given.** A feeding with 9 kg consumed of 5 kg offered is refused before any stock moves — new feedings, corrections, an employee's correction request (*What was eaten cannot be more than what was given. Check both amounts.*; the quick entry also refuses more left over than was given). Amounts in grams are converted before comparing, and what was eaten is stored in the feed's stock unit (before, 4000 g eaten of a feed kept in kg was stored as 4000 kg). A refusal or an intake estimate recorded on its own later is never a second issue of stock, and cannot be more than what that animal or group was offered that farm day (refusals of a day add up; 9000 g estimated of 5 kg offered is refused).
- **One feeding round is not counted twice.** A cow fed with her group at 06:00 and on her own at 06:05 (or the other way round), the same feed, within an hour, is asked about: *Fed already this round? Luna is fed with Dairy Herd's ration, and Dairy Herd was given Corn Silage at 06:00.* — *Record as additional feeding* or *Don't record*. Not asked for a feed she has a supplement of, a cow on her own ration, another feed, a refusal, the next round, or when the group's head count already leaves her out. Asked in English or Arabic from what the tablet holds (offline too); the server checks again — an overlap only it can see (another tablet's feeding) gets the same question, and a feeding that waited offline is asked about in the sync panel. **An extra feeding says why** (*Why is it extra?*, required, worker or manager alike): the reason and who gave it are kept on the record and on the feeding the manager reads.
- One ration per head (v0.8.6), refusals apart from fed, the farm's own days and the v0.8.4 stock ledger are unchanged; a confirmed extra feeding is the animal's own feeding and moves its own stock.
- Server: **no migration.** `POST /feeding-events` takes `confirm_additional_feeding` (`confirm_duplicate` also confirms) with `additional_feeding_reason`, and answers an overlap with 409 *Possible duplicate: …* — asked again while the reason is missing. Every 409 *Possible duplicate* now also names what confirms it (`code`, `confirm`, `reason`) and feed refusals carry a `code` (`more_than_given`), so the app asks and translates by name, not by the English sentence; the tablet keeps them with a queued write for the sync panel; a confirmed one writes `feeding_additional_confirmed` (the feedings it overlaps, the feeds, who confirmed). The daily plan's group lines add `covered_animal_ids`. The demo farm's +2 kg supplement for Bella now starts three days back, like the feedings of it. Tests: backend +21 (`test_feeding_event_integrity.py`) and the same 21 on PostgreSQL 16 (`test_feeding_event_integrity_pg.py`), app +10 (`test/records/feeding_event_integrity_test.dart`).

## v0.8.6 — One feeding plan the reports agree with: one ration per head, fed means it left the store, the farm's own days

Audit 2026-11-25 (I-4, I-5, I-6). On the tablet and the web app, decided by the server (architecture/ADR-006):
- **Each animal is planned once.** A herd's line counts only the cows its ration feeds. A cow on her own ration, or in a status group with its own ration (*Pregnant cows*), is fed there and named on the herd's line: *Dairy Herd · 2 of 3 head — Planned on their own line, not in this count: Clover (on her own ration)*. Before, she was planned twice: on the demo farm, putting Clover on her own ration planned 76 kg of dairy mix for three cows that eat 56.
- **What each adjustment does:** a *supplement* adds on top of her ration (she stays in her group's count); an *override* replaces one feed's quantity (she gets her own line — her group's ration as adjusted for her); a *restriction* takes a feed away, and a group's restriction binds every cow in it, also when she is fed on her own.
- **Fed means it left the store.** Only an offered or delivered feeding is fed. A refusal (or an intake estimate) is kept and shown apart — *Refused (recorded, not fed)* on the animal or group — and never counted as fed or costed, in the plan, *last 7 days*, the costs, the reports, the reorder forecast or a lot's trace. It is not a feeding round either (*1/2 today*, My Day, the quick entry).
- **The farm's day, in Beirut.** Every *today*, *yesterday* and day-by-day figure is the farm's calendar day: a feeding at 00:30 is that day, not the evening before as UTC has it; the days the clocks change are 23 and 25 hours long. The daily plan can be read for any past day (`?day=`), with the rations and groups as they were then; a feeding entered late counts on the day it was given, also in the forecast. The tablet and the browser take *today* from the farm, whatever zone the device is set to.
- Group feedings default to the heads the group's ration feeds; a partial feeding (*2 head*, one at the vet) stays the group's and is never split over the cows.
- Server: **no migration.** `GET /feeding-plan/today?day=YYYY-MM-DD`; the plan adds `timezone`, `from`, `to`, `unplanned_fed`, and per line `member_count`, `excluded_heads`, `basis` (animal lines) and `fed`; a subject plan adds `refused_7d` and `consumed_7d` (`fed_7d` and `feed_cost_7d` are stock-moving only); `feeding-history?days=N` and `feed-costs?days=N` are N farm days. Tests: backend +23 (`test_feeding_plan_policy.py`) and the same 23 on PostgreSQL 16 (`test_feeding_plan_policy_pg.py`), app +9 (`test/records/feeding_plan_policy_test.dart`).

## v0.8.5 — Milk judged at the time it was milked: withdrawals and lactations from the history

Audit 2026-11-25 (I-3, I-15). On the tablet and the web app, enforced by the server for every way milk arrives — the form, the cow queue, the quick entry, a correction, an offline tablet catching up:
- **A withdrawal is judged at the milking, not today.** Milk entered today for a day inside a withdrawal that has since ended is refused as stored or sold and accepted only as *withheld* — before, it went into the tank. The withdrawal comes from the dated doses and treatments (overlapping medicines each count; a group's treatment covers the animals that were in the group then); a shorter treatment no longer cuts a longer withdrawal on the animal.
- **Milk the records cannot vouch for is held, not sold.** When only the animal's withdrawal date is known (no dated treatment), or a dose was reversed, the milk is kept but **held for review** — not in the tank, not sold — until a veterinarian or the farm manager releases it (saying why) or withholds it: Milk page → *Milk held for review*. Milk a recorded withdrawal covers cannot be released. A dose or treatment entered late puts the milk it covers on hold and tells the manager; no sale is changed.
- **The milk form asks before saving.** Choosing a day and a milking, the form shows *Under withdrawal at this milking — recorded as withheld*, or *It will be held for review*, or that she was dry then.
- **A cow dried off yesterday** can still have her milk from three days ago entered (it belongs to the lactation that has ended); milk after the dry-off or before the lactation began stays refused. Each milk record now names its lactation.
- **The tank and the collector see only milk that may be sold** (stored and saleable or released); the milk report adds *held*.
- Older records are not reclassified: the tank, handovers and sales read as before. `GET /production/milk-safety/review` lists older milk the history now places inside a withdrawal, for the manager and the vet to decide — docs/runbooks/MILK-SAFETY-REVIEW.md.
- Server: **migration `e8a0c2e4b6d9`** — `milk_records.withdrawal_check`, `release_status`, `safety_note`, `checked_at`, `reviewed_by/at`, `review_note`, `lactation_episode_id`; `animals.withdrawal_known_since`. `GET /production/milk-safety`, `GET /production/milk-held`, `POST /production/milk/{id}/review`, `GET /production/milk-safety/review`; `POST /sync/push` milk is checked like a live entry. Decision record: architecture/ADR-005 (amends PRODUCTION-SCHEMA §8 and §10). Tests: backend +21 (`test_milk_safety.py`), app +11 (`test/records/milk_safety_test.dart`).

## v0.8.4 — Feed stock you can trust: one ledger, approved exceptions, no double issue

Audit 2026-11-25 (I-1, I-2, I-13). On the tablet and the web app (one codebase), enforced by the server:
- **A named lot is the whole answer.** A feeding or a mix that names a lot holding too little is refused, and nothing is recorded — it is never made up from another lot or from no lot (before, the rest came out with no lot, silently). Without a lot named, feed is taken oldest delivery first, never from a held (quarantined, blocked, recalled, expired) lot, never from what is reserved for another animal or group.
- **Recording past the stock is the manager's, with a reason.** *Stock not entered yet — record anyway* now asks *Why?* (required) on the feeding form, the quick entry and the mix form; approving an employee's mix that is short asks the same. What no lot covers is kept as an **exception**: how much, for which feeding or mix, who recorded it, who approved it, why.
- **One stock figure, its parts named.** The stock line, the lots and the reports now always agree: *on hand* is every movement added up. A feed with feed given beyond its stock shows **Fed with no lot 30 kg**, *In lots* and *Fed with no lot (to reconcile)*, and those kilos are not available until the manager **reconciles** them — *It came from a lot* (a delivery entered later gives them up), *The stock was there* (never entered), or a **count** (which settles them all; the count form says so). Undoing the feeding closes its exception too.
- **Two people feeding the last kilos at once** can no longer both take them: the second waits for the first and is told what is left.
- Corrections never take a lot below zero; a return or a spill comes out of the lot named (or the oldest); a count posts its corrections instead of overwriting the stock line. A feed sold in the farm shop is taken from its lots; a device can no longer push a bare feed quantity.
- Offline: a reconciliation made without the connection shows at once and waits in the list (*Feed reconciliation*); an override queued offline carries its reason.
- Server: **migration `d6f8a0c2e4b7`** — table `feed_stock_exceptions`; `inventory_transactions.stock_exception_id`, `actor_user_id`; a backfill that keeps every stored stock line and existing movement and turns older gaps into explicit movements and open `legacy_untraced` exceptions (docs/runbooks/FEED-STOCK-RECONCILIATION.md §6). `override_reason` on `POST /feeding-events`, `/feed-mixes`, `/feed-batches/{id}/complete`, `/feeding-events/{id}/correct`, `/approval-requests/{id}/approve`, `/feed/transactions`; `GET /feed-inventory/exceptions`, `POST /feed-inventory/exceptions/{id}/resolve` (Feed or Inventory *approve*), `GET /feed-inventory/integrity`; availability adds `lot_on_hand`, `untraced`, `open_exceptions`; `POST /feed-inventory/adjustments` returns every movement it posted. `python -m app.feed_stock_integrity [--rebuild --as <user>]` and `docs/runbooks/feed-stock-reconciliation.sql` check a database. Tests: backend +29 (`test_feed_stock_integrity.py` 21, `test_feed_stock_concurrency_pg.py` 6 on PostgreSQL 16, `test_feed_stock_migration.py` on SQLite and PostgreSQL 16), two override tests now give a reason; app +11 (`test/records/stock_integrity_test.dart`).

## v0.8.3 — Feed: count the stock on inspection; only concentrate, silage and hay & straw are fed; the cost of every feeding

On the tablet and the web app (one codebase), enforced by the server:
- **Count the stock on inspection.** Feed → *Stock* → **Count stock** (or a line's menu, or a feed on *Raw materials & lots*): choose the feed, see what the records say, type what is there. The form says the difference before saving (*140 kg less than the records*). The count becomes the stock; the records are never edited — the difference is posted as a count correction on the lots (the stock left is the newest, as feed is used oldest first; a surplus goes to the newest lot), with who counted, when (today, or an earlier day) and what was seen. The same count sent twice changes nothing. Counting is the farm manager's (Feed or Inventory *approve*).
- **What the animals are fed: concentrate, corn silage, hay & straw.** Every feed now says what it is — *Concentrate*, *Corn silage*, *Hay & straw*, or *Raw material — for mixing*. Only the first three are offered on the feeding forms (animal, group, quick entry, the cow queue, feeding programs); grain, meals, minerals and premix go into a mix and the server refuses them on a feeding. The purchase form and *New feed* ask *What is it?* (a raw material unless it is one of the three); before, every feed bought on the purchase form was marked as fed, so grain appeared on the cows' feeding form. The manager can change a feed's type (*Type & price*); a feed still in a ration in force cannot be made a raw material until the ration changes. Feeds already on a farm are typed by the migration from their standard row, name and category; a feed a ration in force still feeds as it is stays a feed.
- **Feed prices and the cost of each feeding.** Each feed has a price per kg (*Type & price*, or *Set price* on Feed → *Costs*). A feeding is costed from what it takes from the stock: the price of the delivery it comes from, the cost of the mix it was made in, else the feed's price — so corn silage and straw grown on the farm or found at a count are costed too. The feeding forms show *Cost of this feeding: $3.84* as the amounts are typed, and name any feed without a price. *Costs* lists every feed's price (a feed without one is named), and the cost of each animal or group per day. The feed report adds *Feed cost per day*, *Fed without a price* and *Feed cost per animal and group*.
- **Milk date.** *Milked on* (today by default, up to 60 days back) is on both milk forms — *Record milk* and the cow queue / quick entry — and the cow-after-cow entry keeps the day chosen. Checked again in the browser against the server: milk entered for an earlier day is recorded on that day.
- Offline: a type or price changed without the connection shows at once; a count waits in the list (*Stock count*) and is applied when it reaches the server.
- Server: **migration `c4e6a8b0d2f5`** — `feed_products.ration_type` (concentrate | silage | hay_straw, null = raw material), with the backfill above. `POST /feed-inventory/counts` (Feed or Inventory *approve*); `POST|PATCH /feed-products` take `ration_type` (an older client's `is_feedable` is read from the name and category; a grain stays a raw material) and `PATCH` takes the price `default_unit_cost` (also the stock line's cost); products report `ration_type` and `current_unit_cost`; `GET /reports/feed` adds `by_subject`, `cost_by_day`, `feed_cost_per_day`, `unpriced_kg`. The demo farm's barley and minerals are raw materials (the bull and ewe rations take the dairy concentrate instead; the dry-cow ration no longer lists minerals). Tests: backend +9 (`test_feed_types_counts_costs.py`; two feeding tests now feed straw, not barley), app +14 (`test/records/feed_types_counts_test.dart`); the tablet-size sweep covers the two new forms.

## v0.8.2 — Each cow's number in the milking queue; each cow's morning and afternoon in the milk report

On the tablet and the web app (one codebase):
- **Each cow's number in the queue.** *Cow queue → Queue numbers* (the farm manager): every cow in milk with a number field — the order the cows come in to be milked. *Number them 1, 2, 3… in this order* fills them in; any number can be changed or cleared; a number given to two cows is refused (on the form and by the server). A dry cow keeps her number for her next lactation and is listed so it can be taken from her. Cows without a number come after the numbered ones, by tag, as before.
- **The queue follows the numbers** — the cow queue, *Follow the queue*, the quick entry's round and the milk report all list the cows by their number.
- **Record milk opens the next cow by herself.** *Record milk* (Milk page, +) offers the next cow still to milk at this time of day on top (*Next: No. 1 · Bella*) and shows each cow's number; typing her number finds her. After each save the next number opens on the same milking and day — no picking again — with *Skip* (come back to her later) and *Stop*. The form says where she is: *No. 3 · Cow 3 of 12 in the queue*, and who comes next.
- **A number typed in opens her cow.** In the quick entry of a milking, typing the cow's queue number (*4*, *No. 4*, *#4*, or in Arabic digits) opens her; a tag or identifier always wins over a number. Her number is on her card.
- **The milk report, each cow.** *Per animal* now shows each cow's **morning** and **afternoon** (or evening) litres over the period, with her number; a new table **Each cow, day by day** lists every cow's morning, afternoon and total for each day (a period up to a month), the latest day first, the cows in queue order. Periods **Today** and **Yesterday** are added. On the Milk page, *View all* and *Each cow — every milking* under the top producers (they did nothing before) open the milk report on today. A long table is cut into parts, so the PDF prints a month of every cow.
- The Milk page names the second milking as the farm does (*Afternoon milking*); an animal under withdrawal opens her record when tapped (the *View Animal Record* button did nothing).
- Who may do what: setting the numbers — Animals *edit* or Milk *approve* (the manager); employees follow them. Every change is in the audit history and the event log.
- Offline: numbers set without the connection show on the queue at once and are sent when it is back.
- Server: **migration `b3d5f7a9c1e4`** — `animals.milking_queue_number`. `PUT /animals/milking-queue` (safe to resend); `GET /reports/milk` adds `morning_l`, `midday_l`, `evening_l` and `queue_number` per animal and `by_animal_day` (null for a period over 31 days). Tests: backend +8 (`test_milking_queue.py`), app +15 (`test/records/milking_queue_test.dart`); the tablet-size sweep covers the queue-numbers form.

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
