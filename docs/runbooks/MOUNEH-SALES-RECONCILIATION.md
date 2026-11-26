# Runbook — Mouneh sales recorded before v0.8.8 (audit I-8)

Until v0.8.8 a sale in the Mouneh shop moved the jars and wrote a Mouneh sale line, but never reached the farm's books: it was missing from Sales & Finance, the owed list, the Sales and Finance reports and profit and loss (a $7 sale showed $7 in Mouneh and $0 everywhere else). From v0.8.8 every new sale posts one canonical sale (`sales.product_type = 'mouneh'`, linked from `mouneh_sale_lines.sale_id`). The sales recorded before are put in the books by a reconciliation that a farm manager runs once, after the upgrade.

## What it does

| Line on record, not in the books | What happens |
|---|---|
| A sale in the Mouneh shop | **Posted**: one sale on the day it was sold (`sold_at` of the line), its revenue (`revenue`, in cents), quantity, product, customer; paid on that day (default) or still owed. Its production cost stays on the line (`cost_of_goods` = quantity × cost per unit). |
| A jar of a farm-shop purchase during a visit (written in the same moment as the purchase, retail, no discount, no customer, within what the purchase came to) | **Linked** to that purchase's sale (`visitor_retail`), which already holds its revenue — never posted again. |
| A line that fits more than one farm-shop purchase, or more than its purchase came to | **Left for a look** (`needs_review`); nothing is written. |
| A cancelled line | Ignored (it sold nothing). |

Nothing on a line is changed except the empty link: quantity, price, discount, revenue, margin, cost and date stay as they were. Each step is audited (`mouneh_sale_posted`, `mouneh_sale_linked`, and one `mouneh_sales_reconciled` for the run, with what was posted, linked and left). A line is linked with a conditional update (`… WHERE sale_id IS NULL`), so two runs at once cannot both post it; a second run finds nothing more to do.

## How

Farm manager (or anyone with Finance *approve*):

1. **Dry run** — `GET /api/v1/finance/reconciliation/mouneh-sales`. Writes nothing. Read:
   - `to_post.count`, `to_post.amount` and `to_post.items` (each with `mouneh_sale_id`, `sold_at`, `product_name`, `quantity`, `amount`, `cost_of_goods`);
   - `farm_shop.items` (each with the visit purchase's `sale_id`);
   - `needs_review` (with `problem`);
   - `already_in_books`.
2. Decide how the past sales were paid. A shop sale was normally paid at the till: **paid** (cash in on the day of the sale). If they were sold on credit and the money is still to come, post them as **pending** (they appear in *Who owes what*).
3. **Apply** — `POST /api/v1/finance/reconciliation/mouneh-sales` with `{"payment_status": "paid"}` (or `"pending"`). The answer is the same report with `posted` (the new sale ids).
4. Check: run the dry run again — `to_post.count` and `farm_shop.count` are 0. In Sales & Finance → Profit & loss, the *Mouneh* activity's revenue now equals the Mouneh shop's revenue for the same months, less the farm-shop jars (those are under *Visits*, in the visit's purchase).

Lines left in `needs_review` are listed with their ids; decide each one with the farm (a farm-shop jar or a shop sale) before posting anything by hand.

## After v0.8.8

- A sale is paid now, owed by a named buyer, or paid in part (the part is a receipt, `customer_payments.sale_id`; the rest is received in Sales & Finance — *Receive payment*, with *A part payment — the rest is still owed* for another part).
- Cancelling a Mouneh sale (in Mouneh, or in Sales & Finance) puts its jars back on the shelf, undoes its revenue with a negative row and refunds what was received; the sale stays on file with its reason.
- Revenue, receivables and cash are separate: revenue on the day of the sale, receivables what is still owed, cash in on the day each payment is received.
