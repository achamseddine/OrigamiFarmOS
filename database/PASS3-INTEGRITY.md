# Pass 3 Integrity & Transaction Matrix

| Operation | Required atomic effects |
|---|---|
| Receive purchased feed | receipt record/source + inventory lot + RECEIPT ledger + outbox |
| Transfer stock | TRANSFER_OUT + TRANSFER_IN + outbox |
| Quarantine lot | quality state + audit/event; availability projection updates |
| Reserve feed | reservation + optional feed allocation + event |
| Complete mixing batch | actual components + ingredient CONSUMPTION + output lot + PRODUCTION_OUTPUT + genealogy + outbox |
| Record feeding | usage-policy validation + feeding event/components + applicable inventory CONSUMPTION + outbox |
| Reverse feeding | reversal business record + reversing inventory ledger + outbox |
| Physical count | count/lines + approved adjustment ledger + event |
| Forecast | reproducible forecast/lines; no stock mutation |
| Reorder alert | alert/workflow notification; no automatic purchase approval |

## Critical validation sequence for feed use
1. Resolve target animal/group and effective species/profile.
2. Resolve requested feed product and lot.
3. Confirm lot belongs to product/item and farm.
4. Confirm lot is not expired/recalled/quarantined/blocked.
5. Evaluate FeedUsagePolicy.
6. Check reservations/allocations.
7. Check eligible available quantity.
8. Convert UOM using compatible dimension.
9. Post feed + inventory facts atomically.
10. Emit outbox event.

## Cattle-premix test
Given CATTLE_DAIRY_PREMIX with default BLOCK and ALLOW rule for CATTLE/DAIRY:
- feeding to dairy cow => allowed if inventory/lot rules pass;
- use in approved cattle formula => allowed;
- feeding to horse => FEED_USAGE_BLOCKED, no inventory transaction;
- use in sheep formula/batch => FEED_USAGE_BLOCKED, no inventory transaction;
- 400 kg reserved for lactating cattle => unavailable to unrelated use;
- a failed/blocked attempt is auditable but does not reduce stock.

## Concurrency
Availability checks and ledger posting must be concurrency-safe. Implementation may use transaction-level locking/advisory locks/serialized stock keys depending on framework ADR. Never implement read-balance-then-write without protection.

## Cost
Ledger rows retain unit cost where known. Feed batch actual cost derives from actual consumed lots/quantities plus configured production overhead later. Feeding cost derives from actual inventory consumption. Cost projections do not modify source ledger.

## Immutability
Posted ledger rows, completed feed batches, historical formula versions, activated historical feeding-program versions and posted feeding events cannot be edited in place. Corrections use explicit reversal/amendment/version mechanisms.
