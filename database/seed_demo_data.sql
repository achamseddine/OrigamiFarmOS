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

COMMIT;

-- Recommendations are intentionally NOT seeded here — call
-- GET /api/v1/recommendations (or GET /api/v1/morning-briefing) once the
-- API is running and it will compute them fresh from the rows above via
-- the rule engine (backend/app/recommendations/engine.py), exactly as
-- CONSTITUTION.md requires: "Every recommendation requires evidence."
