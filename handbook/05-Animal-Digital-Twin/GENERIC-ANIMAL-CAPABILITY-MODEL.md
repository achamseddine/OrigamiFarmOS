# Generic Animal Model & Dynamic Species Capabilities

**Project:** Origami FarmOS  
**Purpose:** Developer handoff for Claude / GitHub implementation  
**Status:** Development specification

## 1. Core design decision

Origami FarmOS must not implement separate core entities such as `Cow`, `Sheep`, `Horse`, or `Chicken`.

All individual animals use one generic `Animal` entity. Species, sex, life stage, management/production profile, and configuration determine which identifiers, modules, workflows, terminology, validations, and UI tabs apply.

```text
Animal
  + Species
  + Sex
  + Life Stage
  + Management / Production Profile
        |
        v
  Capability Resolver
        |
        +-- Identification
        +-- Reproduction
        +-- Production
        +-- Health
        +-- Management
```

**Implementation rule:** do not scatter conditions such as `if species == "cow"` through the application. Business capabilities must be configuration-driven.

## 2. Generic animal creation

The Add Animal workflow starts with:

1. Species
2. Sex
3. Individual vs group/flock management where supported
4. Breed
5. Date of birth or estimated date
6. Management / production profile where relevant

After these selections, the capability resolver determines the remainder of the form.

Example:

```text
Species = Cattle
Sex = Female
Profile = Dairy
Life Stage = Adult

=> ear-tag identification
=> reproduction
=> pregnancy
=> live birth / calving
=> milk production
=> lactation
=> weight/body condition
=> health/treatment
```

For a mare:

```text
Species = Horse
Sex = Female
Profile = Breeding

=> name/microchip/passport identification
=> reproduction
=> pregnancy
=> live birth / foaling
=> health
=> weight/body condition
=> farrier/hoof care
=> NO dairy-production module
```

For a layer hen:

```text
Species = Chicken
Sex = Female
Profile = Layer

=> leg band or flock identification
=> egg production
=> breeding where applicable
=> incubation/hatching workflow where applicable
=> health
=> feed
=> NO pregnancy
=> NO live-birth workflow
```

## 3. Capability resolution

Capabilities must be resolved from more than species:

```text
Species + Sex + Life Stage + Management/Production Profile
                         |
                         v
                  Capability Set
```

Examples:

| Configuration | Resulting capabilities |
|---|---|
| Cattle + Female + Lactating/Dairy | Milk, lactation, reproduction, pregnancy, calving, health |
| Cattle + Male + Breeding | Breeding, health, growth; no pregnancy/milk |
| Sheep + Female + Dairy | Milk, reproduction, pregnancy, lambing, wool if configured |
| Sheep + Female + Meat | Reproduction, pregnancy, lambing, growth; milk-production UI may be disabled |
| Horse + Female + Breeding | Reproduction, pregnancy, foaling, farrier, health |
| Chicken + Female + Layer | Eggs, health, feed, breeding; no pregnancy |
| Chicken + Broiler flock | Growth, feed, health, mortality; no egg-production requirement |

Suggested capability codes include:

```text
EAR_TAG
RFID
MICROCHIP
LEG_BAND
PASSPORT
INDIVIDUAL_TRACKING
GROUP_TRACKING
BREEDING
PREGNANCY
LIVE_BIRTH
INCUBATION
HATCHING
MILK_PRODUCTION
LACTATION
EGG_PRODUCTION
WOOL_PRODUCTION
GROWTH_TRACKING
WEIGHT_TRACKING
BODY_CONDITION
HOOF_CARE
```

Capabilities should be extensible and data-driven.

## 4. Generic identification model

Do not place `ear_tag` as a mandatory column on `animal`.

Use a child entity:

```text
Animal
  |
  +-- AnimalIdentifier [0..*]
```

Suggested identifier types:

```text
EAR_TAG
RFID
MICROCHIP
LEG_BAND
PASSPORT
REGISTRATION_NUMBER
FARM_NUMBER
NAME
OTHER
```

Example cow:

```text
Animal UUID: internal canonical ID
Farm Number: 744
Ear Tag: LB-00451
RFID: 982000123456789
```

Example mare:

```text
Animal UUID: internal canonical ID
Name: Luna
Microchip: 985141000123456
Passport: HOR-LB-882
```

Both remain the same `Animal` entity.

## 5. Generic reproduction model

Reproduction is a capability. Pregnancy is not synonymous with reproduction.

### Mammalian reproduction

```text
Heat
 -> Mating / AI
 -> Pregnancy
 -> Pregnancy Check
 -> Birth
 -> Offspring
```

The underlying event can remain generic while the UI uses species terminology:

| Species | UI birth term |
|---|---|
| Cattle | Calving |
| Sheep | Lambing |
| Goat | Kidding |
| Horse | Foaling |

### Poultry reproduction

```text
Breeding
 -> Egg laid
 -> Fertile egg
 -> Incubation
 -> Hatch
 -> Chick
```

Therefore a hen may have `BREEDING`, `EGG_PRODUCTION`, `INCUBATION`, and `HATCHING`, but must never receive `PREGNANCY` or `LIVE_BIRTH`.

## 6. Generic production model

Production records must not be hard-coded into the Animal entity.

```text
Livestock Subject
      |
      +-- Production Record
             |
             +-- MILK
             +-- EGGS
             +-- WOOL
             +-- GROWTH
             +-- other future outputs
```

Examples:

- Dairy cow: milk/lactation.
- Dairy sheep/goat: milk plus applicable reproduction/wool.
- Layer hen/flock: egg production.
- Horse: normally no commodity-production module; reproduction/performance remains available.

## 7. Individual and group livestock

Introduce a generic `LivestockSubject` concept:

```text
LivestockSubject
   |
   +-- Animal       (individual)
   |
   +-- AnimalGroup  (herd / flock / batch)
```

Cattle and horses will normally be individual. Sheep may be individual or group-managed. Poultry will often be flock/batch managed, with optional individual records for selected breeding or valuable animals.

Feed, production, health/treatment, mortality, location, and other operational records should reference a livestock subject where the business process can validly operate at either level.

## 8. Dynamic UI

The animal profile navigation must be generated from capabilities.

Example dairy cow:

```text
744 — Holstein Cow
Overview | Milk | Reproduction | Health | Feed | Weight | Events | Documents
```

Example mare:

```text
Luna — Arabian Mare
Overview | Reproduction | Health | Feed | Weight | Farrier | Events | Documents
```

Example layer hen:

```text
Hen 0184
Overview | Eggs | Health | Feed | Breeding | Events
```

Example flock:

```text
Layer Flock 03 — 120 hens
Overview | Egg Production | Feed | Health | Mortality | Breeding | Inventory
```

The same capability rules must govern API validation and UI visibility. Hiding a tab is not sufficient security or business validation.

## 9. Suggested database model

Core entities:

```text
animal
- id UUID PK
- species_id FK
- sex
- breed_id FK nullable
- birth_date nullable
- birth_date_estimated boolean
- life_stage_id FK
- management_profile_id FK nullable
- status
- current_location_id nullable
- created_at
- updated_at

animal_identifier
- id UUID PK
- animal_id FK
- identifier_type
- identifier_value
- issuing_authority nullable
- valid_from nullable
- valid_to nullable
- is_primary boolean
- status

species
- id UUID PK
- code
- name_en
- name_ar
- active

capability
- id UUID PK
- code UNIQUE
- category
- active

species_capability_rule
- id UUID PK
- species_id FK
- capability_id FK
- sex nullable
- life_stage_id nullable
- management_profile_id nullable
- enabled boolean
- required boolean
- configuration JSONB nullable
- priority integer

animal_group
- id UUID PK
- species_id FK
- group_type
- name
- quantity
- sex_composition nullable
- life_stage_id nullable
- management_profile_id nullable
- location_id nullable
- status

livestock_subject
- id UUID PK
- subject_type ENUM(ANIMAL, ANIMAL_GROUP)
- animal_id nullable
- animal_group_id nullable
```

A polymorphic implementation may be replaced with explicit nullable FKs or separate association tables according to the project's persistence conventions. Referential integrity is more important than forcing a specific ORM pattern.

## 10. Capability resolver

Conceptual service:

```text
resolveCapabilities(
    species,
    sex,
    lifeStage,
    managementProfile
) -> CapabilitySet
```

The resolver must:

1. load matching rules;
2. apply specificity/priority;
3. return enabled capabilities;
4. return whether each is optional or required;
5. return capability configuration;
6. provide UI terminology/configuration;
7. be callable by backend validation and frontend rendering.

Do not persist every resolved capability on the animal unless required for historical reasons. Prefer deriving from configuration, while versioning configuration where historical interpretation matters.

## 11. API implications

Suggested endpoints:

```http
GET  /api/v1/species
GET  /api/v1/species/{speciesId}/configuration
POST /api/v1/animal-capabilities/resolve
POST /api/v1/animals
GET  /api/v1/animals/{id}
GET  /api/v1/animals/{id}/capabilities
POST /api/v1/animals/{id}/identifiers

POST /api/v1/animal-groups
GET  /api/v1/animal-groups/{id}
```

Example capability request:

```json
{
  "speciesCode": "CATTLE",
  "sex": "FEMALE",
  "lifeStage": "ADULT",
  "managementProfile": "DAIRY"
}
```

Example response:

```json
{
  "capabilities": [
    {"code": "EAR_TAG", "required": true},
    {"code": "RFID", "required": false},
    {"code": "BREEDING", "required": false},
    {"code": "PREGNANCY", "required": false},
    {"code": "LIVE_BIRTH", "required": false},
    {"code": "MILK_PRODUCTION", "required": false},
    {"code": "LACTATION", "required": false},
    {"code": "WEIGHT_TRACKING", "required": false}
  ]
}
```

## 12. Validation rules

- Every animal has one canonical internal UUID.
- Species is mandatory.
- Sex is mandatory where biologically/operationally known; an explicit UNKNOWN/UNDETERMINED value may be permitted by configuration.
- Identifier requirements come from capability/configuration, not a universal ear-tag rule.
- Identifier values subject to uniqueness must be unique within their configured scope/issuing authority.
- Pregnancy events require the `PREGNANCY` capability.
- Live-birth events require `LIVE_BIRTH`.
- Egg production requires `EGG_PRODUCTION`.
- Milk records require `MILK_PRODUCTION`.
- Lactation requires the relevant milk/lactation capability.
- Poultry must not receive mammalian pregnancy workflows.
- Male animals must not receive pregnancy capability.
- Group-only workflows must accept `AnimalGroup`; individual-only workflows must require `Animal`.
- Changing species after operational history exists must be highly restricted and audited.
- Changing sex, life stage, or management profile must trigger capability re-evaluation.
- Removing a capability must not delete historical records created while it was applicable.
- Capability configuration changes must be auditable/versioned where they alter historical interpretation.

## 13. Implementation guidance

Build in this order:

1. Generic `Animal`, `Species`, `Breed`, `AnimalIdentifier`.
2. Capability catalog and rule tables.
3. Capability resolver service.
4. Dynamic Add Animal form.
5. Dynamic animal-profile navigation.
6. Backend capability validation.
7. Generic mammalian reproduction events.
8. Species terminology mapping (calving/lambing/kidding/foaling).
9. Generic production records with milk/egg/wool/growth types.
10. `AnimalGroup` / flock support.
11. Poultry incubation/hatching.
12. Administrative UI for species/capability configuration.

## 14. Developer acceptance criteria

The architecture is accepted when a developer can add a new species without creating a new core animal table or duplicating the animal module.

Adding a species should primarily require configuration:

```text
Species
+ identifiers
+ lifecycle
+ capabilities
+ terminology
+ management profiles
+ validation configuration
```

For example, adding goats should not require a new `Goat` entity. Configuration should enable ear tags, breeding, pregnancy, kidding, milk where applicable, weight, health, and other relevant capabilities.

The same principle must support future species without architectural redesign.

## 15. Non-negotiable architecture rule

**Animal is the entity. Species describes the animal. Capabilities describe what the animal can participate in.**

Do not model:

```text
Cow module
Sheep module
Horse module
Chicken module
```

as separate livestock architectures.

Model:

```text
                    LIVESTOCK SUBJECT
                           |
              +------------+------------+
              |                         |
            ANIMAL                  ANIMAL GROUP
              |
            SPECIES
              |
      SPECIES CONFIGURATION
              |
    Species + Sex + Life Stage
       + Management Profile
              |
              v
       CAPABILITY PROFILE
              |
   +----------+----------+----------+
   |          |          |          |
Identity  Reproduction Production  Management
              |
          Health / Events
```

This is the foundation that allows Origami FarmOS to support cattle, sheep, goats, horses, chickens, ducks, turkeys, and future livestock consistently while keeping one coherent domain model.
