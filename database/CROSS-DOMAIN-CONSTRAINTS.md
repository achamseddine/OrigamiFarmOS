# Database Baseline v1 — Cross-Domain Constraints

- Reuse canonical identities; farm-owned rows resolve to one farm; external IDs never replace UUID identity.
- Animal is generic; AnimalGroup is first-class; capabilities gate behavior.
- Inventory ledger is the only physical stock truth; on-hand, reserved and available differ.
- Feed possession does not imply permission; formula, batch, program and feeding event remain distinct.
- Observation != diagnosis != treatment != administration; medication use and stock consumption are atomic.
- Requisition != PO != receipt; sales order != delivery != invoice != payment.
- Only accepted receipt posts stock in; only posted stock delivery posts stock out.
- Planned field operations do not consume stock; harvest enters inventory exactly once.
- Farm-produced feed converges on normal inventory/feed controls.
- Durable assets are not consumable inventory.
- Posted transactions are immutable; corrections use reversal/amendment/versioning.
- Audit log, domain outbox and operational ledgers have distinct purposes.
