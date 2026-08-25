-- Origami FarmOS — demo seed data (PostgreSQL), matching the Option C
-- manager-demo narrative used across the tablet mock data
-- (mobile/flutter_app/lib/data/demo/demo_data.dart) and the backend's
-- Python seeder (backend/app/seed.py).
--
-- `backend/app/seed.py` is the actively tested seeding path (run via
-- `python -m app.seed`, exercised by backend/tests/). This file is the
-- portable SQL equivalent for environments that provision PostgreSQL
-- directly from schema.sql + this file, without running the Python app
-- first. IDs are fixed literals (not gen_random_uuid()) purely so the
-- foreign-key references below stay simple to read and verify.
--
-- Apply after schema.sql:
--   psql "$DATABASE_URL" -f database/schema.sql
--   psql "$DATABASE_URL" -f database/seed_demo_data.sql

BEGIN;

INSERT INTO farms (id, name, country, region, timezone, default_currency) VALUES
  ('00000000-0000-0000-0000-000000000001', 'Origami Farms', 'Lebanon', 'Bekaa Valley', 'Asia/Beirut', 'USD');

-- Password for every demo user is 'farmos123' (bcrypt hash below is a
-- fixed demo-only hash — never reuse in a real deployment).
INSERT INTO users (id, farm_id, name, email, password_hash, role, language) VALUES
  ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', 'Rami Farah', 'rami@origami.farm', '$2b$12$C9x1qk3f0m2v6VwYQwXrZuKt2yq6Zt0m1yQe1oQvVYVYV9m1kq1Sa', 'manager', 'en'),
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', 'Joseph Origami', 'owner@origami.farm', '$2b$12$C9x1qk3f0m2v6VwYQwXrZuKt2yq6Zt0m1yQe1oQvVYVYV9m1kq1Sa', 'owner', 'en'),
  ('00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000001', 'Dr. Layla Haddad', 'layla.vet@origami.farm', '$2b$12$C9x1qk3f0m2v6VwYQwXrZuKt2yq6Zt0m1yQe1oQvVYVYV9m1kq1Sa', 'veterinarian', 'en'),
  ('00000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-000000000001', 'Karim Youssef', 'karim.worker@origami.farm', '$2b$12$C9x1qk3f0m2v6VwYQwXrZuKt2yq6Zt0m1yQe1oQvVYVYV9m1kq1Sa', 'worker', 'en'),
  ('00000000-0000-0000-0000-000000000014', '00000000-0000-0000-0000-000000000001', 'Nadine Saab', 'nadine.acct@origami.farm', '$2b$12$C9x1qk3f0m2v6VwYQwXrZuKt2yq6Zt0m1yQe1oQvVYVYV9m1kq1Sa', 'accountant', 'en');
-- NOTE: replace the placeholder hash above with the output of
-- `python -c "from app.core.security import hash_password; print(hash_password('farmos123'))"`
-- before using this file against a real database — see backend/README.md.

INSERT INTO suppliers (id, farm_id, name) VALUES
  ('00000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000001', 'Al Mashreq'),
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000001', 'Bekaa Hay Co.'),
  ('00000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000001', 'Farm Harvest'),
  ('00000000-0000-0000-0000-000000000023', '00000000-0000-0000-0000-000000000001', 'Green Feed Co.'),
  ('00000000-0000-0000-0000-000000000024', '00000000-0000-0000-0000-000000000001', 'NutriPlus'),
  ('00000000-0000-0000-0000-000000000025', '00000000-0000-0000-0000-000000000001', 'VetCare');

INSERT INTO customers (id, farm_id, name) VALUES
  ('00000000-0000-0000-0000-000000000030', '00000000-0000-0000-0000-000000000001', 'Beirut Fresh Market'),
  ('00000000-0000-0000-0000-000000000031', '00000000-0000-0000-0000-000000000001', 'Bekaa Co-op');

-- ---------------------------------------------------------------- Inventory
INSERT INTO inventory_items (id, farm_id, name, category, unit, current_qty, reorder_level, supplier_label, unit_cost, last_purchase) VALUES
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-000000000001', 'Dairy Mix', 'Dairy', 'kg', 3250, 2000, 'Al Mashreq', 0.42, now() - interval '20 days'),
  ('00000000-0000-0000-0000-0000000000f5', '00000000-0000-0000-0000-000000000001', 'Alfalfa Hay', 'Dairy', 'kg', 4800, 3000, 'Bekaa Hay Co.', 0.31, now() - interval '20 days'),
  ('00000000-0000-0000-0000-0000000000f6', '00000000-0000-0000-0000-000000000001', 'Corn Silage', 'Dairy', 'kg', 2200, 2500, 'Farm Harvest', 0.18, now() - interval '20 days'),
  ('00000000-0000-0000-0000-0000000000f7', '00000000-0000-0000-0000-000000000001', 'Layer Feed', 'Poultry', 'kg', 1150, 1500, 'Al Mashreq', 0.39, now() - interval '20 days'),
  ('00000000-0000-0000-0000-0000000000f8', '00000000-0000-0000-0000-000000000001', 'Goat Mix', 'Goats', 'kg', 900, 800, 'Green Feed Co.', 0.44, now() - interval '20 days'),
  ('00000000-0000-0000-0000-0000000000f9', '00000000-0000-0000-0000-000000000001', 'Minerals', 'Minerals', 'kg', 320, 300, 'NutriPlus', 1.10, now() - interval '20 days'),
  ('00000000-0000-0000-0000-0000000000fa', '00000000-0000-0000-0000-000000000001', 'Medicine', 'Medicine', 'items', 14, 10, 'VetCare', 12.5, now() - interval '20 days');

-- 7 days of usage on the two low-stock items so days-remaining is computable.
INSERT INTO inventory_transactions (item_id, direction, quantity, reason, created_at)
SELECT '00000000-0000-0000-0000-0000000000f6', 'out', 90, 'daily_feeding', now() - (d || ' days')::interval FROM generate_series(0, 6) AS d;
INSERT INTO inventory_transactions (item_id, direction, quantity, reason, created_at)
SELECT '00000000-0000-0000-0000-0000000000f7', 'out', 55, 'daily_feeding', now() - (d || ' days')::interval FROM generate_series(0, 6) AS d;


-- ------------------------------------------------------------------ Animals
INSERT INTO animals (id, farm_id, tag, name, species, breed, sex, birth_date, status, location_label, health_score, pregnant, pregnancy_days, lactating, lactation_cycle, group_name) VALUES
  ('00000000-0000-0000-0000-000000000744', '00000000-0000-0000-0000-000000000001', '744', 'Bella', 'cow', 'Holstein Friesian', 'F', now() - interval '4 years 40 days', 'under_treatment', 'North Pasture — Group A', 87, true, 120, true, 2, 'Dairy Herd'),
  ('00000000-0000-0000-0000-000000000214', '00000000-0000-0000-0000-000000000001', '214', 'Luna', 'cow', 'Holstein Friesian', 'F', now() - interval '5 years', 'healthy', 'North Pasture', 92, false, NULL, true, NULL, 'Dairy Herd'),
  ('00000000-0000-0000-0000-000000000189', '00000000-0000-0000-0000-000000000001', '189', 'Rasha', 'goat', 'Baladi', 'F', now() - interval '3 years', 'under_treatment', 'North Pasture', 58, false, NULL, false, NULL, 'Dairy Herd'),
  ('00000000-0000-0000-0000-00000000a032', '00000000-0000-0000-0000-000000000001', 'G-032', 'Mira', 'goat', 'Damascus', 'F', now() - interval '2 years', 'under_observation', 'Hillside Paddock', 76, false, NULL, false, NULL, 'Goat Group B'),
  ('00000000-0000-0000-0000-00000000b045', '00000000-0000-0000-0000-000000000001', 'S-045', 'Daisy', 'sheep', 'Awassi', 'F', now() - interval '2 years', 'healthy', 'Meadow Field', 88, false, NULL, false, NULL, 'Sheep Group A'),
  ('00000000-0000-0000-0000-00000000c007', '00000000-0000-0000-0000-000000000001', 'H-07', 'Thunder', 'horse', 'Arabian', 'M', now() - interval '6 years', 'healthy', 'Stables', 90, false, NULL, false, NULL, NULL),
  ('00000000-0000-0000-0000-00000000d247', '00000000-0000-0000-0000-000000000001', 'L-247', 'Hen 247', 'layer_hen', 'Lohmann Brown', 'F', now() - interval '300 days', 'healthy', 'Poultry House 1', 83, false, NULL, false, NULL, 'Layer Flock'),
  ('00000000-0000-0000-0000-00000000d183', '00000000-0000-0000-0000-000000000001', 'L-183', 'Hen 183', 'layer_hen', 'Lohmann Brown', 'F', now() - interval '340 days', 'under_treatment', 'Poultry House 1', 45, false, NULL, false, NULL, 'Layer Flock'),
  ('00000000-0000-0000-0000-00000000d012', '00000000-0000-0000-0000-000000000001', 'D-012', 'Duck 12', 'duck', 'Pekin', 'F', now() - interval '220 days', 'under_observation', 'Pond Area', 78, false, NULL, false, NULL, 'Duck Flock'),
  ('00000000-0000-0000-0000-00000000b118', '00000000-0000-0000-0000-000000000001', 'S-118', 'Willow', 'goat', 'Saanen', 'F', now() - interval '3 years', 'under_treatment', 'Hillside Paddock', 64, false, NULL, true, NULL, 'Goat Group B'),
  ('00000000-0000-0000-0000-000000000381', '00000000-0000-0000-0000-000000000001', '381', 'Clover', 'cow', 'Holstein', 'F', now() - interval '3 years', 'healthy', 'North Pasture', 91, false, NULL, true, NULL, 'Dairy Herd'),
  ('00000000-0000-0000-0000-00000000a091', '00000000-0000-0000-0000-000000000001', 'G-091', 'Gigi', 'goat', 'Saanen', 'F', now() - interval '2 years', 'healthy', 'Hillside Paddock', 89, false, NULL, true, NULL, 'Goat Group B');

-- Willow is under an active medication withdrawal (triggers RULE-WITHDRAWAL).
UPDATE animals SET withdrawal_until = now() + interval '2 days', withdrawal_reason = 'Medication'
  WHERE id = '00000000-0000-0000-0000-00000000b118';

-- Bella's declining milk trend (8 sessions, oldest first) — triggers RULE-HEALTH-RISK.
INSERT INTO milk_records (animal_id, session, liters, destination, recorded_at, recorded_by)
SELECT '00000000-0000-0000-0000-000000000744', 'morning', v.liters, 'stored', now() - (v.days_ago || ' days')::interval, '00000000-0000-0000-0000-000000000013'
FROM (VALUES (7,23.0),(6,22.5),(5,22.0),(4,21.5),(3,21.0),(2,20.5),(1,20.0),(0,18.6)) AS v(days_ago, liters);

-- Bella's declining supplemental feed trend.
INSERT INTO inventory_transactions (item_id, direction, quantity, reason, linked_entity_type, linked_entity_id, created_at)
SELECT '00000000-0000-0000-0000-0000000000f1', 'out', v.qty, 'daily_feeding', 'animal', '00000000-0000-0000-0000-000000000744', now() - (v.days_ago || ' days')::interval
FROM (VALUES (7,18.0),(6,17.5),(5,17.0),(4,17.2),(3,16.8),(2,16.5),(1,16.0),(0,14.2)) AS v(days_ago, qty);

INSERT INTO observations (farm_id, entity_type, entity_id, observation_type, quality, severity, observed_at, observer_id, notes) VALUES
  ('00000000-0000-0000-0000-000000000001', 'animal', '00000000-0000-0000-0000-000000000744', 'fever', 'human_observed', 'severe', now() - interval '6 hours', '00000000-0000-0000-0000-000000000013', 'Cow reluctant to be milked, udder appears swollen.');

INSERT INTO treatments (entity_type, entity_id, diagnosis, medication, dose, route, start_at, end_at, status, responsible_user_id) VALUES
  ('animal', '00000000-0000-0000-0000-000000000744', 'Mastitis', 'Intramammary antibiotic', '1 tube', 'Intramammary', now() - interval '30 days', now() - interval '27 days', 'resolved', '00000000-0000-0000-0000-000000000012'),
  ('animal', '00000000-0000-0000-0000-000000000744', 'Mastitis', 'Intramammary antibiotic', '1 tube', 'Intramammary', now() - interval '60 days', now() - interval '57 days', 'resolved', '00000000-0000-0000-0000-000000000012');

-- ------------------------------------------------------------------- Flocks
INSERT INTO flocks (id, farm_id, name, species, count, status, location_label) VALUES
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-000000000001', 'Layer Flock', 'layer_hen', 2450, 'healthy', 'Poultry House 1-3'),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-000000000001', 'Duck Flock', 'duck', 680, 'healthy', 'Pond Area'),
  ('00000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-000000000001', 'Turkey Flock', 'turkey', 120, 'healthy', 'Barn C');

-- Duck flock egg drop (-22% vs last week) — triggers RULE-EGG-DROP.
INSERT INTO egg_records (flock_id, total_eggs, sellable_eggs, broken_eggs, consumed, hatched, wasted, recorded_at) VALUES
  ('00000000-0000-0000-0000-0000000000f3', 1446, 1300, 60, 40, 30, 16, now() - interval '7 days'),
  ('00000000-0000-0000-0000-0000000000f3', 1128, 1000, 50, 40, 30, 8, now()),
  ('00000000-0000-0000-0000-0000000000f2', 4100, 3700, 180, 120, 60, 40, now() - interval '7 days'),
  ('00000000-0000-0000-0000-0000000000f2', 4212, 3800, 180, 120, 60, 52, now()),
  ('00000000-0000-0000-0000-0000000000f4', 487, 460, 15, 8, 2, 2, now() - interval '7 days'),
  ('00000000-0000-0000-0000-0000000000f4', 502, 470, 18, 8, 4, 2, now());

-- ------------------------------------------------------------------- Fields
INSERT INTO fields (id, farm_id, name, crop_type, stage, est_yield_kg, expected_harvest_date) VALUES
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-000000000001', 'Field 2 — Tomatoes', 'Tomatoes', 'ripening', 420, now() + interval '20 hours'),
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-000000000001', 'Field 3 — Zucchini', 'Zucchini', 'flowering', 310, now() + interval '3 days'),
  ('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-000000000001', 'Field 4 — Cucumbers', 'Cucumbers', 'growing', 280, now() + interval '5 days'),
  ('00000000-0000-0000-0000-0000000000e4', '00000000-0000-0000-0000-000000000001', 'Herb Garden — Basil', 'Basil', 'mature', 65, now() + interval '2 hours'),
  ('00000000-0000-0000-0000-0000000000e5', '00000000-0000-0000-0000-000000000001', 'Orchard — Oranges', 'Oranges', 'developing', 1200, now() + interval '28 days');

-- -------------------------------------------------------------------- Tasks
INSERT INTO tasks (farm_id, title, description, due_at, priority, status) VALUES
  ('00000000-0000-0000-0000-000000000001', 'Inspect Cow 744', 'Health check', now() + interval '1 hour', 'high', 'open'),
  ('00000000-0000-0000-0000-000000000001', 'Reorder dairy mix', 'Low stock alert', now() + interval '3 hours', 'medium', 'open'),
  ('00000000-0000-0000-0000-000000000001', 'Collect duck eggs', 'Main house', now() + interval '4 hours', 'medium', 'open'),
  ('00000000-0000-0000-0000-000000000001', 'Harvest tomatoes in Field 2', 'Estimated 80 kg', now() + interval '9 hours', 'medium', 'open');

-- ------------------------------------------------------------ Sales/expenses
INSERT INTO sales (farm_id, product_type, product_label, quantity, unit, amount, payment_status, sold_at) VALUES
  ('00000000-0000-0000-0000-000000000001', 'milk', 'Milk', 340, 'L', 4250, 'paid', now()),
  ('00000000-0000-0000-0000-000000000001', 'eggs', 'Eggs', 285, 'dozen', 2380, 'paid', now()),
  ('00000000-0000-0000-0000-000000000001', 'produce', 'Produce', 260, 'kg', 3120, 'pending', now()),
  ('00000000-0000-0000-0000-000000000001', 'animals', 'Animals', 1, 'head', 2150, 'paid', now()),
  ('00000000-0000-0000-0000-000000000001', 'farm_products', 'Farm Products', 40, 'units', 945, 'partial', now());

INSERT INTO expenses (farm_id, category, amount, incurred_at) VALUES
  ('00000000-0000-0000-0000-000000000001', 'feed', 1680, now()),
  ('00000000-0000-0000-0000-000000000001', 'medicine', 720, now()),
  ('00000000-0000-0000-0000-000000000001', 'labor', 1150, now()),
  ('00000000-0000-0000-0000-000000000001', 'fuel', 420, now()),
  ('00000000-0000-0000-0000-000000000001', 'other', 260, now());

-- ============================================================================
-- Mouneh & Farm Product Processing module demo data (tech spec v0.5).
-- Makdous is used purely as an EXAMPLE — every row below is inserted the
-- same way a farm manager's Product Builder / Recipe / Batch screens would
-- write it; nothing about "Makdous" is special-cased in the schema or the
-- application code (see backend/app/mouneh/seed.py, the Python equivalent
-- of this block).
-- ============================================================================

-- Super user: the only role allowed to activate/deactivate the module.
INSERT INTO users (id, farm_id, name, email, password_hash, role, language) VALUES
  ('00000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-000000000001', 'Sami Nassar (Platform Admin)', 'super@origamifarms.com', '$2b$12$C9x1qk3f0m2v6VwYQwXrZuKt2yq6Zt0m1yQe1oQvVYVYV9m1kq1Sa', 'super_user', 'en');

INSERT INTO module_licenses (id, farm_id, module_code, status, plan, starts_at, activated_by) VALUES
  ('00000000-0000-0000-0000-000000000100', '00000000-0000-0000-0000-000000000001', 'mouneh', 'active', 'mouneh_addon', now() - interval '60 days', '00000000-0000-0000-0000-000000000015');

-- Raw materials + packaging (reusable across any future Mouneh product).
INSERT INTO raw_materials (id, farm_id, name, category, source_type, unit, default_unit_cost, current_stock, loss_percent_default) VALUES
  ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000001', 'Baby Eggplant', 'raw_material', 'farm_produced', 'kg', 1.20, 320, 6),
  ('00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000001', 'Walnuts', 'raw_material', 'purchased', 'kg', 7.50, 25, 0),
  ('00000000-0000-0000-0000-000000000103', '00000000-0000-0000-0000-000000000001', 'Red Pepper Paste', 'raw_material', 'purchased', 'kg', 3.80, 18, 0),
  ('00000000-0000-0000-0000-000000000104', '00000000-0000-0000-0000-000000000001', 'Garlic', 'raw_material', 'farm_produced', 'kg', 2.10, 12, 3),
  ('00000000-0000-0000-0000-000000000105', '00000000-0000-0000-0000-000000000001', 'Olive Oil', 'raw_material', 'farm_produced', 'liter', 6.50, 60, 0),
  ('00000000-0000-0000-0000-000000000106', '00000000-0000-0000-0000-000000000001', 'Salt', 'raw_material', 'purchased', 'kg', 0.35, 40, 0),
  ('00000000-0000-0000-0000-000000000107', '00000000-0000-0000-0000-000000000001', 'Glass Jars (500ml)', 'packaging', 'purchased', 'piece', 0.35, 600, 1),
  ('00000000-0000-0000-0000-000000000108', '00000000-0000-0000-0000-000000000001', 'Jar Lids', 'packaging', 'purchased', 'piece', 0.08, 600, 1),
  ('00000000-0000-0000-0000-000000000109', '00000000-0000-0000-0000-000000000001', 'Labels', 'packaging', 'purchased', 'piece', 0.05, 600, 0);

-- Product (created via the Dynamic Product Builder — output_unit, shelf
-- life, and pricing are all manager-entered, not hard-coded).
INSERT INTO mouneh_products (id, farm_id, name, category, output_unit, default_batch_size, shelf_life_days, warehouse_rules, low_stock_threshold, target_price, wholesale_price, target_margin_pct, status, created_by) VALUES
  ('00000000-0000-0000-0000-000000000200', '00000000-0000-0000-0000-000000000001', 'Makdous', 'Mouneh', 'jar', 100, 365, 'Store in a cool, dark room. Fully submerged in olive oil.', 20, 6.50, 5.00, 40, 'active', '00000000-0000-0000-0000-000000000015');

-- Recipe (Bill of Materials, per a 100-jar batch).
INSERT INTO mouneh_recipes (id, product_id, version, basis_quantity, basis_unit, notes) VALUES
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000200', 1, 100, 'jar', 'Standard Makdous recipe — baby eggplant stuffed with walnuts, red pepper paste and garlic, cured in olive oil.');

INSERT INTO mouneh_recipe_items (recipe_id, material_id, material_type, quantity, unit, loss_percent) VALUES
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000101', 'raw_material', 45, 'kg', 6),
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000102', 'raw_material', 4, 'kg', 0),
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000103', 'raw_material', 3, 'kg', 0),
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000104', 'raw_material', 2, 'kg', 3),
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000105', 'raw_material', 18, 'liter', 0),
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000106', 'raw_material', 2.5, 'kg', 0),
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000107', 'packaging', 100, 'piece', 1),
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000108', 'packaging', 100, 'piece', 1),
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000109', 'packaging', 100, 'piece', 0);

-- Product-level cost template (labor/overhead — applies to every future batch).
INSERT INTO cost_components (id, product_id, cost_type, label, calculation_method, amount, quantity, unit_cost) VALUES
  ('00000000-0000-0000-0000-000000000221', '00000000-0000-0000-0000-000000000200', 'labor', 'Labor (curing + packing)', 'quantity_x_rate', NULL, 10, 5.0),
  ('00000000-0000-0000-0000-000000000222', '00000000-0000-0000-0000-000000000200', 'utilities', 'Gas & Electricity', 'fixed', 14, NULL, NULL),
  ('00000000-0000-0000-0000-000000000223', '00000000-0000-0000-0000-000000000200', 'transport', 'Delivery to market', 'per_output_unit', 0.10, NULL, NULL),
  ('00000000-0000-0000-0000-000000000224', '00000000-0000-0000-0000-000000000200', 'cooling_storage', 'Cold storage allocation', 'fixed', 8, NULL, NULL),
  ('00000000-0000-0000-0000-000000000225', '00000000-0000-0000-0000-000000000200', 'market_fees', 'Co-op commission', 'percentage', 3, NULL, NULL);

-- Batch 1: completed 65 days ago -> 98 jars of finished goods stock.
-- Cost numbers below are the same costing engine's output for this
-- recipe/output_qty=98 (see backend/tests/test_mouneh_costing.py) —
-- snapshotted onto the batch exactly as app/api/v1/mouneh.py would.
INSERT INTO production_batches (id, farm_id, product_id, recipe_version_id, batch_code, planned_qty, actual_output_qty, waste_qty, damaged_qty, quality_status, expiry_date, warehouse_location, status, planned_unit_cost, planned_total_cost, actual_unit_cost, actual_total_cost, labor_hours, started_at, completed_at, created_by) VALUES
  ('00000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000200', '00000000-0000-0000-0000-000000000201', 'MOU-20260620-001', 100, 98, 2, 0, 'good', now() + interval '350 days', 'Storage Room A — Shelf 3', 'completed', 3.6898, 361.6031, 3.6898, 361.6031, 10, now() - interval '66 days', now() - interval '65 days', '00000000-0000-0000-0000-000000000015');

INSERT INTO batch_input_consumptions (batch_id, material_id, planned_qty, actual_qty, unit_cost, total_cost) VALUES
  ('00000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000101', 47.7, 47.7, 1.20, 57.24),
  ('00000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000102', 4.0, 4.0, 7.50, 30.00),
  ('00000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000103', 3.0, 3.0, 3.80, 11.40),
  ('00000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000104', 2.06, 2.06, 2.10, 4.326),
  ('00000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000105', 18.0, 18.0, 6.50, 117.00),
  ('00000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000106', 2.5, 2.5, 0.35, 0.875),
  ('00000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000107', 101.0, 101.0, 0.35, 35.35),
  ('00000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000108', 101.0, 101.0, 0.08, 8.08),
  ('00000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000109', 100.0, 100.0, 0.05, 5.00);

INSERT INTO finished_goods_stock (id, farm_id, product_id, batch_id, warehouse_location, quantity_produced, quantity_available, quantity_sold, unit_cost, expiry_date) VALUES
  ('00000000-0000-0000-0000-000000000400', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000200', '00000000-0000-0000-0000-000000000300', 'Storage Room A — Shelf 3', 98, 53, 45, 3.6898, now() + interval '350 days');

-- Batch 2: still in progress (60-jar batch, started 2 days ago) — shows up
-- as an "active batch" on the dashboard.
INSERT INTO production_batches (id, farm_id, product_id, recipe_version_id, batch_code, planned_qty, status, planned_unit_cost, planned_total_cost, warehouse_location, started_at, created_by) VALUES
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000200', '00000000-0000-0000-0000-000000000201', 'MOU-20260821-001', 60, 'in_progress', 4.1125, 246.7495, 'Storage Room A — Shelf 3', now() - interval '2 days', '00000000-0000-0000-0000-000000000015');

INSERT INTO batch_input_consumptions (batch_id, material_id, planned_qty, unit_cost) VALUES
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000101', 28.62, 1.20),
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000102', 2.4, 7.50),
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000103', 1.8, 3.80),
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000104', 1.236, 2.10),
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000105', 10.8, 6.50),
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000106', 1.5, 0.35),
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000107', 60.6, 0.35),
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000108', 60.6, 0.08),
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000109', 60.0, 0.05);

-- Sales against the completed batch's finished goods (retail/wholesale/market).
INSERT INTO mouneh_sale_lines (id, farm_id, product_id, batch_id, finished_goods_stock_id, quantity, unit_price, discount, channel, cost_per_unit, revenue, margin, sold_at, sold_by) VALUES
  ('00000000-0000-0000-0000-000000000410', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000200', '00000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000400', 20, 6.50, 0, 'retail', 3.6898, 130.00, 56.204, now() - interval '8 days', '00000000-0000-0000-0000-000000000015'),
  ('00000000-0000-0000-0000-000000000411', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000200', '00000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000400', 15, 5.00, 5, 'wholesale', 3.6898, 70.00, 14.653, now() - interval '5 days', '00000000-0000-0000-0000-000000000015'),
  ('00000000-0000-0000-0000-000000000412', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000200', '00000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000400', 10, 6.50, 0, 'market', 3.6898, 65.00, 28.102, now() - interval '2 days', '00000000-0000-0000-0000-000000000015');

INSERT INTO mouneh_events (farm_id, entity_type, entity_id, event_type, payload_json, created_by, created_at) VALUES
  ('00000000-0000-0000-0000-000000000001', 'mouneh_product', '00000000-0000-0000-0000-000000000200', 'product_created', '{"name": "Makdous"}', '00000000-0000-0000-0000-000000000015', now() - interval '67 days'),
  ('00000000-0000-0000-0000-000000000001', 'mouneh_recipe', '00000000-0000-0000-0000-000000000201', 'recipe_created', '{"product_id": "00000000-0000-0000-0000-000000000200", "version": 1}', '00000000-0000-0000-0000-000000000015', now() - interval '67 days'),
  ('00000000-0000-0000-0000-000000000001', 'production_batch', '00000000-0000-0000-0000-000000000300', 'batch_completed', '{"actual_output_qty": 98}', '00000000-0000-0000-0000-000000000015', now() - interval '65 days'),
  ('00000000-0000-0000-0000-000000000001', 'production_batch', '00000000-0000-0000-0000-000000000301', 'batch_started', '{"planned_qty": 60}', '00000000-0000-0000-0000-000000000015', now() - interval '2 days');

COMMIT;

-- Recommendations are intentionally NOT seeded here — call
-- GET /api/v1/recommendations (or GET /api/v1/morning-briefing) once the
-- API is running and it will compute them fresh from the rows above via
-- the rule engine (backend/app/recommendations/engine.py), exactly as
-- CONSTITUTION.md requires: "Every recommendation requires evidence."
