#!/usr/bin/env bash
# Restore a backup (ADR-015, DB-PLAN 11.5). No existing database with data is ever dropped or overwritten.
#   /opt/starindex/postgres/restore.sh <YYYY-MM-DD | latest | file.dump> <target-db> [--switch]
#   target-db:
#     starindex_restoretest  rehearsal copy, replaced on every run
#     a NEW name             e.g. starindex_20261005 for a real restore next to the live database (refused if it exists)
#     the live database      only while it is still EMPTY (first fill after bootstrap-db.sh, e.g. the RDS → Neon move)
#   --switch (root): after the checks pass, stop the app, point DB_URL at target-db (app.env keeps a .bak copy), start it.
# The admin login creates the database (password typed or ADMIN_PGPASSWORD); the app role restores into it and owns it.
# A mistake noticed within 6 hours is simpler to undo with Neon's instant restore (Console → Backup & Restore).
set -Eeuo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
usage="usage: restore.sh <YYYY-MM-DD|latest|file.dump> <target-db> [--switch]"
src="${1:?$usage}"
target="${2:?$usage}"
switch=""
case "${3:-}" in
  "") ;;
  --switch) switch=1 ;;
  *) die "$usage" ;;
esac
valid_db_name "$target" || die "invalid database name: $target"
parse_db_url
live_db="$PGDATABASE"
if [ -n "$switch" ] && [ "$(id -u)" -ne 0 ]; then die "--switch needs root (systemctl, $APP_ENV)"; fi
if [ -n "$switch" ] && [ "$target" = "$live_db" ]; then die "--switch: $target is already the live database"; fi
app_psql() { ( load_db_env && psql -d "$1" -v ON_ERROR_STOP=1 -tAq -c "$2" ); }
target_exists="$(app_psql "$live_db" "SELECT count(*) FROM pg_database WHERE datname = '$target'")" \
  || die "cannot reach $live_db as the app role (bootstrap-db.sh done?)"
mode=new
if [ "$target" = "$live_db" ]; then
  [ "$(app_psql "$live_db" "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")" = 0 ] \
    || die "$live_db is the live database and has tables: restore next to it under a new name, then --switch"
  mode=fill-empty-live
elif [ "$target" = starindex_restoretest ]; then
  mode=rehearsal
elif [ "$target_exists" != 0 ]; then
  die "$target already exists: choose a new name (an older database may be a rollback copy kept by --switch)"
fi

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
# Before anything is created: the file must be a pg_dump custom-format archive.
pg_restore --list "$work/r.dump" >/dev/null 2>&1 || die "not a pg_dump archive (pg_dump -Fc): $src"

# The app role owns the restore databases, so it can drop the rehearsal copy or a partial new one (never the live one).
drop_target() { ( load_db_env && psql -d "$live_db" -v ON_ERROR_STOP=1 -qc "DROP DATABASE IF EXISTS \"$target\" WITH (FORCE)" ); }
cleanup_failed() {
  trap - ERR
  if [ "$mode" = fill-empty-live ]; then
    # --single-transaction rolled the restore back: the live database is empty again
    echo "restore failed: nothing was committed to $live_db" >&2
  else
    echo "restore failed: dropping the partial $target; the live database $live_db was not touched" >&2
    drop_target || echo "could not drop $target" >&2
  fi
}
trap cleanup_failed ERR

if [ "$mode" = fill-empty-live ]; then
  echo "== fill the empty live database $live_db"
else
  echo "== create $target next to $live_db ($mode)"
  drop_target   # rehearsal copy, or nothing (a new name does not exist)
  ( load_admin_env && psql -v ON_ERROR_STOP=1 -q -v dbname="$target" < "$here/create-db.sql" )
fi
echo "== pg_restore as the app role"
load_db_env
pg_restore --no-owner --no-privileges --no-tablespaces --exit-on-error --single-transaction -d "$target" "$work/r.dump"

echo "== checks"
psql -d "$target" -v ON_ERROR_STOP=1 -tA \
  -c "SELECT 'flyway latest ' || max(version::int) FROM flyway_schema_history WHERE version IS NOT NULL" \
  -c "SELECT 'region rows ' || count(*) FROM region" \
  -c "SELECT 'batch executions ' || count(*) FROM batch_job_execution" \
  -c "SELECT 'data_pack rows ' || count(*) || ', pinned ' || count(*) FILTER (WHERE pinned) FROM data_pack"
trap - ERR

if [ "$mode" = fill-empty-live ]; then
  echo "restored into the live database $live_db (it was empty). Start or restart the app: sudo systemctl restart starindex"
  exit 0
fi
if [ -z "$switch" ]; then
  echo "restored into $target. The app still uses $live_db. To use $target: rerun with a new name and --switch (root)."
  exit 0
fi
echo "== switch the app to $target"
systemctl stop starindex || true
backup="$APP_ENV.bak-$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "$APP_ENV" "$backup"
new_url="$(sed -n 's/^DB_URL=//p' "$APP_ENV" | tail -1 | sed -E "s#^(jdbc:postgresql://[^/]+/)[a-z0-9_]+#\1$target#")"
awk -v url="$new_url" '/^DB_URL=/ { print "DB_URL=" url; next } { print }' "$backup" > "$APP_ENV.new"
chown --reference="$backup" "$APP_ENV.new" && chmod --reference="$backup" "$APP_ENV.new"
mv "$APP_ENV.new" "$APP_ENV"
systemctl start starindex
echo "the app now uses $target. $live_db is kept; to go back: sudo cp -p $backup $APP_ENV && sudo systemctl restart starindex"
