-- DB-PLAN 5.2: owner role and database. Same SQL on EC2 (as postgres) and RDS (as the master user, not a superuser).
--   psql -v ON_ERROR_STOP=1 -v dbname=starindex -f create-db.sql
-- Idempotent. The password is set separately through stdin (install.sh), never on a command line.
SELECT 'CREATE ROLE starindex LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'starindex') \gexec
-- "To create a database owned by another role, you must be able to SET ROLE to that role" (CREATE DATABASE docs).
-- Since PostgreSQL 16 the creator of a role is a member WITH ADMIN but without SET (createrole_self_grant is empty),
-- so test SET, not membership (verified: PG 18.6, non-superuser CREATEROLE CREATEDB master). A superuser qualifies.
SELECT 'GRANT starindex TO CURRENT_USER WITH SET TRUE' WHERE NOT pg_has_role(current_user, 'starindex', 'SET') \gexec
SELECT format('CREATE DATABASE %I OWNER starindex TEMPLATE template0 ENCODING %L LOCALE %L', :'dbname', 'UTF8', 'C')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'dbname') \gexec
