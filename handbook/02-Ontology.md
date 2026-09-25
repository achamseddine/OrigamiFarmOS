# Origami FarmOS — Enterprise Ontology

**Status:** Canonical architecture specification

## 1. Principles
Origami models a farm through canonical entities, effective state, transactions and events. One real-world entity has one enterprise identity. Identifiers are aliases, not entities. History is preserved. Species differences use configuration/capabilities rather than duplicate tables. Quantities are unit-aware; missing is not zero.

## 2. Domain map
```text
Farm / Enterprise
├─ Organization / People / Roles
├─ Sites / Locations / Fields / Buildings
├─ Livestock: Animal + AnimalGroup
├─ Feed / Formula / Batch / Feeding Program
├─ Health / Welfare / Reproduction
├─ Production: Milk / Eggs / Wool / Growth
├─ Crops / Harvests
├─ Inventory / Products / Lots
├─ Procurement / Suppliers
├─ Sales / Finance
├─ Assets / Maintenance
├─ Laboratory / Quality
└─ Traceability / Compliance / Workflow / Events / Analytics
```

## 3. Livestock
**LivestockSubject** is either an individual **Animal** or **AnimalGroup** (herd/flock/batch). Animal is generic: no separate Cow, Horse, Sheep or Chicken core entities.

Animal references Species, Breed, Sex, LifeStage, ManagementProfile, Location and zero/many AnimalIdentifiers (ear tag, RFID, microchip, passport, registration, farm number, leg band, name).

**Capability** expresses applicable behavior such as BREEDING, PREGNANCY, LIVE_BIRTH, INCUBATION, MILK_PRODUCTION, EGG_PRODUCTION, WOOL_PRODUCTION, WEIGHT_TRACKING or FARRIER. Capabilities resolve from species + sex + life stage + management profile and configured state.

AnimalGroup membership is effective-dated. Historical membership is retained.

## 4. State and events
An animal is not one mutable history record:
```text
Animal
├─ stable identity/master attributes
├─ effective-dated state
└─ authoritative domain events/transactions
```
Pregnancy, lactation, movement, health and feeding assignments are supported by their owning domain records. Current state must not erase history.

## 5. Reproduction
Canonical concepts: mating/insemination, pregnancy assessment, pregnancy, birth, offspring relationship, incubation and hatch. Species terminology maps canonical semantics: calving/calf, lambing/lamb, kidding/kid, foaling/foal. Poultry uses egg/incubation/hatch and is never forced through pregnancy semantics.

## 6. Production
Production records measurable output by eligible subject and time: milk, eggs, wool, growth and other configured outputs. Capability determines applicability.

## 7. Feed
```text
Feed Item → Formula + Version → Feed Batch → Feed Product/Lot
                                            ↓
Feeding Program → Feeding Assignment → Feeding Event → LivestockSubject
```
Purchased finished feed may enter directly as Feed Product/Lot.

Definitions:
- FeedItem: ingredient/raw input.
- FeedProduct: product usable for feeding.
- FeedFormula: intended recipe.
- FormulaVersion: immutable historical recipe.
- FeedBatch: actual mixing occurrence.
- FeedLot: traceable stock.
- FeedingProgram: intended ration.
- FeedingAssignment: effective-dated program-to-subject link.
- FeedingEvent: actual feed offered/delivered/consumed.
- FeedUsagePolicy: enforceable species/profile/use restrictions.
- FeedAllocation: reserved stock for an authorized purpose.

**Physical possession of feed does not imply permission to use it.**

## 8. Inventory and procurement
InventoryItem is the stock master; InventoryLot is a traceable physical lot; InventoryTransaction is an auditable receipt, issue, transfer, production, consumption, return, waste, quarantine/release or adjustment. Current stock is derived/reconciled from transactions.

On-hand is not necessarily available: quarantined, blocked and reserved quantities reduce usable availability.

Procurement semantics:
```text
Supplier → Requisition → Purchase Order → Receipt → Acceptance/Rejection → Inventory Lot → Cost
```
Ordered, received and accepted quantities are distinct facts.

## 9. Health, welfare and laboratory
Health concepts include observation, examination, diagnosis, treatment, medication administration, vaccination, procedure and withdrawal. Observation is not diagnosis.

Welfare assessments/interventions reference livestock/location and retain their own records.

Laboratory semantics:
```text
Test Order → Sample → Chain of Custody → Method/Test → Result → Validation → Report
```
A lab result is evidence/measurement, not automatically a veterinary diagnosis or product disposition.

## 10. Crops and assets
Crop semantics: Field/Plot → Crop/Cultivar → Crop Cycle → Input/Application → Observation → Harvest → Harvest Lot.

Asset is a durable physical resource. Asset → maintenance plan → work order → maintenance/calibration/inspection. Assets are distinct from consumable inventory.

## 11. Traceability
Product describes a type; lot/batch identifies a physical instance.
```text
Source Lots → Transformation/Production → Output Lots → Movement/Use → Destination/Exposed Subjects
```
External IDs are aliases, never internal primary keys.

## 12. People, documents and workflow
Person/User is distinct from Role. Authority can change over time. Documents have identity/version/access controls. Evidence references source records without changing them.

Workflow orchestrates domain work but does not own domain truth. Task completion is not automatically business completion.

## 13. Events and decisions
A domain event states that an authoritative outcome occurred. Events have stable IDs, type/version, entity reference, occurrence/recording times and correlation/causation where relevant; consumers are idempotent.

```text
Observation → Analysis/Recommendation → Authorized Decision → Action → Outcome
```
AI recommendation is not authoritative business truth.

## 14. Semantic invariants
1. Species does not create separate Animal entities.
2. Individual and group livestock are first-class.
3. Formula is not batch; feeding program is not formula.
4. Planned/recommended feeding is not actual feeding.
5. Purchased quantity is not received quantity.
6. On-hand is not necessarily available.
7. Reserved/quarantined/blocked stock is not freely available.
8. Feed usage policy can prohibit cross-species use.
9. Identifier is not entity identity.
10. Observation is not diagnosis.
11. Lab result is not automatically diagnosis/disposition.
12. Task completion is not domain completion.
13. Missing is not zero.
14. Historical records are not overwritten to represent current state.
15. AI output is not an authorized decision.

## 15. Acceptance criteria
A new species can be added mainly through configuration; generic Animal supports cattle, horses, sheep, goats and individual poultry; flock operations need no fake individual animals; cattle-only premix can be blocked from horse/sheep use; inventory, procurement and feeding share lot/quantity semantics; canonical masters are reused across modules; history/provenance remain queryable; and workflow/AI can orchestrate or recommend without becoming the authoritative domain record.
