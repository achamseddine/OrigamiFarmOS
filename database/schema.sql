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
    role           TEXT NOT NULL CHECK (role IN ('owner','manager','worker','veterinarian','accountant','read_only','super_user')),
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

-- ============================================================================
-- Mouneh & Farm Product Processing module (tech spec v0.5 §3 "Core Data
-- Model"). License-gated per farm via module_licenses; nothing here
-- hard-codes a product type — mouneh_products rows are created dynamically
-- by a farm manager through the Product Builder (see database/seed_demo_data.sql
-- for Makdous used purely as demo data).
-- ============================================================================

CREATE TABLE module_licenses (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id        UUID NOT NULL REFERENCES farms(id),
    module_code    TEXT NOT NULL,
    status         TEXT NOT NULL DEFAULT 'inactive' CHECK (status IN ('active','inactive','expired')),
    plan           TEXT NOT NULL DEFAULT 'mouneh_addon',
    starts_at      TIMESTAMPTZ,
    expires_at     TIMESTAMPTZ,
    max_users      INTEGER,
    max_products   INTEGER,
    activated_by   UUID REFERENCES users(id),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (farm_id, module_code)
);

CREATE TABLE mouneh_products (
    id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id                   UUID NOT NULL REFERENCES farms(id),
    name                      TEXT NOT NULL,
    category                  TEXT NOT NULL DEFAULT 'general',
    photo_path                TEXT,
    output_unit               TEXT NOT NULL CHECK (output_unit IN ('jar','bottle','pack','kg','liter','tray','piece','custom')),
    custom_output_unit_label  TEXT,
    default_batch_size        NUMERIC(10,2) NOT NULL DEFAULT 1 CHECK (default_batch_size > 0),
    shelf_life_days           INTEGER,
    warehouse_rules           TEXT,
    low_stock_threshold       NUMERIC(10,2),
    target_price              NUMERIC(10,2),
    wholesale_price           NUMERIC(10,2),
    target_margin_pct         NUMERIC(5,2),
    status                    TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','archived')),
    license_required          TEXT NOT NULL DEFAULT 'mouneh',
    created_by                UUID REFERENCES users(id),
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (farm_id, category, name)
);
CREATE INDEX idx_mouneh_products_farm ON mouneh_products(farm_id);

CREATE TABLE raw_materials (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id                UUID NOT NULL REFERENCES farms(id),
    name                   TEXT NOT NULL,
    category               TEXT NOT NULL DEFAULT 'raw_material' CHECK (category IN ('raw_material','packaging')),
    source_type            TEXT NOT NULL DEFAULT 'purchased' CHECK (source_type IN ('farm_produced','purchased')),
    inventory_item_id      UUID REFERENCES inventory_items(id),
    unit                   TEXT NOT NULL,
    default_unit_cost      NUMERIC(10,4) NOT NULL DEFAULT 0 CHECK (default_unit_cost >= 0),
    stock_tracking_enabled BOOLEAN NOT NULL DEFAULT true,
    current_stock          NUMERIC(12,3) NOT NULL DEFAULT 0 CHECK (current_stock >= 0),
    loss_percent_default   NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (loss_percent_default BETWEEN 0 AND 100),
    active                 BOOLEAN NOT NULL DEFAULT true,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_raw_materials_farm ON raw_materials(farm_id);

CREATE TABLE mouneh_recipes (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id       UUID NOT NULL REFERENCES mouneh_products(id),
    version          INTEGER NOT NULL DEFAULT 1,
    effective_from   TIMESTAMPTZ NOT NULL DEFAULT now(),
    basis_quantity   NUMERIC(10,2) NOT NULL CHECK (basis_quantity > 0),
    basis_unit       TEXT NOT NULL,
    active           BOOLEAN NOT NULL DEFAULT true,
    notes            TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (product_id, version)
);
CREATE INDEX idx_mouneh_recipes_product ON mouneh_recipes(product_id);

CREATE TABLE mouneh_recipe_items (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    recipe_id     UUID NOT NULL REFERENCES mouneh_recipes(id) ON DELETE CASCADE,
    material_id   UUID NOT NULL REFERENCES raw_materials(id),
    material_type TEXT NOT NULL DEFAULT 'raw_material',
    quantity      NUMERIC(12,3) NOT NULL CHECK (quantity > 0),
    unit          TEXT NOT NULL,
    loss_percent  NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (loss_percent BETWEEN 0 AND 100),
    is_optional   BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX idx_mouneh_recipe_items_recipe ON mouneh_recipe_items(recipe_id);

CREATE TABLE production_batches (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id             UUID NOT NULL REFERENCES farms(id),
    product_id          UUID NOT NULL REFERENCES mouneh_products(id),
    recipe_version_id   UUID NOT NULL REFERENCES mouneh_recipes(id),
    batch_code          TEXT NOT NULL,
    planned_qty         NUMERIC(10,2) NOT NULL CHECK (planned_qty > 0),
    actual_output_qty   NUMERIC(10,2),
    waste_qty           NUMERIC(10,2) NOT NULL DEFAULT 0,
    damaged_qty         NUMERIC(10,2) NOT NULL DEFAULT 0,
    quality_status      TEXT NOT NULL DEFAULT 'good' CHECK (quality_status IN ('good','substandard','rejected')),
    expiry_date         TIMESTAMPTZ,
    warehouse_location  TEXT,
    status              TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','in_progress','completed','cancelled')),
    planned_unit_cost   NUMERIC(10,4),
    planned_total_cost  NUMERIC(12,2),
    actual_unit_cost    NUMERIC(10,4),
    actual_total_cost   NUMERIC(12,2),
    labor_hours         NUMERIC(8,2),
    started_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at        TIMESTAMPTZ,
    created_by          UUID REFERENCES users(id),
    notes               TEXT,
    UNIQUE (farm_id, batch_code)
);
CREATE INDEX idx_production_batches_farm ON production_batches(farm_id);
CREATE INDEX idx_production_batches_product ON production_batches(product_id, status);

CREATE TABLE cost_components (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id          UUID REFERENCES mouneh_products(id),
    batch_id            UUID REFERENCES production_batches(id),
    cost_type           TEXT NOT NULL CHECK (cost_type IN
                           ('labor','packaging_extra','utilities','transport','cooling_storage','market_fees','byproduct_credit','other')),
    label               TEXT,
    calculation_method  TEXT NOT NULL DEFAULT 'fixed' CHECK (calculation_method IN ('fixed','per_output_unit','quantity_x_rate','percentage')),
    amount              NUMERIC(10,4),
    quantity            NUMERIC(10,2),
    unit_cost           NUMERIC(10,4),
    allocation_basis    TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (product_id IS NOT NULL OR batch_id IS NOT NULL)
);
CREATE INDEX idx_cost_components_product ON cost_components(product_id);
CREATE INDEX idx_cost_components_batch ON cost_components(batch_id);

CREATE TABLE batch_input_consumptions (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id      UUID NOT NULL REFERENCES production_batches(id) ON DELETE CASCADE,
    material_id   UUID NOT NULL REFERENCES raw_materials(id),
    planned_qty   NUMERIC(12,3) NOT NULL,
    actual_qty    NUMERIC(12,3),
    unit_cost     NUMERIC(10,4) NOT NULL,
    total_cost    NUMERIC(12,2)
);
CREATE INDEX idx_batch_input_consumptions_batch ON batch_input_consumptions(batch_id);

CREATE TABLE finished_goods_stock (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id              UUID NOT NULL REFERENCES farms(id),
    product_id           UUID NOT NULL REFERENCES mouneh_products(id),
    batch_id             UUID NOT NULL REFERENCES production_batches(id),
    warehouse_location   TEXT,
    quantity_produced    NUMERIC(10,2) NOT NULL DEFAULT 0,
    quantity_available   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (quantity_available >= 0),
    quantity_reserved    NUMERIC(10,2) NOT NULL DEFAULT 0,
    quantity_sold        NUMERIC(10,2) NOT NULL DEFAULT 0,
    quantity_expired     NUMERIC(10,2) NOT NULL DEFAULT 0,
    quantity_damaged     NUMERIC(10,2) NOT NULL DEFAULT 0,
    unit_cost            NUMERIC(10,4) NOT NULL DEFAULT 0,
    expiry_date          TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_finished_goods_product ON finished_goods_stock(product_id);
CREATE INDEX idx_finished_goods_expiry ON finished_goods_stock(expiry_date);

CREATE TABLE mouneh_sale_lines (
    id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id                   UUID NOT NULL REFERENCES farms(id),
    sale_id                   UUID REFERENCES sales(id),
    product_id                UUID NOT NULL REFERENCES mouneh_products(id),
    batch_id                  UUID NOT NULL REFERENCES production_batches(id),
    finished_goods_stock_id   UUID NOT NULL REFERENCES finished_goods_stock(id),
    quantity                  NUMERIC(10,2) NOT NULL CHECK (quantity > 0),
    unit_price                NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    discount                  NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
    customer_id               UUID REFERENCES customers(id),
    channel                   TEXT NOT NULL DEFAULT 'retail' CHECK (channel IN ('retail','wholesale','market','other')),
    cost_per_unit             NUMERIC(10,4) NOT NULL,
    revenue                   NUMERIC(12,2) NOT NULL,
    margin                    NUMERIC(12,2) NOT NULL,
    sold_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    sold_by                   UUID REFERENCES users(id)
);
CREATE INDEX idx_mouneh_sale_lines_farm_time ON mouneh_sale_lines(farm_id, sold_at);
CREATE INDEX idx_mouneh_sale_lines_product ON mouneh_sale_lines(product_id);

CREATE TABLE mouneh_events (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    farm_id       UUID NOT NULL REFERENCES farms(id),
    entity_type   TEXT NOT NULL,
    entity_id     UUID NOT NULL,
    event_type    TEXT NOT NULL,
    payload_json  JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_by    UUID REFERENCES users(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_mouneh_events_entity ON mouneh_events(entity_type, entity_id);
CREATE INDEX idx_mouneh_events_farm_time ON mouneh_events(farm_id, created_at);
