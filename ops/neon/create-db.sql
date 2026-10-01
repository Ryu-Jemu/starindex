-- Owner role and database (ADR-015, ADR-017). Run by ops/neon/bootstrap.sh / restore.sh with the ADMIN login:
-- Neon neondb_owner on neondb, or any CREATEROLE CREATEDB role. Never a superuser need.
--   psql -v ON_ERROR_STOP=1 -v dbname=starindex < create-db.sql
-- Idempotent. The password is set separately through stdin, never on a command line.
-- The role is created with SQL, so it has plain privileges (no neon_superuser, no CREATEDB).
SELECT 'CREATE ROLE starindex LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'starindex') \gexec
-- "To create a database owned by another role, you must be able to SET ROLE to that role" (CREATE DATABASE docs).
-- Since PostgreSQL 16 the creator of a role is a member WITH ADMIN but without SET (createrole_self_grant is empty),
-- so test SET, not membership (verified on PG 18.6 with a non-superuser CREATEROLE CREATEDB admin).
SELECT 'GRANT starindex TO CURRENT_USER WITH SET TRUE' WHERE NOT pg_has_role(current_user, 'starindex', 'SET') \gexec
SELECT format('CREATE DATABASE %I OWNER starindex TEMPLATE template0 ENCODING %L LOCALE %L', :'dbname', 'UTF8', 'C')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'dbname') \gexec
