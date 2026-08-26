-- Origami FarmOS optional sample dataset.
-- Development/test use only. Apply after database/schema.sql.
-- The sample account password is `change-me-now`; change or delete it
-- immediately if this dataset is loaded into any shared environment.

BEGIN;

INSERT INTO farms (id, name, country, region, timezone, default_currency)
VALUES ('00000000-0000-0000-0000-000000000001', 'Sample Farm', 'Lebanon', 'Bekaa', 'Asia/Beirut', 'USD');

INSERT INTO users (id, farm_id, name, email, password_hash, role, language)
VALUES (
  '00000000-0000-0000-0000-000000000010',
  '00000000-0000-0000-0000-000000000001',
  'Sample Manager',
  'manager@example.invalid',
  crypt('change-me-now', gen_salt('bf', 12)),
  'manager',
  'en'
);

INSERT INTO suppliers (id, farm_id, name)
VALUES
  ('00000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000001', 'Sample Feed Supplier');

INSERT INTO animals (
  id, farm_id, tag, name, species, breed, sex, birth_date, status,
  location_label, health_score, lactating, group_name
) VALUES
  ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000001', 'C-101', 'Sample Cow', 'cow', 'Holstein', 'F', now() - interval '3 years', 'healthy', 'North Barn', 92, true, 'Dairy Herd'),
  ('00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000001', 'G-102', 'Sample Goat', 'goat', 'Saanen', 'F', now() - interval '2 years', 'under_observation', 'Goat Barn', 78, false, 'Goat Herd');

INSERT INTO inventory_items (
  id, farm_id, name, category, unit, current_qty, reorder_level,
  supplier_id, supplier_label, unit_cost, last_purchase
) VALUES
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000001', 'Dairy Feed', 'feed', 'kg', 1250, 500, '00000000-0000-0000-0000-000000000020', 'Sample Feed Supplier', 0.40, now() - interval '7 days'),
  ('00000000-0000-0000-0000-000000000202', '00000000-0000-0000-0000-000000000001', 'Mineral Mix', 'supplement', 'kg', 80, 50, '00000000-0000-0000-0000-000000000020', 'Sample Feed Supplier', 1.25, now() - interval '7 days');

INSERT INTO tasks (id, farm_id, title, description, due_at, priority, status)
VALUES
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000001', 'Review sample animal records', 'Sample task that can be deleted.', now() + interval '1 day', 'medium', 'open');

INSERT INTO milk_records (
  id, animal_id, session, liters, quality_status, destination, recorded_at,
  recorded_by
) VALUES
  ('00000000-0000-0000-0000-000000000401', '00000000-0000-0000-0000-000000000101', 'morning', 18.5, 'normal', 'stored', now(), '00000000-0000-0000-0000-000000000010');

COMMIT;
