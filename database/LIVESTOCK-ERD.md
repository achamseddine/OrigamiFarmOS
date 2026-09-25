# Database Pass 2 — Livestock ERD

```mermaid
erDiagram
  FARM ||--o{ ANIMAL : owns
  SPECIES ||--o{ ANIMAL : classifies
  BREED o|--o{ ANIMAL : identifies_breed
  LIFE_STAGE o|--o{ ANIMAL : current_stage
  MANAGEMENT_PROFILE o|--o{ ANIMAL : current_profile
  LOCATION o|--o{ ANIMAL : current_location

  ANIMAL ||--o{ ANIMAL_IDENTIFIER : has
  IDENTIFIER_TYPE_POLICY ||--o{ ANIMAL_IDENTIFIER : governs
  ANIMAL ||--o{ ANIMAL_STATE_HISTORY : history
  ANIMAL ||--o{ ANIMAL_EXTERNAL_ALIAS : aliases

  FARM ||--o{ ANIMAL_GROUP : owns
  SPECIES ||--o{ ANIMAL_GROUP : classifies
  LIFE_STAGE o|--o{ ANIMAL_GROUP : current_stage
  MANAGEMENT_PROFILE o|--o{ ANIMAL_GROUP : current_profile
  LOCATION o|--o{ ANIMAL_GROUP : current_location
  ANIMAL_GROUP_TYPE_POLICY ||--o{ ANIMAL_GROUP : governs

  ANIMAL_GROUP ||--o{ ANIMAL_GROUP_MEMBERSHIP : has
  ANIMAL ||--o{ ANIMAL_GROUP_MEMBERSHIP : participates
  ANIMAL_GROUP ||--o{ ANIMAL_GROUP_QUANTITY_EVENT : quantity_history

  ANIMAL ||--o{ ANIMAL_RELATIONSHIP : source
  ANIMAL ||--o{ ANIMAL_RELATIONSHIP : target

  SPECIES ||--o{ SPECIES_CAPABILITY_RULE : resolves
  CAPABILITY ||--o{ SPECIES_CAPABILITY_RULE : enables
  LIFE_STAGE o|--o{ SPECIES_CAPABILITY_RULE : qualifies
  MANAGEMENT_PROFILE o|--o{ SPECIES_CAPABILITY_RULE : qualifies
```

## Physical subject model
There is intentionally no `livestock_subject` table in Pass 2. Later feed/health/production association tables that support both individuals and groups will use explicit constrained FKs or typed association tables.
