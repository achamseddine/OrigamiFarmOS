# Offline & Synchronization Architecture

Origami is offline-first for critical farm workflows.

## Local operation
Mobile stores required reference/master data and locally created pending operations. Each write has a client-generated stable operation UUID.

## Sync
```text
Local Command
 → Pending Queue
 → Connectivity
 → Authenticate
 → Send operationId + payload
 → Server deduplicates
 → Server authorizes/validates current state
 → Apply OR reject/conflict
 → Return authoritative result
 → Update local projection
```

## Writes recorded offline (ADR-008)
A queued write is replayed with `X-Offline-Recorded-At` (when it was recorded on the tablet) and its original `Idempotency-Key`. The server judges it against its own records, as a live write — never the tablet's cached view. Where a live write is refused so the person at the parlour acts (milk a recorded withdrawal covers), a write recorded offline is kept, held and reported to the people who decide instead (milk: held, never saleable, never released). Until the server has answered, the tablet shows its own entry as waiting (milk: *Waiting for check*, out of every stored or sellable figure); a refusal stays in view where the record was made, with Try again and Discard. The header can never make a write allowed or saleable that a live one would not be.

## Conflict policy
Never use blind last-write-wins for financial, inventory, clinical, reproduction or other consequential transactions. Prefer append operations, optimistic versions and explicit conflict resolution.

## Time
Retain both local occurrence time and server recorded time. Clock drift must not rewrite authoritative sequencing silently.

The farm's clock is the farm's time zone, not the device's: the server gives it with its daylight-saving changes for the next year (`GET /farms/me` → `clock`), so a tablet set to another zone, or offline for months, still suggests the farm's morning or afternoon milking and dates late entries at the farm's hour (ADR-008).

## Reference data
Species, capabilities, UOM, locations, feed masters and other needed reference data are versioned/synchronized for offline use.

## Deletion
Use tombstones/status/version information when clients must learn that a record was retired/deactivated.
