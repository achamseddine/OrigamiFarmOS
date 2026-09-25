# Pass 5 Integrity & Cross-Domain Behavior

## Procurement → Inventory
Only posted accepted goods create inventory RECEIPT transactions. PO quantities never create stock. Rejected goods never enter eligible on-hand stock unless a controlled quarantine receipt policy explicitly records physical custody.

## Feed → Procurement
Feed forecast/reorder is advisory demand. It may create a DRAFT requisition with provenance. Human/workflow approval remains required.

## Health → Procurement
Medication/vaccine demand may create requisitions but clinical authority and purchasing authority remain separate.

## Procurement → Costing
PO line stores agreed price; goods receipt links physical quantity; costing snapshots actual accepted-lot basis. Freight/tax/discount allocation methodology must be explicit.

## Inventory → Costing
Quantity ledger and cost layers are separate but linked. Reversing quantity movement requires corresponding cost reversal. Never edit historical unit cost in-place after consumption.

## Costing → Production
Per-unit production cost is a projection with methodology/version. It cannot modify production quantity or financial accounting.

## Farm scoping
Supplier may be organization-wide; requisitions, POs, receipts, inventory and costs are farm-scoped. Cross-farm receipt or allocation is blocked unless a future explicit inter-farm transfer workflow exists.

## Idempotency
Requisition creation from alert, PO submission, receipt posting, return posting and cost generation are idempotent/retry-safe.

## Immutability
Approved PO commercial terms require amendment/version/reapproval. Posted receipts/returns/cost entries use reversal/correction, not destructive edits.

## Acceptance
The full chain is traceable:
```text
Feed forecast → Requisition → Approval → PO → Receipt → Lot → Consumption → Cost → Animal/Group/Production
```
and every stage retains its own meaning and quantity.
