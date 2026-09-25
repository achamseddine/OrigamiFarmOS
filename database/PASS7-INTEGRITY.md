# Pass 7 Integrity & Cross-Domain Behavior

## Production → Sales
Production records say what animals/groups produced. Inventory lots say what physical saleable stock exists. Sales delivery says what left the farm. Never overwrite production to reflect sales.

## Sales → Inventory
Sales order reserves stock only through explicit inventory reservation policy. Order creation alone does not reduce on-hand. Posting stock delivery creates an inventory ISSUE transaction atomically.

## Live animals
Live-animal sale uses Animal identity and a controlled livestock ownership/status/disposition transaction. Do not model a cow/horse/sheep as kilograms of inventory merely to sell it.

## Health withdrawal
Milk/eggs/meat-equivalent product subject to active withdrawal/restriction cannot be released into eligible sale stock. Restricted production may still be truthfully measured.

## Traceability
For milk/crop/feed lots, customer delivery should be traceable backward to source lot/production/harvest and forward from a recalled lot to affected deliveries/customers.

## Sales → Finance
Delivery and invoice remain separate. Invoice and payment remain separate. Partial delivery, partial invoice and partial payment are supported.

## Procurement → Cash
Supplier payment may reference future supplier invoices/accounting documents. Paying a supplier does not alter PO/receipt/inventory history.

## Cost → Margin
Margin is derived from documented cost/revenue facts and methodology. It does not mutate source records.

## Cash controls
Posted payments/cash transactions are immutable; correction uses reversal. Account balance is derived from posted movements, not manually overwritten.

## Example
```text
Cow group → 1,800 L milk production
→ 1,760 L eligible sale stock after disposition/loss
→ Customer order 1,000 L
→ Delivery 600 L + later 400 L
→ Invoice $700
→ Customer pays $400 + $300
```
All quantities and money stages remain distinct and reconcilable.

## Acceptance
1. Partial order/delivery/invoice/payment works.
2. Stock decreases only on posted delivery, not order/invoice.
3. Customer AR is reconstructable.
4. Returned stock requires quality disposition.
5. Restricted output cannot silently enter saleable stock.
6. Live-animal sale preserves animal history.
7. Revenue, cash and operational margin remain distinct.
