# Pass 5 — Purchasing Matching, Approval & Control Matrix

## Document chain
```text
Demand / Replenishment Recommendation
        ↓
Purchase Requisition
        ↓ approval
Purchase Order
        ↓
Goods Receipt
        ↓ accepted quantity
Inventory Lot + RECEIPT ledger
        ↓
Supplier Invoice (finance integration)
        ↓
Payment (finance integration)
```

## Quantity states
Never collapse:
- recommended;
- requested;
- approved;
- ordered;
- shipped (if known);
- received;
- accepted;
- rejected;
- returned;
- invoiced;
- paid.

## Three-way match
When supplier invoice schema is implemented/connected, match:
1. PO — what was ordered and agreed commercially;
2. Goods Receipt — what was actually accepted;
3. Invoice — what supplier billed.

Tolerance rules are configurable. Exceptions require workflow/approval; a mismatch must not silently alter stock.

## Approval controls
- requester and approver separation can be required by policy;
- amount/category/farm determines approval route;
- authority is evaluated at decision time;
- delegation is effective-dated;
- approved documents are versioned/amended rather than silently edited;
- supplier change after approval can trigger reapproval.

## Feed replenishment
A stockout alert may generate a proposed requisition containing item, eligible stock, projected demand, safety stock, lead time and recommended quantity. Farm manager remains responsible for approval under configured authority.

## Receipt control
Receiving validates PO/item/UOM, quantity tolerance, lot/expiry requirements and quality disposition. Feed/medicine requiring quarantine may be received physically but unavailable until released.

## Cost control
PO price is commercial expectation. Inventory receipt cost is snapshotted from the accepted commercial basis plus allowed landed-cost allocation. Later supplier invoice variance is retained separately and can adjust valuation through explicit costing transactions—not by editing original quantity ledger.

## Acceptance scenarios
1. 500 kg premix ordered, 480 kg delivered, 470 kg accepted, 10 kg rejected: inventory increases by 470 kg only.
2. Partial receipt leaves PO line open for remaining quantity.
3. Reorder recommendation cannot create an approved PO by itself.
4. Expired medicine delivered can be recorded/rejected/quarantined without becoming available.
5. Supplier price change after receipt does not rewrite historical feed cost.
6. Return to supplier creates RETURN_OUT ledger and preserves original receipt genealogy.
