# Operational Workflows — farm staff handbook

**Status:** Operator flow guide, reviewed against the QR-branch code on 2026-11-13. Where a safeguard is **target / not yet implemented**, this page says so. It is not a substitute for an approved veterinary protocol, physical stock count or milk withdrawal procedure.

Start with [Animal Digital Twin](../05-Animal-Digital-Twin/README.md), [Animal + Feed flow audit](../../docs/ANIMAL-FEED-FLOW-AUDIT.md), [QR worker workflow](../../docs/QR-ANIMAL-QUICK-ENTRY.md), [Generic Feed implementation map](../../docs/GENERIC-FEED-ARCHITECTURE.md) and [Offline & Sync](../../architecture/OFFLINE-SYNC.md).

## 1. Morning / evening animal round — worker

| Step | Worker action | System of record / important exception |
| --- | --- | --- |
| Identify | Sign in; scan **animal** QR with keyboard-wedge reader or type tag; confirm identity, species and location | Canonical `Animal` UUID. Camera scanning/printing **not shipped**. Stall QR is not animal identity. |
| Check | Confirm the animal is present and eligible; inspect withdrawal and sync status | Cached withdrawal may be stale offline. If uncertain, **withhold and physically segregate milk**, not sell/dispatch it. |
| Milk | Record actual measured litres, correct session and destination | `POST /production/milk`. AM/PM is a device-time suggestion; duplicate sessions across devices are **not yet guarded**. |
| Feed | Select actual products; enter kg **offered**. Enter refused kg only if individually measured | `POST /feeding-events`. Estimated consumed = offered minus measured refused, not proof of swallowed intake. No entry from planned targets. |
| Care | Record observed signs, dated measured weight, or medicine via approved pharmacy workflow | Separate health/weight/medication endpoints and permissions; observation is not diagnosis. |
| Confirm | Check which writes succeeded, which queued, which failed; then scan next animal | Milk and feed are separate writes. A locally queued write is **not yet server accepted**. |

**Midday shared feeding:** choose the actual **AnimalGroup** and record the total physical silage/straw delivered to that group. Do not invent equal per-cow intake. An individual supplement is its own event. **Never log the same delivered feed twice** as both a group issue and per-animal issues.

**If the app rejects a write:** keep the measurement on paper or in a controlled retry queue, check the exact reason, correct the relevant domain transaction, and re-sync. Do not tick a task as a replacement for a missing milk/feed/medicine record.

## 2. New animal, reproduction and exit — authorized staff

```text
Choose species/sex/stage/profile
 → resolve capabilities and required identifier types
 → register animal with current identifier + optional group
 → verify Digital Twin
 → breeding → pregnancy check → episode → birth / loss
 → newborn registration and dam/sire relationship
 → lactation start / dry-off as dated events
 → feeding review task → authorized feeding decision
 → exit (sold/transferred/dead/etc.), with history preserved
```

- Do not type a new pregnancy or lactation flag into a generic edit form; the episode/event is authoritative.
- Group membership is effective-dated; a herd name is not a substitute for the member history.
- After an exit, ordinary milk and feed entries are not allowed. Historical records and traceability remain.
- Only an authorized clinician records a diagnosis/treatment; a worker can record signs and request review.
- Read [Animal implementation map](../../docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md) and [Reproduction Schema](../../database/REPRODUCTION-SCHEMA.md).

## 3. Receive → mix → feed → reconcile — stock keeper and manager

| Stage | What to record | What it **does not** mean |
| --- | --- | --- |
| Delivery | Supplier, receipt lot, ordered/received/rejected/accepted kg, cost, status and expiry | Purchase order or formula target is not stock on hand. |
| Quality gate | Quarantine/block/recall when indicated; release by authorized person | An unknown-quality lot is not automatically approved by a completed receipt. Formal QA release rules need hardening. |
| Formula | Versioned target recipe, eligible species, nutrient evidence, unit basis | Formula quantity is not actual weighed ingredients. |
| Mixing | Start one server-numbered `MIX-N`; enter **actual** lot-specific ingredient weights, actual output and variance | Offline device cannot assign final mix number; no automatic nutrition approval. |
| Program | Resolve applicable program; review lifecycle change; authorize explicit assignment | A recommendation is not an assignment. **Server approval enforcement for assignments needs correction (AF-04).** |
| Feeding | Issue actual product/lot to animal or group, record offered quantity; optional measured refusal | Offered ≠ consumed. A refusal record must not issue stock again. |
| Control | Count stock, reconcile with reason and authority; trace source lot → mix → exposure | Never repair a shortage by inventing a lot or silently negative stock. |

**Current high-priority defects:** daily group+individual demand can double-count (AF-01), and the API accepts `allow_negative` under feed-create permission (AF-02). Until fixed and tested, do not use automated demand totals as a verified purchasing quantity or permit negative-stock overrides in routine operation.

**Recall:** locate supplier/ingredient lot → batches and output lots → affected feeding events → animals/groups and dates. Block remaining affected stock, notify responsible people, preserve all audit records, and seek veterinary/food-safety assessment where appropriate. A trace result is exposure evidence, not proof of disease or causal milk loss.

## 4. Feeding review and nutrition — manager / veterinary or nutrition reviewer

```text
New milk, pregnancy, dry-off, group, weight, health or stock context
 → resolve effective program and flag material change
 → create review task with reason and data gaps
 → manager / authorized reviewer checks eligibility, intake and stock
 → approve an assignment or new program version (never rewrite historical mix)
 → worker records actual feeding
 → performance analytics compares baseline and observed outcomes with confounders
```

The current Feed Performance tab offers **deterministic monitoring**, not a validated per-cow nutrient-requirements engine. The [Dynamic Nutrition design](../../database/DYNAMIC-NUTRITION-AND-RATION-OPTIMIZATION.md) specifies a future model/solver/approval path. Do not use it as a prescription or assume missing midday feed amounts, body weight or lab analyses are zero.

## 5. Roles and approval boundary

| Action | Expected responsible role | Current enforcement / gap |
| --- | --- | --- |
| Record milk, actual offered feed, observations | Worker with relevant create permission | Domain API permissions apply; offline writes still await server validation |
| Register/edit/exit animals | Authorized Animals staff; higher authority for consequential exit | See livestock API and exit rules |
| Record medication | Authorized pharmacy/health workflow, with required prescription/protocol | Never bypass drug/route/dose/withdrawal checks |
| Receive/mix lots | Feed/stock operator with create permission | Shortage override currently needs tighter approval and provenance |
| Activate/assign feeding program | Farm feed approver, with vet/nutrition input for risk | **Desired control:** explicit assignment endpoint currently uses feed-create, not approve |
| Quarantine/release, reconcile stock | Inventory/feed approver | Record reason, physical evidence and ledger correction |
| Review feed performance signal | Manager, with veterinarian/nutrition professional for clinical cases | Alert is not diagnosis or authority to change a ration |

## 6. Sync and exception states

- **Draft:** not submitted, editable; do not count as work done.
- **Queued locally:** stable operation ID and payload stored; show offline/pending state.
- **Accepted by server:** authoritative event/lot/mix/record returned; refresh projection.
- **Rejected/conflicted:** show error, preserve original measurement and source time; user resolves and resubmits as an auditable correction. No silent last-write-wins.
- **Reversed/amended:** posted history remains visible with linked correction and reason.

**Current limitations:** not all target UI states, cross-device duplicate checks or withdrawal dispatch holds are implemented. See [AF-03/07/08](../../docs/ANIMAL-FEED-FLOW-AUDIT.md). When offline, do not treat a green task checkmark or a queued write as server-confirmed animal care.

## 7. English / Arabic working terms

| English | Arabic | Meaning |
| --- | --- | --- |
| Animal / group | حيوان / قطيع | Individual ID versus shared pen/flock subject |
| Offered | الكمية المقدّمة | Physically offered/issued feed |
| Refused | الكمية المرفوضة | Measured leftovers, not automatically returned stock |
| Estimated consumed | الاستهلاك التقديري | Estimate with evidence, not directly measured ingestion |
| Mix number | رقم الخلطة | Immutable server-issued physical production identity |
| Withdrawal / withheld milk | فترة السحب / حليب محجوز | Milk must be physically separated from saleable milk |
| Pending sync | بانتظار المزامنة | Locally queued, not yet accepted by server |

All feeding quantities must show **kg as-fed** (unless explicitly another unit) and distinguish **kg dry matter** in nutrition calculations. Never convert between these without a measured or declared dry-matter fraction and provenance.

## 8. Review / verification checklist

Run the acceptance scenarios in [Animal + Feed flow audit](../../docs/ANIMAL-FEED-FLOW-AUDIT.md) before using these flows for unsupervised farm operations. The repository's test suites cover many existing behaviors but this documentation review did **not** execute them and did **not** close the identified code gaps.
