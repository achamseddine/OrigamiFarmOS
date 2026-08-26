-- Creates the complete Origami FarmOS PostgreSQL schema and then loads the
-- optional sample dataset. Run with psql so the relative include commands
-- are supported:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f database/setup_with_sample_data.sql
--
-- Do not use this convenience script for a production database.
\set ON_ERROR_STOP on
\ir schema.sql
\ir sample_data.sql
