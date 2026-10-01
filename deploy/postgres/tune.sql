-- DB-PLAN 5.2: PostgreSQL 18 on the app EC2 (t4g.small, ~1.9 GiB shared with the JVM and Valkey).
-- Applied by install.sh as the postgres superuser, then restarted (shared_buffers, max_connections, huge_pages,
-- listen_addresses need a restart). On RDS the same values go into a DB parameter group instead.
-- scripts/ec2sim.sh checks that docker-compose.ec2sim.yml uses the same memory values.
ALTER SYSTEM SET listen_addresses = 'localhost';
ALTER SYSTEM SET max_connections = 20;
ALTER SYSTEM SET shared_buffers = '128MB';
ALTER SYSTEM SET effective_cache_size = '256MB';
ALTER SYSTEM SET work_mem = '4MB';
ALTER SYSTEM SET maintenance_work_mem = '32MB';
ALTER SYSTEM SET huge_pages = 'off';
ALTER SYSTEM SET max_wal_size = '256MB';
ALTER SYSTEM SET min_wal_size = '64MB';
ALTER SYSTEM SET checkpoint_timeout = '15min';
ALTER SYSTEM SET password_encryption = 'scram-sha-256';
ALTER SYSTEM SET timezone = 'UTC';
ALTER SYSTEM SET log_timezone = 'Asia/Seoul';
ALTER SYSTEM SET idle_in_transaction_session_timeout = '5min';
ALTER SYSTEM SET log_min_duration_statement = '1s';
