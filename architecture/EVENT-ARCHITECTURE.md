# Event Architecture

Domain events represent successful authoritative outcomes.

## Canonical envelope
```json
{
  "eventId": "uuid",
  "eventType": "FeedBatchCompleted",
  "eventVersion": 1,
  "aggregateType": "FeedBatch",
  "aggregateId": "uuid",
  "occurredAt": "ISO-8601 UTC",
  "recordedAt": "ISO-8601 UTC",
  "correlationId": "uuid",
  "causationId": "uuid-or-null",
  "actorId": "uuid-or-null",
  "farmId": "uuid",
  "payload": {}
}
```

## Rules
- Publish success events only after the authoritative transaction succeeds.
- Consumers are idempotent.
- Event schemas are versioned.
- Events do not grant consumers permission to violate their own invariants.
- Prefer an outbox pattern so database commit and event publication cannot drift.
- Integration/webhook delivery is separate from internal domain-event truth.
