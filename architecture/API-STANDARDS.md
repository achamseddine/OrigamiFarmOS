# API Standards

## Style
REST/JSON under `/api/v1`. OpenAPI is the machine-readable contract.

## Resources
Use canonical nouns and UUIDs. External aliases are lookup attributes, not resource IDs.

## Writes
Retryable writes use an `Idempotency-Key` or equivalent stable operation ID. Mutation responses return the authoritative resource/result and relevant version.

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
