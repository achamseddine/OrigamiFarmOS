# Animal Digital Twin — documentation index

The **Animal** is one canonical entity for every configured species. Its capability set determines available actions; a group is a separate livestock subject. The Digital Twin combines **authoritative records and derived views**, not a mutable all-purpose form.

**Start here:** [Current Animal implementation map](../../docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md) · [QR Animal Quick Entry](../../docs/QR-ANIMAL-QUICK-ENTRY.md) · [Animal + Feed workflow audit](../../docs/ANIMAL-FEED-FLOW-AUDIT.md) · [Operational Workflows](../06-Operational-Workflows/README.md).

## Animal record: from registration to exit

```text
Species / sex / life stage / profile
  → capability resolver
  → required identifiers + canonical UUID
  → optional effective-dated group membership
  → Digital Twin:
      identity / location / history
      reproduction / lactation / family
      health / weight / medicine / withdrawal
      milk / production
      feeding plan + actual events + mix exposure
  → lifecycle and production events trigger feeding review
  → authorized assignment; never automatic ration change
  → exit; close incompatible activity, preserve past records
```

| Twin area | Authoritative source | Do not infer |
| --- | --- | --- |
| Identity | `Animal` UUID + typed active/retired `AnimalIdentifier` history | A pen label is not animal identity; a changed tag is not a new animal |
| Herd/flock | Effective-dated `AnimalGroupMembership`, quantity ledger for counted groups | `group_name` is a legacy fallback, not the authoritative membership history |
| Reproduction | Breeding, pregnancy checks/episodes, births/offspring, lactation episodes, dry-off | A breeding event alone is not proof of pregnancy |
| Health | Observation, dated weight, health case, authorized medication and withdrawal | A symptom is not a diagnosis; a photo is not a weight |
| Milk | Dated per-animal measured milk record, session, destination | A suggested AM/PM label or task tick is not proof of milk; offline milk may await validation |
| Feeding | Approved program/version or group inheritance, individual exceptions, actual feeding events and source lots | Planned ration is not offered feed; group issue is not per-animal consumed amount |
| Intelligence | Rebuildable feed performance assessment with evidence, context and confidence | Correlation is not causation; there is no validated per-animal ration solver |

## Read the specifications in this order

1. [Generic Animal capability model — implementation](../../docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md) (canonical current behavior, validations, endpoints, migration and deviations).
2. [Generic Animal capability model — original design](GENERIC-ANIMAL-CAPABILITY-MODEL.md) (conceptual reference; check the implementation map before using its suggested schema).
3. [Generic Feed implementation](../../docs/GENERIC-FEED-ARCHITECTURE.md) and [original formula/program design](GENERIC-FEED-FORMULA-AND-FEEDING-PROGRAM-MODEL.md).
4. [Livestock](../../database/LIVESTOCK-SCHEMA.md), [Reproduction](../../database/REPRODUCTION-SCHEMA.md), [Health](../../database/HEALTH-VETERINARY-SCHEMA.md), [Feed](../../database/FEED-SCHEMA.md) and [Production](../../database/PRODUCTION-SCHEMA.md) conceptual schemas.
5. [Physical schema deviations](../../database/README.md), [offline synchronization](../../architecture/OFFLINE-SYNC.md) and [audit / acceptance gaps](../../docs/ANIMAL-FEED-FLOW-AUDIT.md).

## Immediate workflow correction priorities

- Group + individual ration totals and overrides must be counted **once** (AF-01).
- Ration assignment approvals must be enforced on the server, not merely hidden in Flutter (AF-04).
- Milk withdrawal release and cross-device duplicate handling need explicit offline safeguards (AF-03, AF-07).
- QR camera scanning, printable labels, secure photos and per-animal nutrition optimization are **not yet shipped** (AF-09, AF-10).

**Status:** this page is a navigation and flow guide. It does not imply the listed code gaps have been fixed.
