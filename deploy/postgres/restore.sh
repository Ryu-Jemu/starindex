#!/usr/bin/env bash
# Restore a backup into the LOCAL PostgreSQL (DB-PLAN 5.6). For RDS follow 5.7 (create-db.sql as the master user).
#   sudo /opt/starindex/postgres/restore.sh <YYYY-MM-DD | latest | /path/file.dump> [target-db]
# target-db defaults to the live database; then the app is stopped during the restore and started again.
# Rehearsal: restore.sh latest starindex_restoretest (the app keeps running).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
src="${1:?usage: restore.sh <YYYY-MM-DD|latest|file.dump> [target-db]}"
load_db_env
live_db="$PGDATABASE"
target="${2:-$live_db}"
[[ "$target" =~ ^[a-z_][a-z0-9_]*$ ]] || die "invalid database name: $target"
is_local_db || die "DB_URL points at $PGHOST: restore.sh only restores into the local PostgreSQL (see DB-PLAN 5.7 for RDS)"

work="$(mktemp -d /var/tmp/starindex-restore-XXXXXX)"
chmod 755 "$work"
trap 'rm -rf "$work"' EXIT
if [ -f "$src" ]; then
  install -m 644 "$src" "$work/r.dump"
else
  bucket="$(env_get S3_BUCKET)"
  [ -n "$bucket" ] || die "S3_BUCKET is empty in $APP_ENV"
  if [ "$src" = latest ]; then
    name="$(aws s3 ls --region "$AWS_REGION" "s3://$bucket/backup/db/" | awk '{print $4}' | grep -E '^starindex-[0-9-]+\.dump$' | sort | tail -1)"
    [ -n "$name" ] || die "no backup in s3://$bucket/backup/db/"
  else
    [[ "$src" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "expected YYYY-MM-DD, latest or a file: $src"
    name="starindex-$src.dump"
  fi
  aws s3 cp --region "$AWS_REGION" --only-show-errors "s3://$bucket/backup/db/$name" "$work/r.dump"
  chmod 644 "$work/r.dump"
fi

restarted=""
if [ "$target" = "$live_db" ]; then
  echo "== stopping the app (live database)"
  systemctl stop starindex || true
  restarted=1
fi
echo "== recreate $target"
as_postgres dropdb --if-exists --force "$target"
as_postgres psql -v ON_ERROR_STOP=1 -q -v dbname="$target" -f "$here/create-db.sql"
echo "== pg_restore"
pg_restore --no-owner --no-privileges --exit-on-error -d "$target" "$work/r.dump"

echo "== checks (DB-PLAN 5.6)"
psql -d "$target" -v ON_ERROR_STOP=1 -tA \
  -c "SELECT 'flyway latest ' || max(version::int) FROM flyway_schema_history WHERE version IS NOT NULL" \
  -c "SELECT 'region rows ' || count(*) FROM region" \
  -c "SELECT 'batch executions ' || count(*) FROM batch_job_execution" \
  -c "SELECT 'data_pack rows ' || count(*) || ', pinned ' || count(*) FILTER (WHERE pinned) FROM data_pack"
if [ -n "$restarted" ]; then
  echo "== starting the app"
  systemctl start starindex
fi
echo "restored into $target. Also check: manifest versions exist in data_pack; publish of the same nightDate gives the same version."
