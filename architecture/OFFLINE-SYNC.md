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

## Conflict policy
Never use blind last-write-wins for financial, inventory, clinical, reproduction or other consequential transactions. Prefer append operations, optimistic versions and explicit conflict resolution.

## Time
Retain both local occurrence time and server recorded time. Clock drift must not rewrite authoritative sequencing silently.

## Reference data
Species, capabilities, UOM, locations, feed masters and other needed reference data are versioned/synchronized for offline use.

## Deletion
Use tombstones/status/version information when clients must learn that a record was retired/deactivated.
