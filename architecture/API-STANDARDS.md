# API Standards

## Style
REST/JSON under `/api/v1`. OpenAPI is the machine-readable contract.

## Resources
Use canonical nouns and UUIDs. External aliases are lookup attributes, not resource IDs.

## Writes
Retryable writes use an `Idempotency-Key` or equivalent stable operation ID. Mutation responses return the authoritative resource/result and relevant version.

## Duplicate entries and approvals
Two kinds of duplicate, two defences (`backend/app/core/duplicates.py`):

- **The same request twice** (a retry, an offline replay, a double tap) is answered from the stored response by the `Idempotency-Key` middleware. Every tablet write carries a key — direct, queued and the confirmed resend below share one key per logical write.
- **The same fact entered twice by people** (two workers recording one cow's morning milk, a delivery note typed in again, a mix saved twice) is a new request. Each record workflow looks for an existing record that says the same thing and answers **409** with a `detail` starting `Possible duplicate:` that names what is already there. A real second entry (a second milking, another delivery on the same invoice) is resent with `confirm_duplicate: true`; it is recorded and a `duplicate_confirmed` event names the record it resembles. The tablet asks *Already recorded?* for every form in one place (`core/widgets/duplicate_confirmation.dart`); a queued offline entry refused this way gets *Record anyway* in the sync panel.

| Workflow | Same fact when… |
|---|---|
| Milk | same animal and session, same farm day (farm time zone) |
| Eggs / harvest (both endpoints) | same flock or field + product and quantity within 30 min |
| Feeding event | same subject, kind and per-feed quantities within 30 min |
| Feed delivery (lot receipt) | same supplier + invoice/reference, or same supplier + quantity within 30 min |
| Feed mix | same output and ingredient quantities within 30 min |
| Breeding / pregnancy check | same female, kind/result, same farm day |
| Birth | a birth of the same dam within 30 days (twins are one birth with two newborns) |
| Treatment / medicine administration | same subject and medicine within 12 h |
| Observation | same subject, type and value within 30 min |
| Weight | same animal, same farm day |
| Health case | an open case for the same subject and problem |
| Animal | an active animal of the species with the same name |
| Mouneh sale | same product, quantity, price and customer within 5 min |
| Flock head-count change | same group, kind and quantity within 30 min |
| Task | an open task with the same title for the same person |

Where a repeat can never be right the refusal is a plain 409 with no override: a feed product, group, field or Mouneh raw material with the same name; a lot code already used.

**Approval levels** (permission actions view/create/edit/delete/approve/export/assign/configure) are enforced on the server; the tablet only hides what a person cannot do:

- Taking stock below the ledger (`allow_negative`) needs *approve* on Feed & nutrition or Inventory (Mouneh: Mouneh inventory/production or Inventory) — `deps.ensure_stock_override`.
- A formula or program created/versioned without Feed *approve* is saved as a **draft**; activating needs approve.
- **Employees enter the day's data; the manager approves what changes the farm (v0.7.8).** With *create*, an employee records milk and feedings. Recording a numbered mix (`/feed-mixes`, `/feed-batches` start/complete), the feed list (`/feed-products`), an animal's ration (feeding assignments), reservations and reorder policies, and correcting a feeding (`/feeding-events/{id}/reverse|correct`) need Feed & Nutrition *approve*; correcting a milk record (`/production/milk/{id}/correct`, in place, before/after in the audit log) needs Milk production *approve*.
- Someone without the approval **sends** a mix or a correction as an approval request (`POST /approval-requests`, kinds `feed_mix`, `milk_correction`, `feeding_correction`): it is checked when sent, changes nothing, and is applied — by the same service, as the manager, recording who asked — only when someone with *approve* on its module approves it (`/approval-requests/{id}/approve`); a rejection gives a reason; the employee may withdraw it while it waits. Managers and the employee are notified.
- **Buying feed** (`POST /feed-lots/receive`, stock-in on `/feed/transactions`) needs Feed or Inventory *approve*. An employee sends a purchase request (`POST /procurement/requisitions` with `feed_product_id` lines and `submit: true`; Feed or Inventory *create*); a manager — or Feed *approve* for a feed-only request — approves or rejects it; the delivery is then recorded with `requisition_id`, for that feed, up to the approved quantity + 10%, and closes the request.
- A delivery graded `poor` is received **quarantined**; releasing it is a Feed approval.
- A death is an Animals *edit*; a sale, cull, slaughter or transfer needs Animals *approve*. Correcting a lactation start needs *edit* (Animals or Milk production).
- The farm calendar (`PATCH /farms/me`) needs Settings *configure*.
- **Selling milk (v0.7.9).** `POST /production/milk-sales` and `/milk-sales/{id}/paid` need Sales or Finance *create*, or Milk production *approve*; `/milk-sales/{id}/cancel` needs *approve* on Milk production, Sales or Finance; reading the tank and the sales needs *view* on any of the three. Selling more than the tank holds (`allow_negative`) and `POST /production/milk-tank/adjustments` (a count, or milk out with a reason) need Milk production *approve*. The tank is never stored: stored milk − recorded sales + adjustments.
- **Financials (v0.8.0).** `POST /finance/sales` and `/sales/{id}/paid` need Sales or Finance *create*; `/sales/{id}/cancel` Sales or Finance *approve*. `POST /finance/expenses` and `/expenses/{id}/paid` need Expenses or Finance *create*; `/expenses/{id}/cancel` Expenses or Finance *approve*. `POST /finance/exchange-rates` needs Finance *approve* or Settings *configure*. Reading: sales with Sales/Finance, expenses with Expenses/Finance, `/finance/owed` each half by the same rule, `/finance/profit-loss` with Finance/Reports. Amounts are stored in the farm's currency (USD); an entry in LBP keeps `original_amount`, `original_currency` and `exchange_rate` (the farm's rate for its day — `exchange_rates`, a history — unless the rate used is given). A cancelled sale gets a negative `reversal` row; a cancelled expense keeps `status = cancelled`; nothing is deleted. Milk (tank) and Mouneh (shop) are sold in their own modules.
- **Sales and stock reports (v0.8.0).** `GET /reports/sales` needs *view* on Reports, Sales or Finance. `GET /reports/stock` needs *view* on Reports or one stock area (Inventory, Feed, Mouneh inventory, Animal health, Milk); each section is returned only for its area (all with Reports); values only with Reports/Finance/Sales.
- **Reports (v0.7.9).** `GET /reports/{milk|feed|herd|finance}?start&end` (farm days, both included, at most 366; default the last 30) needs *view* on Reports or on the report's own area (Milk; Feed or Inventory; Animals or Animal health; Finance or Sales). Money in the milk report only with *view* on Reports, Finance or Sales.

## Record consistency
What a record may not state, enforced on the server whatever the client's form allows (`backend/tests/test_record_consistency.py`):

- **Nothing is dated in the future.** Every record endpoint that takes its own date passes it through `app/core/record_time.not_in_future` (5 minutes of clock tolerance): births and acquisitions, milk, eggs, harvests, feedings, deliveries, mixes, observations, weights, doses, health cases, breeding events, exits, head-count changes. Backdating stays allowed. An acquisition is not before the birth.
- **Milk belongs to an animal in milk.** `POST /production/milk` needs an open lactation (409 otherwise, saying to start her milking first), a session of `morning` / `midday` / `evening`, at most 100 L, and a date not before the lactation started. The tablet asks to start her milking (with the calving date) and then opens the milk record.
- **An animal that left the farm takes no new records** — milk, feeding, breeding, group moves, observations, treatments, doses, health cases, and weights dated after it left (a sale weight from before the exit can still be entered).
- **Feed lineage holds.** A raw ingredient (`is_feedable: false`) is not fed directly; a delivery has no negative cost; a mix cannot draw a lot received after the mix's date.
- A harvest's waste is not more than its quantity; a task has a title.

Field-by-field validation refusals (422 with a list) are shown by the tablet as sentences, not as the raw structure.

## Errors
Use consistent machine-readable errors:
```json
{"code":"FEED_USAGE_BLOCKED","message":"Feed is not permitted for the target species.","details":{},"correlationId":"..."}
```

## Concurrency
Use entity/version or ETag-style optimistic concurrency where conflicting writes matter.

## Pagination/filtering
List endpoints use consistent cursor/page conventions chosen once during implementation; document filters/sorts in OpenAPI.

## Validation
APIs enforce permissions, domain state, UOM, compatibility and invariants. UI validation is supplementary.

## Versioning
Breaking contract changes require a new API version or compatible migration/deprecation plan.
