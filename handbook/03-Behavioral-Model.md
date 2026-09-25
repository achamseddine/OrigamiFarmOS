# Origami FarmOS — Behavioral Model

**Status:** Canonical architecture specification

## 1. Core pattern
```text
Intent / Command
 → Authentication + Authorization
 → Load Authoritative State
 → Business Validation
 → Domain Transaction
 → Persist State/Ledger
 → Emit Domain Event
 → Workflow / Integration / Analytics
```
UI visibility never replaces backend validation. Commands differ from events; recommendations differ from actions. Retries are idempotent. Posted history uses correction/reversal rather than silent overwrite.

## 2. Animal behavior
Add Animal → select species → capture sex/life stage/profile/identity → resolve capabilities → validate → create UUID/identifiers → AnimalCreated.

Changing species after operational history is highly restricted. Sex, life-stage and profile changes trigger capability re-evaluation without deleting history.

Groups maintain effective-dated membership. Lifecycle transitions (birth, weaning, breeding, pregnancy, birth, dry-off, death, sale/transfer) are explicit events that validate current state, record authoritative history, update projections, re-evaluate capabilities/programs and emit downstream events/tasks.

## 3. Reproduction
Mammals:
```text
Breeding/AI → Pregnancy Check → Pregnancy → Monitoring → Birth → Offspring/Parentage
```
Poultry:
```text
Breeding → Egg → Incubation → Hatch → Chick/Group
```
Pregnancy actions are rejected when pregnancy capability does not apply.

## 4. Health
```text
Observation/Alert → Health Case → Examination → Diagnosis → Treatment → Follow-up
```
Medication validates product, dose/unit, subject and restrictions/withdrawal. Observation is not automatically diagnosis.

## 5. Feed formula and batch
```text
Draft Formula → Validate Compatibility → Review/Approval → Activate Version → Mixing → Retire
```
Used formula versions become historically immutable.

Batch:
```text
Formula Version
 → Target Batch Size
 → Scale Ingredients
 → Select/Reserve Eligible Lots
 → Validate Usage Policies
 → Record Actual Weights
 → Consume Inventory
 → Create Finished Feed Lot
 → Calculate Cost/Variance
 → FeedBatchCompleted
```
Expired, quarantined, blocked, incorrectly reserved or species-ineligible stock blocks completion unless an authorized exception applies.

## 6. Purchased feed
Requisition → Purchase Order → Receipt → Acceptance → Feed Lot → Allocation → Authorized Use. Ordered, received, accepted and available quantities remain distinct. Purchased finished feed does not require an on-farm formula.

## 7. Feeding program
```text
Species + Sex + Life Stage + Management Profile
+ Reproductive/Lactation State + Production + Weight/Age
 → Evaluate Rules
 → Eligible Programs
 → Specificity/Priority
 → Recommendation + Explanation
 → Authorized Assignment
```
Recommendation is not assignment.

Assignments are effective-dated. Subjects may inherit a group program and receive individual supplements, overrides or restrictions. Calving, pregnancy, weaning, production-band changes and group movement can trigger FeedingProgramReviewRequired.

## 8. Feeding event
```text
Animal/Group
 → Resolve Assignment
 → Select Feed Lot/Batch
 → Validate Availability + Allocation + Usage Policy + Lot Status
 → Record Offered Quantity
 → Optional Consumption/Refusal/Waste
 → Post Inventory Consumption
 → Calculate Cost
 → FeedingEventRecorded
```
Planned ration is never represented as actual feeding.

## 9. Cross-species feed control
For cattle-only premix:
```text
Select Premix → Load FeedUsagePolicy → Target Horse/Sheep
 → BLOCK → Reject → Audit / FeedUsageBlocked
```
Enforcement occurs during formula authoring, mixing, inventory issue and direct feeding. UI bypass cannot bypass API/domain validation.

## 10. Inventory, allocation and reconciliation
```text
Opening + Receipts + Production + Transfers In + Returns
- Issues - Consumption - Transfers Out - Waste
± Authorized Adjustments = Book Stock
```
```text
On Hand - Quarantined - Blocked - Reserved = Available for Use
```

Allocation validates eligible stock, reserves quantity and reduces free availability. Transfer to another purpose validates policy and authority.

Reconciliation:
```text
Expected Closing → Physical Count → Variance
 → Within Tolerance: Reconcile
 → Outside Tolerance: Review/Investigate
```
Unexplained variance is never silently classified as consumption or waste.

## 11. Replenishment
```text
Inventory + Reservations + Incoming Supply
        +
Active Feeding Programs / Forecast Demand
 → Available Stock + Days of Cover
 → Reorder / Stockout Risk
 → FeedReorderRequired
 → Notify Farm Manager
 → Suggested Quantity
 → Requisition / Approval
```
Forecasts respect species/use eligibility. Ineligible stock cannot satisfy demand. Adequately covered shortages suppress duplicate alerts.

## 12. Procurement
Need/Reorder Signal → Requisition → Approval → Purchase Order → Supplier → Receipt → Acceptance/Rejection → Inventory → Cost reconciliation. Automated recommendations never bypass approval authority.

## 13. Production, movement and mortality
Milk/egg/wool records require corresponding capability. Production may trigger analytics/feed review but not silently change feeding.

Animal movement validates source/destination, records effective history, updates current projection, emits an event and evaluates group/program consequences.

Death/disposal is explicit, closes incompatible active assignments, blocks future ordinary production/feeding and retains all history.

## 14. Laboratory and maintenance
Lab: Test Order → Sample → Chain of Custody → Test → Result → Validation → Report → Domain Consumer. Final lab result does not itself diagnose an animal or release a product.

Maintenance: Trigger → Work Order → Assignment → Work → Verification → Completion → Next Due. Invalid calibration can block instrument use where configured.

## 15. Workflow and approval
Workflow orchestrates durable processes and supports tasks, delegation, SLA and escalation. Approval evaluates authority at decision time and records actor, basis, timestamp, decision and evidence. Workflow completion cannot falsely mark a failed domain transaction successful.

## 16. Events, notifications and offline
Events emit only after successful authoritative change; consumers are idempotent. Notifications are consequences, not systems of record; acknowledging an alert does not resolve the condition.

Offline operations retain stable operation ID, actor/device, occurrence time and payload. Sync authenticates, deduplicates, validates authoritative state and applies or creates a conflict. Offline mode grants no additional authority.

## 17. Corrections and concurrency
Drafts may be edited. Posted ledger transactions use reversal/correction; final results use amendments; completed feed batches retain actual composition. Backdating preserves recorded-at time. Retryable commands use idempotency keys. Optimistic concurrency protects conflicting updates.

## 18. Authorization
Every command validates principal, farm/site scope, permission/role, domain authority, entity status and segregation-of-duties rules. Frontend hiding is convenience only.

## 19. AI
AI may detect anomalies, summarize, recommend feed review, forecast stock and suggest reorder quantities. AI may not independently diagnose, approve procurement, finalize lab results, silently change feeding, post inventory adjustments or bypass usage restrictions.

## 20. Cross-domain behavior
```text
Calving Domain records Calving
 → CalvingRecorded
 → Animal projection updates
 → Feed evaluates program
 → Workflow creates review
 → Analytics updates
```
Domains react through controlled services/events rather than rewriting another domain's authoritative records.

## 21. Behavioral invariants
1. Validate before mutation.
2. Authorize at API/domain boundary.
3. Persist before publishing success.
4. Events represent authoritative outcomes.
5. Retry must not duplicate effects.
6. Posted history is corrected, not silently overwritten.
7. Derived state never outranks authoritative records.
8. Recommendation is not action.
9. Plan is not actual transaction.
10. Task completion is not domain completion.
11. On-hand is not necessarily available.
12. Feed use requires inventory + allocation + eligibility.
13. Species restrictions are enforced transactionally.
14. Missing is not zero.
15. External data is validated before becoming internal truth.
16. AI cannot bypass authority.

## 22. Acceptance criteria
Capabilities dynamically govern animal actions; invalid species/state workflows are rejected server-side; lifecycle events can trigger feeding reviews without deleting history; purchased and farm-mixed feed converge downstream; cattle-only premix cannot be used for horses/sheep; feed mixing consumes exact lots and creates traceable output; group feeding supports individual overrides; reservations affect availability; shortages generate explainable farm-manager alerts before stockout; reconciliation exposes unexplained variance; retries do not duplicate transactions; cross-domain reactions use controlled events/services; approvals/corrections/exceptions remain auditable; AI recommendations remain distinct from authorized decisions.
