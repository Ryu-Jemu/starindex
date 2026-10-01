#!/usr/bin/env bash
# Restore a backup into the LOCAL PostgreSQL (DB-PLAN 5.6). For RDS follow 5.7 (create-db.sql as the master user).
#   sudo /opt/starindex/postgres/restore.sh <YYYY-MM-DD | latest | /path/file.dump> [starindex_restoretest]
# Without a second argument the live database is replaced: the archive is checked first, the app is stopped, the
# current database is kept as <db>_prev, and any failure puts it back and starts the app again.
# Rehearsal: restore.sh latest starindex_restoretest (the app keeps running).
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
src="${1:?usage: restore.sh <YYYY-MM-DD|latest|file.dump> [starindex_restoretest]}"
load_db_env
live_db="$PGDATABASE"
target="${2:-$live_db}"
# Only the databases pg_hba.conf lets the owner role reach (and never postgres or a template).
[ "$target" = "$live_db" ] || [ "$target" = starindex_restoretest ] \
  || die "target must be $live_db or starindex_restoretest: $target"
is_local_db || die "DB_URL points at $PGHOST: restore.sh only restores into the local PostgreSQL (see DB-PLAN 5.7 for RDS)"
prev="${target}_prev"

work="$(mktemp -d /var/tmp/starindex-restore-XXXXXX)"
chmod 755 "$work"
trap 'rm -rf "$work"' EXIT
if [ -f "$src" ]; then
  install -m 644 "$src" "$work/r.dump"
else
  bucket="$(env_get S3_BUCKET)"
  [ -n "$bucket" ] || die "S3_BUCKET is empty in $APP_ENV"
  if [ "$src" = latest ]; then
    name="$(aws s3 ls --region "$AWS_REGION" "s3://$bucket/backup/db/" | awk '{print $4}' \
      | grep -E '^starindex-[0-9-]+\.dump$' | sort | tail -1)" || true
    [ -n "$name" ] || die "no backup in s3://$bucket/backup/db/"
  else
    [[ "$src" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "expected YYYY-MM-DD, latest or a file: $src"
    name="starindex-$src.dump"
  fi
  aws s3 cp --region "$AWS_REGION" --only-show-errors "s3://$bucket/backup/db/$name" "$work/r.dump"
  chmod 644 "$work/r.dump"
fi
# Before anything is stopped or renamed: the file must be a pg_dump custom-format archive.
pg_restore --list "$work/r.dump" >/dev/null 2>&1 || die "not a pg_dump archive (pg_dump -Fc): $src"

stopped=""
rollback() {
  trap - ERR
  echo "restore failed: removing the partial $target and putting the previous one back" >&2
  as_postgres dropdb --if-exists --force "$target" || true
  if db_exists "$prev"; then
    as_postgres psql -qc "ALTER DATABASE \"$prev\" RENAME TO \"$target\"" || echo "could not rename $prev back to $target" >&2
  fi
  if [ -n "$stopped" ]; then systemctl start starindex || true; fi
}
trap rollback ERR

if [ "$target" = "$live_db" ]; then
  echo "== stopping the app (live database)"
  systemctl stop starindex || true
  stopped=1
fi
echo "== keep the current $target as $prev"
as_postgres dropdb --if-exists --force "$prev"
if db_exists "$target"; then
  as_postgres psql -qc "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$target' AND pid <> pg_backend_pid()" >/dev/null
  as_postgres psql -v ON_ERROR_STOP=1 -qc "ALTER DATABASE \"$target\" RENAME TO \"$prev\""
fi
echo "== create $target and pg_restore"
psql_postgres_file "$here/create-db.sql" -v dbname="$target"
pg_restore --no-owner --no-privileges --exit-on-error -d "$target" "$work/r.dump"

echo "== checks (DB-PLAN 5.6)"
psql -d "$target" -v ON_ERROR_STOP=1 -tA \
  -c "SELECT 'flyway latest ' || max(version::int) FROM flyway_schema_history WHERE version IS NOT NULL" \
  -c "SELECT 'region rows ' || count(*) FROM region" \
  -c "SELECT 'batch executions ' || count(*) FROM batch_job_execution" \
  -c "SELECT 'data_pack rows ' || count(*) || ', pinned ' || count(*) FILTER (WHERE pinned) FROM data_pack"
trap - ERR
if [ -n "$stopped" ]; then
  echo "== starting the app"
  systemctl start starindex
fi
echo "restored into $target. The previous database is kept as $prev (drop it later: sudo -u postgres dropdb $prev)."
echo "Also check: manifest versions exist in data_pack; publish of the same nightDate gives the same version."
