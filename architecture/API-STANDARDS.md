# API Standards

## Style
REST/JSON under `/api/v1`. OpenAPI is the machine-readable contract.

## Resources
Use canonical nouns and UUIDs. External aliases are lookup attributes, not resource IDs.

## Writes
Retryable writes use an `Idempotency-Key` or equivalent stable operation ID. Mutation responses return the authoritative resource/result and relevant version.

## Duplicate entries and approvals
Two kinds of duplicate, two defences (`backend/app/core/duplicates.py`):

- **The same request twice** (a retry, an offline replay, a double tap) is answered from the stored response by the `Idempotency-Key` middleware. Every tablet write carries a key — direct, queued and the confirmed resend below share one key per logical write.
- **The same fact entered twice by people** (two workers recording one cow's morning milk, a delivery note typed in again, a mix saved twice) is a new request. Each record workflow looks for an existing record that says the same thing and answers **409** with a `detail` starting `Possible duplicate:` that names what is already there. A real second entry (a second milking, another delivery on the same invoice) is resent with `confirm_duplicate: true`; it is recorded and a `duplicate_confirmed` event names the record it resembles. The tablet asks *Already recorded?* for every form in one place (`core/widgets/duplicate_confirmation.dart`); a queued offline entry refused this way gets *Record anyway* in the sync panel.

| Workflow | Same fact when… |
|---|---|
| Milk | same animal and session, same farm day (farm time zone) |
| Eggs / harvest (both endpoints) | same flock or field + product and quantity within 30 min |
| Feeding event | same subject, kind and per-feed quantities within 30 min |
| Feed delivery (lot receipt) | same supplier + invoice/reference, or same supplier + quantity within 30 min |
| Feed mix | same output and ingredient quantities within 30 min |
| Breeding / pregnancy check | same female, kind/result, same farm day |
| Birth | a birth of the same dam within 30 days (twins are one birth with two newborns) |
| Treatment / medicine administration | same subject and medicine within 12 h |
| Observation | same subject, type and value within 30 min |
| Weight | same animal, same farm day |
| Health case | an open case for the same subject and problem |
| Animal | an active animal of the species with the same name |
| Mouneh sale | same product, quantity, price and customer within 5 min |

Where a repeat can never be right the refusal is a plain 409 with no override: a feed product, group, field or Mouneh raw material with the same name; a lot code already used.

**Approval levels** (permission actions view/create/edit/delete/approve/export/assign/configure) are enforced on the server; the tablet only hides what a person cannot do:

- Taking stock below the ledger (`allow_negative`) needs *approve* on Feed & nutrition or Inventory (Mouneh: Mouneh inventory/production or Inventory) — `deps.ensure_stock_override`.
- A formula or program created/versioned without Feed *approve* is saved as a **draft**; activating needs approve. A farm feed's first one-step mix creates and approves its recipe, so it needs Feed approve; later mixes of an approved recipe need only create.
- A delivery graded `poor` is received **quarantined**; releasing it is a Feed approval.
- A death is an Animals *edit*; a sale, cull, slaughter or transfer needs Animals *approve*. Correcting a lactation start needs *edit* (Animals or Milk production).
- The farm calendar (`PATCH /farms/me`) needs Settings *configure*.

## Errors
Use consistent machine-readable errors:
```json
{"code":"FEED_USAGE_BLOCKED","message":"Feed is not permitted for the target species.","details":{},"correlationId":"..."}
```

## Concurrency
Use entity/version or ETag-style optimistic concurrency where conflicting writes matter.

## Pagination/filtering
List endpoints use consistent cursor/page conventions chosen once during implementation; document filters/sorts in OpenAPI.

## Validation
APIs enforce permissions, domain state, UOM, compatibility and invariants. UI validation is supplementary.

## Versioning
Breaking contract changes require a new API version or compatible migration/deprecation plan.
