# QR Animal Quick Entry — worker workflow and implementation map

**Status (2026-11-11): first functional Flutter slice committed on `feat/qr-animal-quick-entry`; camera QR decoding, printable QR generation and photo attachments are **not implemented**.** This is the canonical worker workflow direction, replacing generic checklist completion as the way to record animal work.

## Goal

At the animal, a signed-in worker identifies the **actual Animal** (not its pen) and records the facts of a session with minimal taps. The Digital Twin is the system of record; the scan is a navigation shortcut, not a new animal table or authorization mechanism. The worker's tasks remain useful for scheduling and reminders, but ticking a task **never** creates milk, feeding or medication transactions.

Typical rounds at Origami Farms (times are configurable, not assertions of completion):
- **~06:00**: scan animal → morning milk in litres; concentrate and straw **offered** in decimal kg, with measured refusals when known; optional health observation
- **~11:00–12:00**: scan animal or use the existing **group feeding** form → corn silage / long straw actually offered; do not manufacture individual consumption from a shared pen amount
- **~18:00**: scan animal → evening milk and offered concentrate/straw; record exceptions
- **As needed**: record dated weight (scale/tape), clinical observation, and lot-bound medicine administration via the pharmacy, with an authorized prescription/protocol where required

## Implemented in this first slice

| Capability | Implementation | Boundaries |
|---|---|---|
| Scan/identify | `AnimalQuickEntryScreen` accepts `origami://animal/<canonical-animal-id>` from a keyboard-wedge QR scanner, a typed tag or a chosen animal; `animal_scan.dart` resolves only an exact unique current animal | No built-in camera scanner, no QR artwork or label printing. No automatic pen-to-animal substitution. |
| Milk | Capability- and permission-gated morning/evening entry; 13:00 local-time session suggestion; decimal litres; existing `AnimalsProvider.recordMilk` | A suggested session is not proof of milking; duplicate *manual* events need a review workflow |
| Feed | Three labeled **input slots**: concentrate, corn silage, straw; each requires an explicit feed product, actual offered kg, optional measured refused kg; existing `FeedingProvider.recordFeeding` writes one canonical animal feeding event | Labels do not infer a product or stock lot. The existing server chooses eligible FIFO lots and enforces policy. No stock from formula targets is treated as actual |
| Missing feed values | Blank means not recorded; consumed quantity is only populated when an individual animal's refusals were measured | Group feed remains a separate AnimalGroup feeding event; no per-animal intake fabricated |
| Medication | Quick action opens existing `showAdministerDialog`; `_TreatDialog` removed from Digital Twin and Record sheet | Product, eligible pharmacy lot, allowed route, treatment/protocol and server-derived withdrawal remain authoritative. Prescription/authorization is enforced server-side |
| Weight | Authorized dated scale/tape measurement through `POST /animals/{id}/weights` | A photograph is **not** a weight measurement |
| Observation | Existing observation dialog; worker reports a sign, not a diagnosis | Photo capture and attachment synchronization not yet available |
| Withdrawal milk | New `withheld` destination; server rejects `stored`, `sold`, `processed` and `consumed` when an animal is under withdrawal | A separate physical diversion/labeling procedure is still required; offline cached status can be stale |
| Language/input | EN and Lebanese AR via `context.t`, RTL inherited from app, Arabic-Indic/Persian digits and decimal commas/Arabic decimal separator parsed | Full app-wide numeric migration is a separate task |
| Reliability | Existing per-request outbox/idempotency; successful milk is cleared before attempting feed, so a feed failure can be retried without resending milk | Two endpoints are **not** one atomic transaction; no cross-device duplicate-session detection yet |

### Operator flow

1. Open **Morning Briefing → Animal quick entry**, **Animals → Animal quick entry**, the **Record sheet**, or the animal **Digital Twin**.
2. With a USB/Bluetooth keyboard-wedge scanner, scan the QR into the focused field and press Enter (or type the tag / choose an animal). The screen confirms **name, human-readable ID, species and current location**. If the label is unknown or ambiguous, nothing is written.
3. Enter only the fields actually measured. Empty fields are skipped. A value of zero is different from blank. Feed amounts are **offered**, not automatically consumed.
4. Use **Report observation**, **Record measured weight**, or **Administer medicine** as separate controlled domain actions.
5. **Save & scan next** submits through the existing APIs. The app clears only successful portions. Check the sync indicator and any server rejection; scan the next animal.

### QR label contract

Payload: `origami://animal/<animal UUID>` (opaque canonical ID, no PII, credentials or health facts). Print the animal's **human-readable primary tag** beside the QR, plus a short fallback lookup string. A scanner that types text into the tablet can use this today; labels must currently be created with a trusted **offline** QR-label tool. A future app-integrated camera reader/print service requires a reviewed dependency, Android permission/intent handling, an ADR and device testing.

**A QR physically attached to a stall is a location label, not an animal label.** It must never silently bind to whichever animal occupied that stall yesterday. Either attach the QR to the animal's movable tag, or implement a separate effective-dated location→occupant resolution with explicit identity confirmation.

Treat all QR input as untrusted. A scan **never** bypasses sign-in, farm scope, module permissions or server validation. The worker must not be able to resolve another farm's animal from the local list.

## Data, traceability and safety

- **Animal identity:** canonical generic Animal UUID; AnimalIdentifier remains an alias with active/retired history; the UI does not invent Cow/Sheep tables.
- **Milk:** `POST /production/milk` with animal, measured litres, local-time suggested session and destination. `withheld` is a distinct non-saleable destination when withdrawal is active. The server enforces it even if the tablet's cached status is stale. Existing reports must not treat `withheld` as saleable output.
- **Feeding:** `POST /feeding-events` with `subject_type=animal`, `event_type=offered` and per-product components. `quantity_consumed` is sent only when the worker measured the animal's refusals. Inventory and lot lineage remain the feeding service's responsibility; physical `MIX` numbers and ingredient genealogy are never generated by this UI.
- **Medication:** use the pharmacy's `MedicationAdministration` with an eligible lot, authorized route, treatment or approved protocol, actual administered quantity and server-derived withdrawal. Do not generate drug, dose, route or withdrawal suggestions in this workflow. A medication that requires a prescription must be refused by the server without one.
- **Health:** observation ≠ diagnosis; measured weight ≠ image-based estimation. History is appended, corrected or reversed through owning domain APIs rather than edited in place.
- **Offline:** existing `ApiClient.write` outbox uses idempotency keys and cached writes; UI success may mean *accepted locally*, not yet accepted by the server. Sync failures must remain visible. The milk and feed endpoints are separate transactions; there is no promise of atomic cross-domain save.

## Critical integration gaps discovered in the 2026-11-13 review

See [Animal + Feed workflow audit](ANIMAL-FEED-FLOW-AUDIT.md) for code-backed evidence, priority and acceptance tests. In particular: **AF-03** stale offline withdrawal state must never be used to clear milk for sale; **AF-07** the server has no cross-device animal/date/session duplicate guard; **AF-08** the suggested AM/PM session uses device time rather than a configured farm timezone; **AF-01** group + individual daily feeding demand can be double-counted; **AF-02** feed create-rights can request an un-lotted negative-stock issue; and **AF-14** program creation/versioning can auto-activate with create rights. These are **open implementation gaps**. A QR scan never proves that an event has been accepted by the server.

## Follow-up work (not shipped)

1. **Native camera QR scanning** and offline QR label generation/printing with an ADR, device-camera permission review, robust scan throttling and physical tag tests.
2. **Photo attachments:** secure capture, local encryption, compression, private object storage, background upload, retry and event attachment links; record wound/abnormality/body-condition photo sequences, not photo-derived weight without a validated model.
3. **Duplicate-session safeguards:** query existing records, show already-recorded milk session, distinguish a legitimate second measurement from an accidental duplicate, reconcile offline conflicts with an auditable correction.
4. **Group QR and milking-round modes:** group feeding uses AnimalGroup and actual pen quantities; batch milk entry is still per-animal canonical records. No invented individual intake.
5. **Body-condition scoring:** species-specific scale, observer, method, date and audit history; optional comparative photos.
6. **Clinical hardening:** require explicit authorized dose context in the pharmacy UI; avoid unrestricted manual dose/units where a current prescription/protocol should supply them. Verify local veterinary withdrawal requirements and physical milk segregation.
7. **Offline freshness:** show last sync/withdrawal-data age and unresolved outbox status before saleable milk dispatch; implement report-level separation of withheld milk.

## Acceptance and on-farm tests

- Arabic keyboard: `١٢٫٥`, `۱۲٫۵`, `12,5`, `12.5`; reject garbage and refused > offered.
- Unknown QR, foreign URL, duplicate tag, retired identifier: no animal selected; no record created.
- View-only account: no write actions. An animal without MILK_PRODUCTION: no milk field.
- Milk under withdrawal: API rejects sold, stored, processed, consumed; allows only `withheld`. A physical milk-diversion instruction must be followed.
- Feeding: select actual product for each of concentrate/silage/straw; no auto-inferred product or individual consumption; negative/overdrawn quantities refused by server.
- Offline: record a milk and feed entry; confirm outbox; reconnect; verify one of each, correct animal and source lots. Simulate feed failure after successful milk; retry without duplicate milk.
- Check physical QR contrast, mud/glare, camera/keyboard-wedge ergonomics, 48 px targets, keyboard-open scrolling and battery use in the barn.
- Run `flutter analyze`, `flutter test`, backend `pytest` and PostgreSQL migration/artifact CI before merge. These checks have **not** been run in this connector-only session.

## Related architecture

- `CONSTITUTION.md`; `handbook/02-Ontology.md`; `handbook/03-Behavioral-Model.md`
- `docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md`; `docs/GENERIC-FEED-ARCHITECTURE.md`
- `database/CLINICAL-DECISION-SUPPORT-EMERGENCY-PROTOCOLS.md`
- `product/MVP_SCOPE.md`; `product/TRACEABILITY.md`

User-supplied UX reference: `Farm_Animal_Tracker_New.html` (bilingual animal view, simple question flow and optional photos). This implementation adopts its animal-first intent but not its localStorage-only storage or free-form treatment event.
