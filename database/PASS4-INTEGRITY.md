# Pass 4 Integrity & Cross-Domain Behavior

## Capability gates
Backend must enforce:
- PREGNANCY for pregnancy episodes;
- LIVE_BIRTH for mammalian birth;
- INCUBATION/HATCHING for poultry workflows;
- MILK_PRODUCTION for milk records;
- LACTATION for lactation episodes;
- EGG_PRODUCTION for egg records;
- WOOL_PRODUCTION for wool records.

A UI tab being hidden is not validation.

## Reproduction → Livestock
Recording a live birth may atomically create offspring Animal(s), birth_offspring links, parent relationships and outbox events. Group-managed offspring instead use explicit group quantity events. Never create fake individuals merely for counting.

## Reproduction → Feed
Pregnancy confirmation, late gestation, birth, lactation start/end, weaning and similar events may emit FeedingProgramReviewRequired. They do not silently replace an approved feeding assignment.

## Health → Inventory
Medication/vaccine administration validates eligible lot/status/expiry and posts inventory consumption in the same transaction. Failed administration does not consume stock.

## Health → Production
Active withdrawal periods are evaluated when recording/dispositioning affected production. Measured output remains truthful even when unusable for sale/consumption.

## Health → Laboratory
Future test orders/samples/results attach to health cases/subjects. A positive lab result is evidence; it does not automatically create a confirmed diagnosis unless configured authorized workflow does so.

## Production → Feed
Feeding recommendations may use recent milk/egg/growth/weight projections. Feed never overwrites production facts.

## Corrections
Posted reproduction outcomes, administrations and production records are not destructively edited. Use correction/reversal/amendment with actor/reason/audit.

## Offline
Observations, measurements and routine production may be captured offline with stable UUID/operation ID. Consequential actions such as medication administration must still validate stock/authority on synchronization; conflict handling must not silently double-dose or double-consume inventory.

## Acceptance scenarios
1. Dairy cow calving creates birth record, calf link/parentage and feeding-review event.
2. Mare can have pregnancy/foaling but no milk-production commodity workflow unless configured.
3. Layer flock can incubate/hatch without pregnancy records.
4. Worker records fever/diarrhea observation without creating diagnosis.
5. Medication administration consumes the exact inventory lot and creates withdrawal where applicable.
6. Cow under withdrawal records actual milk but output is restricted.
7. Sheep may record milk and wool when capabilities allow.
8. Horse weight measurement is valid without enabling commodity production.
