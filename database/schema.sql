-- Origami FarmOS — PostgreSQL schema (tech spec §9 "Database Schema - MVP Tables")
--
-- This is the authoritative DDL for pilot/staging/production deployments.
-- The FastAPI backend's SQLAlchemy models (backend/app/domain/models.py)
-- are engine-agnostic and will also run against SQLite for local dev/demo
-- and tests; this file documents the "real" PostgreSQL shape (UUIDs,
-- TIMESTAMPTZ, JSONB, foreign keys, indexes) and is what
-- database/migrations/ (Alembic) evolves going forward.
--
-- Apply with:  psql "$DATABASE_URL" -f database/schema.sql

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gen_random_uuid()

CREATE TABLE farms (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name               TEXT NOT NULL,
    country            TEXT NOT NULL DEFAULT 'Lebanon',
    region             TEXT NOT NULL DEFAULT 'Bekaa Valley',
    timezone           TEXT NOT NULL DEFAULT 'Asia/Beirut',
    default_currency   TEXT NOT NULL DEFAULT 'USD',
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE users (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id        UUID NOT NULL REFERENCES farms(id),
    name           TEXT NOT NULL,
    phone          TEXT,
    email          TEXT UNIQUE,
    password_hash  TEXT NOT NULL,
    role           TEXT NOT NULL CHECK (role IN ('owner','manager','worker','veterinarian','accountant','read_only')),
    language       TEXT NOT NULL DEFAULT 'en',
    active         BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE locations (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id    UUID NOT NULL REFERENCES farms(id),
    parent_id  UUID REFERENCES locations(id),
    name       TEXT NOT NULL,
    type       TEXT,
    notes      TEXT
);

CREATE TABLE suppliers (
    id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id  UUID NOT NULL REFERENCES farms(id),
    name     TEXT NOT NULL,
    phone    TEXT
);

CREATE TABLE customers (
    id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id  UUID NOT NULL REFERENCES farms(id),
    name     TEXT NOT NULL,
    phone    TEXT
);

CREATE TABLE animals (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id            UUID NOT NULL REFERENCES farms(id),
    tag                TEXT NOT NULL,
    name               TEXT NOT NULL,
    species            TEXT NOT NULL,
    breed              TEXT,
    sex                TEXT,
    birth_date         TIMESTAMPTZ,
    status             TEXT NOT NULL DEFAULT 'healthy' CHECK (status IN ('healthy','under_observation','under_treatment')),
    location_id        UUID REFERENCES locations(id),
    location_label     TEXT,
    health_score       INTEGER NOT NULL DEFAULT 100 CHECK (health_score BETWEEN 0 AND 100),
    pregnant           BOOLEAN NOT NULL DEFAULT false,
    pregnancy_days     INTEGER,
    lactating          BOOLEAN NOT NULL DEFAULT false,
    lactation_cycle    INTEGER,
    withdrawal_until   TIMESTAMPTZ,
    withdrawal_reason  TEXT,
    weight_kg          NUMERIC(8,2),
    group_name         TEXT,
    photo_path         TEXT,
    active             BOOLEAN NOT NULL DEFAULT true,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (farm_id, tag)
);
CREATE INDEX idx_animals_farm ON animals(farm_id);

CREATE TABLE flocks (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id         UUID NOT NULL REFERENCES farms(id),
    name            TEXT NOT NULL,
    species         TEXT NOT NULL,
    count           INTEGER NOT NULL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'healthy',
    location_id     UUID REFERENCES locations(id),
    location_label  TEXT
);

CREATE TABLE fields (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id                UUID NOT NULL REFERENCES farms(id),
    name                   TEXT NOT NULL,
    crop_type              TEXT,
    area_value             NUMERIC(10,2),
    area_unit              TEXT,
    stage                  TEXT,
    expected_harvest_date  TIMESTAMPTZ,
    est_yield_kg           NUMERIC(10,2)
);

CREATE TABLE inventory_items (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id        UUID NOT NULL REFERENCES farms(id),
    name           TEXT NOT NULL,
    category       TEXT,
    unit           TEXT NOT NULL,
    current_qty    NUMERIC(12,2) NOT NULL DEFAULT 0,
    reorder_level  NUMERIC(12,2) NOT NULL DEFAULT 0,
    supplier_id    UUID REFERENCES suppliers(id),
    supplier_label TEXT,
    unit_cost      NUMERIC(10,4),
    last_purchase  TIMESTAMPTZ
);

CREATE TABLE inventory_transactions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id             UUID NOT NULL REFERENCES inventory_items(id),
    direction           TEXT NOT NULL CHECK (direction IN ('in','out')),
    quantity            NUMERIC(12,2) NOT NULL CHECK (quantity > 0),
    unit_cost           NUMERIC(10,4),
    reason              TEXT,
    linked_entity_type  TEXT,
    linked_entity_id    UUID,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_inventory_tx_item ON inventory_transactions(item_id);

CREATE TABLE observations (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id              UUID NOT NULL REFERENCES farms(id),
    entity_type          TEXT NOT NULL CHECK (entity_type IN ('animal','flock','field')),
    entity_id            UUID NOT NULL,
    observation_type     TEXT NOT NULL,
    value_numeric        NUMERIC(12,4),
    value_text           TEXT,
    unit                 TEXT,
    severity             TEXT CHECK (severity IS NULL OR severity IN ('mild','moderate','severe')),
    observed_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    observer_id          UUID NOT NULL REFERENCES users(id),
    quality              TEXT NOT NULL DEFAULT 'human_observed'
                            CHECK (quality IN ('instrument_measured','counted','human_observed','opinion')),
    confidence           NUMERIC(4,3) NOT NULL DEFAULT 0.65,
    verification_status  TEXT NOT NULL DEFAULT 'unverified',
    notes                TEXT
);
CREATE INDEX idx_observations_entity ON observations(entity_type, entity_id);

CREATE TABLE events (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id             UUID NOT NULL REFERENCES farms(id),
    entity_type         TEXT NOT NULL,
    entity_id           UUID NOT NULL,
    event_type          TEXT NOT NULL,
    payload_json        JSONB NOT NULL DEFAULT '{}'::jsonb,
    device_id           TEXT,
    created_by          UUID NOT NULL REFERENCES users(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    server_created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_events_entity ON events(entity_type, entity_id);
CREATE INDEX idx_events_farm_time ON events(farm_id, server_created_at);

CREATE TABLE tasks (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id       UUID NOT NULL REFERENCES farms(id),
    title         TEXT NOT NULL,
    description   TEXT,
    assigned_to   UUID REFERENCES users(id),
    due_at        TIMESTAMPTZ,
    priority      TEXT NOT NULL DEFAULT 'medium' CHECK (priority IN ('high','medium','low')),
    status        TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_progress','done')),
    source_type   TEXT,
    source_id     UUID
);

CREATE TABLE recommendations (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id            UUID NOT NULL REFERENCES farms(id),
    category           TEXT NOT NULL CHECK (category IN ('health','feed','egg','withdrawal','harvest','finance')),
    priority           TEXT NOT NULL CHECK (priority IN ('high','medium','low','info')),
    title              TEXT NOT NULL,
    entity_type        TEXT,
    entity_id          UUID,
    entity_label       TEXT,
    confidence         NUMERIC(4,3) NOT NULL,
    rationale          TEXT NOT NULL,
    suggested_action   TEXT NOT NULL,
    status             TEXT NOT NULL DEFAULT 'generated'
                          CHECK (status IN ('generated','reviewed','accepted','rejected','postponed','task_created')),
    rule_id            TEXT,
    generated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at         TIMESTAMPTZ,
    decided_by         UUID REFERENCES users(id),
    decided_at         TIMESTAMPTZ
);
CREATE INDEX idx_recommendations_farm_status ON recommendations(farm_id, status);

CREATE TABLE recommendation_evidence (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    recommendation_id  UUID NOT NULL REFERENCES recommendations(id) ON DELETE CASCADE,
    evidence_type      TEXT NOT NULL DEFAULT 'metric',
    label              TEXT NOT NULL,
    value              TEXT NOT NULL,
    weight             NUMERIC(4,3) NOT NULL DEFAULT 1.0,
    note               TEXT
);

CREATE TABLE milk_records (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    animal_id       UUID NOT NULL REFERENCES animals(id),
    session         TEXT NOT NULL CHECK (session IN ('morning','evening')),
    liters          NUMERIC(8,2) NOT NULL CHECK (liters >= 0),
    quality_status  TEXT NOT NULL DEFAULT 'normal',
    destination     TEXT NOT NULL CHECK (destination IN ('stored','sold','processed','consumed')),
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    recorded_by     UUID REFERENCES users(id)
);
CREATE INDEX idx_milk_animal_time ON milk_records(animal_id, recorded_at);

CREATE TABLE egg_records (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    flock_id       UUID NOT NULL REFERENCES flocks(id),
    total_eggs     INTEGER NOT NULL CHECK (total_eggs >= 0),
    sellable_eggs  INTEGER NOT NULL DEFAULT 0 CHECK (sellable_eggs >= 0),
    broken_eggs    INTEGER NOT NULL DEFAULT 0 CHECK (broken_eggs >= 0),
    consumed       INTEGER NOT NULL DEFAULT 0 CHECK (consumed >= 0),
    hatched        INTEGER NOT NULL DEFAULT 0 CHECK (hatched >= 0),
    wasted         INTEGER NOT NULL DEFAULT 0 CHECK (wasted >= 0),
    recorded_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (sellable_eggs + broken_eggs + consumed + hatched + wasted <= total_eggs)
);
CREATE INDEX idx_eggs_flock_time ON egg_records(flock_id, recorded_at);

CREATE TABLE harvest_records (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    field_id      UUID NOT NULL REFERENCES fields(id),
    product_name  TEXT NOT NULL,
    quantity      NUMERIC(10,2) NOT NULL CHECK (quantity > 0),
    unit          TEXT NOT NULL DEFAULT 'kg',
    waste_qty     NUMERIC(10,2) NOT NULL DEFAULT 0,
    destination   TEXT,
    recorded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE treatments (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type           TEXT NOT NULL,
    entity_id             UUID NOT NULL,
    diagnosis             TEXT,
    medication            TEXT NOT NULL,
    dose                  TEXT NOT NULL,
    route                 TEXT NOT NULL,
    start_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    end_at                TIMESTAMPTZ,
    withdrawal_until      TIMESTAMPTZ,
    vet_id                UUID REFERENCES users(id),
    responsible_user_id   UUID NOT NULL REFERENCES users(id),
    status                TEXT NOT NULL DEFAULT 'active',
    cost                  NUMERIC(10,2),
    notes                 TEXT
);
CREATE INDEX idx_treatments_entity ON treatments(entity_type, entity_id);

CREATE TABLE sales (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id         UUID NOT NULL REFERENCES farms(id),
    customer_id     UUID REFERENCES customers(id),
    product_type    TEXT NOT NULL,
    product_label   TEXT,
    quantity        NUMERIC(10,2),
    unit            TEXT,
    amount          NUMERIC(10,2) NOT NULL,
    currency        TEXT NOT NULL DEFAULT 'USD',
    payment_status  TEXT NOT NULL CHECK (payment_status IN ('paid','pending','partial')),
    sold_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_sales_farm_time ON sales(farm_id, sold_at);

CREATE TABLE expenses (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id             UUID NOT NULL REFERENCES farms(id),
    supplier_id         UUID REFERENCES suppliers(id),
    category            TEXT NOT NULL,
    amount              NUMERIC(10,2) NOT NULL,
    currency            TEXT NOT NULL DEFAULT 'USD',
    linked_entity_type  TEXT,
    linked_entity_id    UUID,
    incurred_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_expenses_farm_time ON expenses(farm_id, incurred_at);

CREATE TABLE sync_queue (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    local_event_id    UUID,
    operation         TEXT NOT NULL CHECK (operation IN ('create','update')),
    entity_type       TEXT NOT NULL,
    entity_id         UUID NOT NULL,
    payload_json      JSONB NOT NULL DEFAULT '{}'::jsonb,
    status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','rejected','conflict')),
    retry_count       INTEGER NOT NULL DEFAULT 0,
    last_error        TEXT,
    idempotency_key   TEXT UNIQUE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id        UUID NOT NULL REFERENCES farms(id),
    user_id        UUID NOT NULL REFERENCES users(id),
    action         TEXT NOT NULL,
    entity_type    TEXT NOT NULL,
    entity_id      UUID NOT NULL,
    timestamp      TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata_json  JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX idx_audit_farm_time ON audit_log(farm_id, timestamp);
