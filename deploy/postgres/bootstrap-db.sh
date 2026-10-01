#!/usr/bin/env bash
# One-time database setup (ADR-015). Run on the EC2 after deploy/ec2/install.sh:
#   sudo /opt/starindex/postgres/bootstrap-db.sh        # asks the admin password (Neon: neondb_owner on neondb)
#   ADMIN_USER=… ADMIN_DB=… to use another admin login (RDS: the master user on postgres).
# Creates the role starindex with plain privileges and the database named in DB_URL owned by it, then sets the role
# password from SSM /starindex/db/password through stdin. Idempotent: re-run (as root) after rotating the SSM password;
# a running app is restarted so it picks up the new password.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
parse_db_url
app_db="$PGDATABASE"
[ "$(env_get DB_USERNAME)" = starindex ] || die "create-db.sql creates the role starindex: set DB_USERNAME=starindex in $APP_ENV"
pw="$(ssm /starindex/db/password)" || die "create the SSM SecureString /starindex/db/password first (openssl rand -base64 32)"
[ -n "$pw" ] || die "/starindex/db/password is empty"

echo "== role starindex and database $app_db (admin login)"
load_admin_env
psql -v ON_ERROR_STOP=1 -q -v dbname="$app_db" < "$here/create-db.sql"
# stdin only: the password never appears in argv or the shell history. Neon rejects pre-hashed passwords.
printf "ALTER ROLE starindex PASSWORD '%s';\n" "${pw//\'/\'\'}" | psql -v ON_ERROR_STOP=1 -q
unset pw

echo "== check as the app role"
load_db_env
psql -v ON_ERROR_STOP=1 -tA -c "SELECT 'connected as ' || current_user || ' to ' || current_database()
  || ', PostgreSQL ' || current_setting('server_version')
  || ', superuser ' || (SELECT rolsuper::text FROM pg_roles WHERE rolname = current_user)"
# TLS as the client sees it: Neon ends TLS at its proxy, so pg_stat_ssl on the compute shows no TLS (seen 2026-10-01).
tls="$(psql -tA -c '\conninfo' 2>/dev/null | grep -oE 'TLSv1\.[0-9]' | head -1)" || true
echo "client TLS: ${tls:-none} (sslmode=${PGSSLMODE:-default}, channel_binding=${PGCHANNELBINDING:-default})"
# A running app keeps the password it read from SSM at start: restart it so new connections use the new one.
if systemctl is-active -q starindex 2>/dev/null; then
  echo "== restarting the app (it read the old password at start)"
  systemctl restart starindex
  echo "done."
else
  echo "done. Start the app: sudo systemctl enable --now starindex (Flyway creates the tables)."
fi
