# QR Animal Quick Entry — worker workflow and implementation map

**Status (2026-11-13): second increment on `claude/gifted-davinci-mu9fjj` — built-in camera scanning, printable QR labels for animals and pens, pen/group labels, duplicate-session safeguards, program-prefilled feed rows and scan-driven rounds from My Day. Photo attachments, body-condition scoring and cross-device duplicate reconciliation are still not implemented.** First slice: `feat/qr-animal-quick-entry` (PR #11, merged into this branch). This is the canonical worker workflow direction, replacing generic checklist completion as the way to record animal work.

## Goal

At the animal, a signed-in worker identifies the **actual Animal** (not its pen) and records the facts of a session with minimal taps. The Digital Twin is the system of record; the scan is a navigation shortcut, not a new animal table or authorization mechanism. The worker's tasks remain useful for scheduling and reminders, but ticking a task **never** creates milk, feeding or medication transactions.

Typical rounds at Origami Farms (times are configurable, not assertions of completion):
- **~06:00**: scan animal → morning milk in litres; concentrate and straw **offered** in decimal kg, with measured refusals when known; optional health observation
- **~11:00–12:00**: scan animal or use the existing **group feeding** form → corn silage / long straw actually offered; do not manufacture individual consumption from a shared pen amount
- **~18:00**: scan animal → evening milk and offered concentrate/straw; record exceptions
- **As needed**: record dated weight (scale/tape), clinical observation, and lot-bound medicine administration via the pharmacy, with an authorized prescription/protocol where required

## Workflow analysis (2026-11-13)

The 06:00 round for one cow — morning milk plus concentrate and straw offered — measured on the tablet as it stood after PR #11:

| Step | After PR #11 | Now |
|---|---|---|
| Identify the animal | External keyboard-wedge scanner, or scroll a dropdown of every animal; no printed labels existed | **Tablet camera** (offline), keyboard wedge, typed tag or a searchable **Find**; labels printed from the tablet |
| Confirm it is the right animal | Name, tag, species, location | Same, plus photo/species tile, group, withdrawal / pregnant / in-milk tags and what is **already recorded today** |
| Milk | Session suggested from the clock; litres | Same; a second record in the same session today needs an explicit "second milking" tick |
| Feed | Three fixed rows; pick a product in **each row for every animal** (~6 taps), then type kg | Rows are the animal's **own program** (product named, planned amount per feeding shown); **Fill planned amounts** writes them in to check and correct; refusals only when weighed |
| Next animal | Save, focus returns to the text field | Save; with *Scan next automatically* the camera reopens; in a **round** the remaining animals are listed |
| A pen or a flock | Not scannable; group feeding through menus | **Pen label** opens the group: today's feeding rounds, record the round from its program, pick an animal from its members |

Per cow that is roughly: scan → (check) → litres → *Fill planned amounts* → save — four actions instead of about a dozen, with no product picking and no dropdown scrolling. The tablet now refuses three mistakes the old path allowed silently: a duplicate milking in the same session, a pen label recording against "whichever animal" stood there, and a code from another farm or an animal that has left.

## Implemented in the second increment

| Capability | Implementation | Boundaries |
|---|---|---|
| Camera scanning | `features/scan/qr_scanner_page.dart` — `mobile_scanner` (ADR-003), QR format only, ML Kit bundled model (offline on Android), torch, haptic on read; `QrScanSource` injectable | Camera permission requested when the scanner opens; refusal leaves the typed/wedge path. Device testing in barn light is a manual acceptance step |
| QR grammar | `animal_scan.dart`: `origami://animal/{id}`, `origami://group/{id}`, typed tags; `resolveScan` returns animal / group / a reason (not ours, unknown, ambiguous) | Only animals on the farm (`lifecycle_status = active`) and this farm's groups resolve |
| Labels | `features/scan/qr_labels.dart` — on-screen QR (`barcode` → SVG), label card (code, name, species/group, human tag), A4 PDF sheet via `pdf`/`printing` (print or share). From the Digital Twin's Record sheet, the quick-entry screen, a pen's view and the registry (*Print QR labels* for the animals shown) | Labels are rendered by Flutter and placed as images, so Arabic names print with the device's fonts. Weatherproof stock and placement on the animal's own tag are the farm's job |
| Already recorded today | `quick_round.dart` `milkToday` / `sameSessionToday` / `feedingsToday`; shown on the animal card; a same-session milking needs a tick | Reads the tablet's lists; another tablet's unsynced record is not visible (cross-device reconciliation remains open) |
| Program feed rows | `feedRowsFromPlan` from `GET /livestock-subjects/{id}/feeding-plan` (own or inherited program); planned amount per feeding as a hint; *Fill planned amounts* | The worker sees and can change every figure before saving; the plan is never recorded on its own. With no program, PR #11's three labelled rows |
| Rounds | `QuickRound` milking (session) / individual feeding; `roundStatus`; opened from My Day's routine rows | A round shows progress and who is left; it never selects the next animal for the worker |
| Pen / group label | Group view: today's feeding rounds vs the program, *Record this feeding* (prefilled group feeding form), member chips, the group's own label | Group feeding stays a group event; no per-animal intake is derived from it |

## Implemented in the first slice (PR #11)

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

## Follow-up work (not shipped)

1. ~~Native camera QR scanning and label printing~~ — done in the second increment (ADR-003); physical tag tests in barn conditions remain.
2. **Photo attachments:** secure capture, local encryption, compression, private object storage, background upload, retry and event attachment links; record wound/abnormality/body-condition photo sequences, not photo-derived weight without a validated model.
3. **Duplicate-session safeguards:** the same-tablet check is done (already recorded today, explicit second milking); cross-device reconciliation of offline duplicates with an auditable correction remains.
4. ~~Group QR and milking-round modes~~ — done: pen labels open the group; rounds from My Day. Batch milk entry stays per-animal canonical records.
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
