#!/usr/bin/env bash
# EC2 host setup (Amazon Linux 2023), ADR-015. The database is Neon, so only the PostgreSQL 18 client is installed
# (psql, pg_dump, pg_restore; the client major must be >= the server's). Idempotent: run again after any edit.
#   sudo deploy/ec2/install.sh
# Needs: /etc/starindex/app.env (deploy/app/app.env.example) and SSM SecureString /starindex/db/password readable by
# the instance role. Next: sudo /opt/starindex/postgres/bootstrap-db.sh (once), then sudo systemctl enable --now starindex.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
deploy="$(dirname "$here")"
# shellcheck source=../postgres/lib.sh
. "$deploy/postgres/lib.sh"
[ -f "$APP_ENV" ] || die "create $APP_ENV first: copy deploy/app/app.env.example, set DB_URL (Neon direct endpoint) and S3_BUCKET"

echo "== packages: PostgreSQL 18 client, Valkey"
dnf -y -q install postgresql18 valkey

echo "== app user and directories"
id starindex >/dev/null 2>&1 || useradd --system --home-dir /var/lib/starindex --shell /sbin/nologin starindex
install -d -o starindex -g starindex -m 750 /var/lib/starindex /var/log/starindex
install -d -m 755 /opt/starindex /opt/starindex/postgres
# No secrets inside, but the backup timer runs as starindex and reads it.
chown root:starindex "$APP_ENV" && chmod 640 "$APP_ENV"

echo "== valkey: localhost only, 128 MB, no persistence (PLAN 3.4)"
conf=/etc/valkey/valkey.conf
before="$(sha256sum "$conf")"
sed -i '/^# >>> starindex/,/^# <<< starindex/d' "$conf"
cat >> "$conf" <<'CONF'
# >>> starindex (deploy/ec2/install.sh; later lines override the defaults above)
bind 127.0.0.1 -::1
protected-mode yes
maxmemory 128mb
maxmemory-policy volatile-lru
save ""
appendonly no
# <<< starindex
CONF
systemctl enable --now valkey
# Only when the config changed: a restart empties Valkey (no persistence), including today's API quota counters.
if [ "$(sha256sum "$conf")" != "$before" ]; then systemctl restart valkey; fi

echo "== operation scripts and units"
install -m 644 "$deploy/postgres/lib.sh" "$deploy/postgres/create-db.sql" /opt/starindex/postgres/
install -m 755 "$deploy/postgres/bootstrap-db.sh" "$deploy/postgres/backup.sh" "$deploy/postgres/restore.sh" \
  "$deploy/postgres/pin.sh" /opt/starindex/postgres/
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

echo "== database"
if ( load_db_env && psql -v ON_ERROR_STOP=1 -tAc "SELECT 1" >/dev/null 2>&1 ); then
  echo "reachable as the app role: $(env_get DB_URL | sed 's/?.*//')"
else
  echo "not reachable as the app role yet: run sudo /opt/starindex/postgres/bootstrap-db.sh"
fi
echo "done"
