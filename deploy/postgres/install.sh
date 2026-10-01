#!/usr/bin/env bash
# PostgreSQL 18 on the app EC2 (Amazon Linux 2023), DB-PLAN 5. Idempotent: run again after any edit.
#   sudo deploy/postgres/install.sh
# Needs: /etc/starindex/app.env (deploy/app/app.env.example), SSM SecureString /starindex/db/password readable by the
# instance role, and the AL2023 repository. Verified in an amazonlinux:2023 container (2023.12.20260918,
# postgresql18-server 18.6): package names, PGDATA, postgresql-setup, unit name.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
deploy="$(dirname "$here")"
# shellcheck source=lib.sh
. "$here/lib.sh"
PGDATA=/var/lib/pgsql/data
[ -f "$APP_ENV" ] || die "create $APP_ENV first: copy deploy/app/app.env.example and set S3_BUCKET"

echo "== packages"
dnf -y -q install postgresql18-server postgresql18

echo "== app user and directories"
id starindex >/dev/null 2>&1 || useradd --system --home-dir /var/lib/starindex --shell /sbin/nologin starindex
install -d -o starindex -g starindex -m 750 /var/lib/starindex /var/log/starindex
install -d -m 755 /opt/starindex /opt/starindex/postgres
# No secrets inside, but the backup timer runs as starindex and reads it.
chown root:starindex "$APP_ENV" && chmod 640 "$APP_ENV"

echo "== cluster (locale C, UTF8)"
# postgresql-setup refuses to run while systemd reports NeedDaemonReload=yes (e.g. right after the package install).
systemctl daemon-reload
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  PGSETUP_INITDB_OPTIONS="--locale=C --encoding=UTF8 --auth-local=peer --auth-host=scram-sha-256" postgresql-setup --initdb
fi
install -o postgres -g postgres -m 600 "$here/pg_hba.conf" "$PGDATA/pg_hba.conf"
# No OOM drop-in: the AL2023 unit already sets OOMScoreAdjust=-1000 for the postmaster and PG_OOM_ADJUST_VALUE=0 for
# backends (verified), which is stronger than the -900 DB-PLAN 5.2 planned. Under pressure the JVM goes first.
systemctl enable --now postgresql
psql_postgres_file "$here/tune.sql"
systemctl restart postgresql

echo "== role and database"
psql_postgres_file "$here/create-db.sql" -v dbname=starindex
pw="$(ssm /starindex/db/password)" || die "create the SSM SecureString /starindex/db/password first (openssl rand -base64 32)"
[ -n "$pw" ] || die "/starindex/db/password is empty"
# stdin only: the password never appears in argv or the shell history
printf "ALTER ROLE starindex PASSWORD '%s';\n" "${pw//\'/\'\'}" | runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q
unset pw

echo "== operation scripts and units"
install -m 644 "$here/lib.sh" "$here/create-db.sql" /opt/starindex/postgres/
install -m 755 "$here/backup.sh" "$here/restore.sh" "$here/pin.sh" /opt/starindex/postgres/
install -m 755 "$deploy/app/start.sh" /opt/starindex/start.sh
install -m 644 "$deploy/systemd/starindex.service" "$deploy/systemd/starindex-pgdump.service" \
  "$deploy/systemd/starindex-pgdump.timer" /etc/systemd/system/
systemctl daemon-reload
if [ -n "$(env_get S3_BUCKET)" ]; then
  systemctl enable --now starindex-pgdump.timer
else
  echo "S3_BUCKET is empty in $APP_ENV: daily backup timer not enabled"
fi

echo "== swap 2 GiB, swappiness 10 (DB-PLAN 5.3)"
if ! swapon --show=NAME --noheadings | grep -q '^/swapfile$'; then
  [ -f /swapfile ] || { dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none && chmod 600 /swapfile && mkswap /swapfile >/dev/null; }
  swapon /swapfile || echo "swapon failed (container?)"
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi
install -d /etc/sysctl.d
echo 'vm.swappiness = 10' > /etc/sysctl.d/90-starindex.conf
sysctl -q -p /etc/sysctl.d/90-starindex.conf || echo "sysctl not applied (container?)"

echo "== check"
runuser -u postgres -- psql -tA -c "SELECT version()" -c "SHOW shared_buffers" -c "SHOW listen_addresses" \
  -c "SELECT datname || ' ' || datcollate FROM pg_database WHERE datname = 'starindex'"
echo "done. Next: DB-PLAN 5.7 (cutover) or start the app: systemctl enable --now starindex"
