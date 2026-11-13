# Animal + Feed modules — workflow audit and correction backlog

**Reviewed:** 2026-11-13  
**Code baseline:** [`e7933f09a91fcf56eaad86f688567cc6ebbba447`](https://github.com/achamseddine/OrigamiFarmOS/tree/e7933f09a91fcf56eaad86f688567cc6ebbba447), branch `feat/qr-animal-quick-entry`.  
**Method:** static review of the repository's domain specifications, API/services, Flutter screens, and named tests. **No new runtime, device, PostgreSQL or end-to-end tests were executed in this documentation review.** Findings below distinguish observed code from proposed fixes; they do not claim a defect has been reproduced on a farm device.

## Read this first: which document governs what?

| Concern | Authority / navigation |
| --- | --- |
| Cross-domain invariants and state transitions | [Behavioral Model](../handbook/03-Behavioral-Model.md), [Offline Sync](../architecture/OFFLINE-SYNC.md) |
| Species capabilities, identity, groups, reproduction | [Generic Animal implementation map](GENERIC-ANIMAL-CAPABILITY-MODEL.md), [Livestock Schema](../database/LIVESTOCK-SCHEMA.md), [Reproduction Schema](../database/REPRODUCTION-SCHEMA.md) |
| Feed products, formulas, lots, batches, programs and actual events | [Generic Feed implementation map](GENERIC-FEED-ARCHITECTURE.md), [Feed Schema](../database/FEED-SCHEMA.md) |
| Feed performance: **observational analytics**, not a ration prescription | [Feed Performance Intelligence](../database/FEED-PERFORMANCE-INTELLIGENCE.md) |
| Per-animal nutrient requirements and constrained ration proposals | [Dynamic Nutrition and Ration Optimization](../database/DYNAMIC-NUTRITION-AND-RATION-OPTIMIZATION.md) — **design only; not an implemented optimizer** |
| Worker at the animal | [QR Animal Quick Entry](QR-ANIMAL-QUICK-ENTRY.md) |
| Physical schema differences (codes, floats, UOM) | [Database README](../database/README.md), [ADR-002](../architecture/ADR-002-REFERENCE-KEYS-UOM-SCHEDULER-GENERATED-ARTIFACTS.md) |
| Task-oriented operating instructions | [Operational Workflows](../handbook/06-Operational-Workflows/README.md) |

The `handbook/05-...` long-form documents are original **design references**; the `docs/GENERIC-...` files explain the **current implementation and deviations**. Do not interpret the conceptual SQL in `database/*-SCHEMA.md` as an exact copy of deployed ORM tables.

## Correct target flow — animal

```text
Choose species → sex → life stage → management profile
 → resolve effective capabilities + required identifiers
 → register canonical Animal UUID and identifiers (or resolve an existing one)
 → join effective-dated group membership when appropriate
 → view Digital Twin (identity, lifecycle, family, care, production, feed)
 → record breeding / pregnancy check / birth / lactation / dry-off as EVENTS
 → re-evaluate feeding suitability; open review, NEVER silently change ration
 → record exit/transfer/death; close incompatible activities, retain history
```

- A stall/pen QR is a **location**, not the identity of an animal. The animal QR encodes `origami://animal/<animal UUID>`; confirm the current animal and tag before writing. An old/ambiguous/unknown code must not select the first animal.
- Pregnancy and lactation are projections of episodes; do not add editable pregnancy/lactation switches to the generic animal edit form. Weight is a dated measurement; observation is not a diagnosis.
- The authoritative group relation is an **effective-dated membership**, with a legacy `group_name` fallback only for animals without membership history. A group may be head-count-managed or member-derived; never silently convert group feed to individual consumption.
- The animal record remains accessible after exit for audit and retrospective trace; ordinary new milk/feeding records are blocked.

## Correct target flow — physical feed and daily work

```text
Supplier / delivery
 → record ordered, received, rejected, accepted quantities
 → create eligible ingredient/product lot; quarantine or block when required
 → create/activate immutable formula VERSION (target, not actual)
 → start one numbered MIX batch (server assigns immutable farm-wide number)
 → weigh ACTUAL ingredient quantities against actual source lots
 → atomically issue ingredient lots, record deviations and cost, receive output lot
 → confirm required quality/release controls (additional workflow hardening)
 → approve feeding program VERSION / animal or group assignment
 → worker records offered/delivered quantities by real product/lot/subject
 → optional measured refusals and estimated intake, clearly separate from issues
 → reconcile remaining stock, trace exposures, review production/health signals
```

**Keep five facts distinct:** (1) planned formula, (2) actual manufactured mix, (3) approved ration, (4) feed **offered/issued**, and (5) **estimated** consumed/refused/wasted. A formula's 1,210 kg target is not an inventory receipt, an available mix, or a recorded animal meal. A physical mix number is assigned by the server, never fabricated offline. No nutrient model or price should be used to auto-authorize a ration.

**Two delivery paths:** individually offered feed belongs to `subject_type=animal`; physically shared pen feed belongs to `subject_type=group`. Group exposure does not prove each member ate the average share. A worker must not record the **same physical distribution** again for each animal. Separate individual supplements are separate actual events.

## Correct target flow — QR morning / midday / evening

1. **Identify:** sign in, scan/enter tag, confirm animal, farm, active status, location and capability; check current withdrawal and pending sync state. Device-local time is only a session suggestion, not proof of milking.
2. **Milk:** enter measured litres and AM/PM; if withdrawal applies, divert and physically label the milk **withheld**. Until the server confirms a stale offline entry, do not treat it as cleared for sale/processing. Do not re-send a successful milk entry if feed subsequently fails.
3. **Feed:** choose actual product for concentrate/silage/straw, enter **offered kg**; leave unknown quantities blank. Optional measured refusals permit an **intake estimate** (`offered - refused`), not proof of swallowed feed. Group silage/long-straw deliveries belong on a group event if individual portions were not observed.
4. **Care:** dated weight, observation, medication and clinical follow-up are separate permission-checked transactions. Never infer a diagnosis or medicine dose from a photo or feed trend.
5. **Sync and handover:** show `queued`, `accepted`, `rejected` and `needs review` distinctly; check partial successes before moving to the next animal. Record actual occurrence time and farm timezone; preserve server receipt time separately.

These are **target operating instructions**, not a claim that all screens currently implement every safeguard. See [QR workflow](QR-ANIMAL-QUICK-ENTRY.md) for shipped behavior.

## Correction backlog (priority is operational risk, not a verified incident)

| ID / priority | Observed code or documentation | Required correction / acceptance |
| --- | --- | --- |
| **AF-01 / P0** | [`daily_plan`](../backend/app/services/feeding_program_service.py) adds each group's full head-count targets and also each animal with its own explicit program; `covered_animals` is accumulated but never used. For inherited individual overrides, only supplements are added, so the delta is missed. | Partition **non-overlapping** heads before aggregating: group base for members without individual program; subtract/replace the group component for individual explicit assignments and apply each override **delta**, restriction and supplement once. Use the same corrected projection for daily plan, stock demand, forecast and cost. Test one group + one direct assignment + one override + one supplement + one group-size change. |
| **AF-02 / P0** | `FeedingEventCreate.allow_negative` and `BatchComplete.allow_negative` can be submitted to [feed API](../backend/app/api/v1/feeding.py) endpoints guarded by **feed-create** rights; [inventory consume](../backend/app/services/feed_inventory_service.py) then permits an un-lotted issue when eligible stock is exhausted. This conflicts with a blanket “every feed movement has a lot” assertion. | Normal feed and batch operations must **fail closed** on shortage. If an emergency exception is truly needed, use separate **approve-only**, reasoned, auditable correction/reconciliation with explicit untraced-quantity warning; never pretend a missing lot is traceable. Add worker-vs-manager and concurrent-issue tests. |
| **AF-03 / P0** | [milk API](../backend/app/api/v1/production.py) blocks non-`withheld` destinations while withdrawal is active; [QR UI](../mobile/flutter_app/lib/features/animals/animal_quick_entry_screen.dart) chooses destination from potentially stale cached animal state. Offline writes can queue before server validation. | Add **physical milk segregation and dispatch release** workflow: mark offline/uncertain milk as pending clearance, surface last authoritative withdrawal sync, require confirmed server acceptance before saleable stock/dispatch, train worker to divert suspected milk. Test withdrawal introduced on another device while first tablet is offline. |
| **AF-04 / P1** | [assignment endpoint](../backend/app/api/v1/feeding.py) allows ordinary `FEED_NUTRITION.CREATE` for explicit program assignment, while the [feed documentation](GENERIC-FEED-ARCHITECTURE.md) says only an approver can assign. `DELETE`/end uses `EDIT`. | Choose and enforce a documented **approval matrix** (e.g. explicit program/version change and high-risk restriction require `APPROVE`; routine recorded feeding requires `CREATE`). Record approving actor/time/reason; test all roles. Until code changes, **do not claim server approval is enforced**. |
| **AF-14 / P0** | [\`ProgramCreate\` / \`ProgramVersionCreate\`](../backend/app/schemas/feeding.py) default \`activate=true\`; [program create/version endpoints](../backend/app/api/v1/feeding.py) require only \`CREATE\`, while the dedicated activate endpoint requires \`APPROVE\`. [\`activate_program_version\`](../backend/app/services/feeding_program_service.py) changes **every active explicit assignment** on the previous version to the new version in place. | Creation must default to **draft**, and all activation paths must enforce \`APPROVE\` server-side. Preview all affected subjects, enforce eligibility and require explicit authorized rollout/confirmation; preserve assignment history and per-subject audit. Test create-rights-only user cannot activate or silently change existing rations. |
| **AF-05 / P1** | [`_fed_totals`](../backend/app/services/feeding_program_service.py) sums `quantity_offered` for all recorded event types, including `refusal` and `consumed_estimate`, even though these do **not** move stock. | Split plan comparison into `issued/offered`, `refused`, `consumed_estimate`, `waste`, and `unknown`; only stock-moving events count as issued. Test an offer followed by refusal/estimate does not double-count. |
| **AF-06 / P1** | [`FeedingComponentIn`](../backend/app/schemas/feeding.py) has no server-side cross-field `quantity_consumed <= quantity_offered` check. Refusal/estimate events do not link back to the original offer as a required source reference. | Validate units and quantity relationships **server-side**; link refusal/estimate to the specific offered event and source lots, or explicitly label provenance unavailable. Returns to usable stock require a **separate** approved, physically verified return; do not restore refused feed automatically. |
| **AF-07 / P1** | [milk API](../backend/app/api/v1/production.py) inserts a milk record without an animal/date/session duplicate check; [QR docs](QR-ANIMAL-QUICK-ENTRY.md) already note cross-device duplicates. | Show existing records for the animal/day/session; server-side duplicate detection with override reason and audit trail for genuine second milking. Do not mistake an idempotency key on **one request** for cross-device duplicate detection. |
| **AF-08 / P1** | [`milkSessionForHour`](../mobile/flutter_app/lib/features/animals/animal_scan.dart) uses the device's local hour (<13 = morning); no farm-timezone contract is used in that function. | Configure farm timezone (for this farm, `Asia/Beirut`), show farm-local occurrence timestamp, permit a justified correction, handle DST/clock drift and late entry. Keep recorded-at and occurred-at distinct. |
| **AF-09 / P1** | [QR implementation](QR-ANIMAL-QUICK-ENTRY.md) supports typed tags/keyboard-wedge scans; **no built-in camera scanner, printable label generator or secure photo attachments**. | Add reviewed camera/label workflow and private media capture/sync with permissions, offline retry and provenance. Test worn labels, duplicate/retired tags, exited animals and cached-list freshness; do not call it camera scanning today. |
| **AF-10 / P1** | The [nutrition optimizer design](../database/DYNAMIC-NUTRITION-AND-RATION-OPTIMIZATION.md) existed on the older baseline branch but was absent from the reviewed QR branch; current performance analytics is **not** a validated per-animal requirements engine or solver. | Preserve the design, then implement validated species-specific requirement models, lab/as-fed/DM nutrient coverage, constrained solver, infeasibility, approval and group-outlier handling **as a separate project**. No automatic per-cow ration or veterinary advice now. |
| **AF-11 / P1** | Group and animal events can both be entered for the same delivery, and a group's head count does not establish each animal's intake. | Add a delivery/round reference or overlap check; make UI choose group **or** individual physical distribution plus separately recorded supplements. Maintain uncertainty in exposure analytics. |
| **AF-12 / P2** | [Feed implementation map](GENERIC-FEED-ARCHITECTURE.md) still says “no separate membership table”, “no procurement module”, “no UOM table”, and lists **nine** tabs. Current code has effective-dated memberships, requisitions, a platform UOM registry and **ten** feed tabs (including Performance). | Correct scope and terminology; distinguish **feed-specific `uom.py` conversions** from the **platform `units_of_measure` table**, and requisitions from unverified purchase-order/invoice automation. |
| **AF-13 / P2** | The original [Animal Digital Twin](../handbook/05-Animal-Digital-Twin/README.md) and [Operational Workflows](../handbook/06-Operational-Workflows/README.md) index pages were empty. | Replace them with navigation, role-aware task sequences, exception paths and source-of-truth links. Keep one canonical implementation map per domain rather than copying whole schemas into the handbook. |

**P0** = fix before trusting stock/demand, authorization exceptions or milk release in daily operations. **P1** = fix before broad multi-worker deployment. **P2** = documentation/UX alignment. No backlog item is marked “fixed in code” by this documentation change.

## Additional decisions to document before implementation

- **Actual intake vs issued stock:** an issued kilogram leaves inventory at offering, even when an animal refuses it. Refusals are not automatically returned to a clean lot; capture whether material was weighed, discarded, returned under approved procedure or unmeasured. Never report offered minus unknown refusals as measured consumption.
- **Mix quality:** define which farm-produced lots may be issued immediately versus require quality hold/release, sample evidence, expiry/use-by checks and approver; quarantine must propagate to the issue screen and recall trace. Existing batch completion is **not** evidence of laboratory quality approval.
- **Feed profile evidence:** track as-fed vs dry-matter basis, sample date, lab/declaration provenance, nutrient coverage and uncertainty. A target formula, default cost or generic nutrient profile cannot stand in for actual measured batch composition.
- **Group ration safety:** evaluate every member's physiological needs and exceptions, not only majority lactation state and mean milk. Where data is missing, show review/unknown; no silent automated reassignment.
- **Audit/corrections:** use reversals/amendments for posted events; a task tick is not a feed, milk or medicine transaction. Reconciliation adjustments require physical count, reason and authorization.
- **Offline boundaries:** queued ≠ accepted; show stale inventory, withdrawal, capability and program versions; authoritative stock and farm-wide mix numbers are server-owned. Define conflict-resolution responsibility and timeouts.

## Minimum acceptance scenarios (add as tests before declaring the flows production-ready)

1. **Group vs individual:** three animals in a group, one direct ration, one override, one supplement; the daily-plan total equals the sum of the three **effective individual** requirements exactly once; forecast agrees.
2. **Feed events:** offer 10 kg from MIX-000123, measure 2 kg refused, record 8 kg estimated consumed; inventory issues 10 kg **once**, no second issue from refusal, and trace identifies the output lot and animal/group.
3. **Shortage/permissions:** worker cannot use negative stock, bypass a quarantined lot, activate a program through a create-with-activate shortcut, approve a program or remove a veterinary restriction; manager exception requires reason, trace gap and audit.
4. **Mix identity:** two runs of the same formula create distinct immutable farm-wide numbers and ingredient/output lots; offline starts have a temporary client ID only; replay does not allocate another number.
5. **Animal lifecycle:** register → group membership → breeding/check → birth/lactation → feed review task → authorized program assignment → exit; no loss of history and no post-exit ordinary milk/feed.
6. **Withdrawal/offline:** a worker offline with stale animal status cannot release milk as saleable; server rejection stays visible, physical milk is withheld and the rejected record is resolved without duplicate stock.
7. **Milk duplicates:** two devices attempt the same animal/date/session; second is flagged for review; legitimate second milking can be retained with explanation and audit.
8. **Nutrition readiness:** unknown midday silage quantity or unanalysed feed remains **unknown**, not zero or invented; an infeasible ration reports why and never silently activates a program.
9. **Cross-species:** horse/sheep/poultry feed use respects their configured species and policies; dairy-only premix is rejected for ineligible species.
10. **Release gate:** rerun backend tests + PostgreSQL migration parity, Flutter analyzer/tests, offline outbox/device tests and bilingual RTL/decimal tests after code fixes.

## Proposed implementation order

**Gate 1 — ledger and authorization correctness:** AF-01, AF-02, AF-04, AF-14, AF-05, AF-06, AF-11; unit/lot tests and role matrix.  
**Gate 2 — animal and milk safety:** AF-03, AF-07, AF-08; multi-device/offline and withdrawal segregation tests.  
**Gate 3 — operator usability:** AF-09, mix quality/recall, reliable photos, QR/label deployment.  
**Gate 4 — nutrition decision support:** AF-10; professional model review, solver validation, explicit approvals and monitoring.  
**Docs-only corrections:** AF-12, AF-13 can ship independently, but they do **not** close the implementation gates.

This audit does not alter running APIs, inventory, medication or feeding plans.
