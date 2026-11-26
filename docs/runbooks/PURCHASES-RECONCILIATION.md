# Runbook — deliveries recorded before v0.8.9 (audit I-9, I-14)

Before v0.8.9 a priced feed or medicine delivery counted in profit and loss as **cash out on the day it arrived, for everything delivered** (500 kg at USD 0.50 = USD 250, the 20 kg rejected included) and was owed to nobody. A farm that also recorded the supplier's invoice as an expense counted it a second time. From v0.8.9 each priced delivery has one supplier bill (`expenses`, linked to its lot) for what was accepted; cash is only what was paid (`supplier_payments`).

Deliveries recorded before have no bill, so they are now neither cash out nor owed until a manager decides.

1. **Dry run** — `GET /api/v1/finance/reconciliation/purchases` (Finance *approve*). Nothing is written. Each item is a delivery with no bill: product, date, supplier, accepted quantity, `accepted_value` (accepted × price) and `received_value` (what the old reports counted), and
   - `proposal: link` with the `expense_id` that probably paid for it (same kind, within a week, the accepted or the full value, same or no supplier) — today it is counted twice;
   - `proposal: decide` — nothing on record says how it was paid.
2. **Apply** — `POST /api/v1/finance/reconciliation/purchases` with `{"decisions": [{"lot_id": …, "action": "link", "expense_id": …}, {"lot_id": …, "action": "paid_on_receipt"}, {"lot_id": …, "action": "on_credit"}]}`:
   - `link` makes that expense the delivery's bill: it stops being a cost (the stock is costed when fed or received) and its payment is counted once, as before; its amount is never changed;
   - `paid_on_receipt` bills it for what was accepted, paid on the day it arrived (as the manager states);
   - `on_credit` bills it as still owed (it appears in *Who owes what* to pay from Sales & Finance).
3. **Check** — run the dry run again: what was decided is gone; deliveries left are still undecided. Applying the same decision twice does nothing.

Each step is audited (`purchase_bill_linked`, `purchase_billed` with `reconciliation`, one `purchases_reconciled`).
