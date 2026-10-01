#!/usr/bin/env bash
# Restore a pg_dump archive into a NEW database next to the live one (ADR-017; never overwrites existing data).
#   ops/neon/restore.sh <file.dump | file.dump.enc> <new-db>
# Daily archives are GitHub Actions artifacts of the etl workflow (7 days), encrypted because the repository is public:
#   gh run download <run-id> -n starindex-db-<date> -D /tmp/restore && ops/neon/restore.sh /tmp/restore/starindex.dump.enc starindex_20261005
# The key is BACKUP_KEY from the environment, else from ops/neon/app.env (the GitHub secret cannot be read back).
# The admin login creates the database owned by starindex and restores AS starindex (SET ROLE), so the app owns
# every object. A failed restore drops the partial database. Switching the ETL to it = changing the DB_URL secret.
# A mistake noticed within 6 hours is simpler to undo with Neon's instant restore (Console → Backup & Restore).
set -Eeuo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
usage="usage: restore.sh <file.dump | file.dump.enc> <new-db>"
src="${1:?$usage}"
target="${2:?$usage}"
[ -f "$src" ] || die "no such file: $src"
valid_db_name "$target" || die "invalid database name: $target"
parse_db_url
live_db="$APP_DB"
[ "$target" != "$live_db" ] || die "$target is the live database: restore next to it under a new name"
load_admin_env
admin_db="$PGDATABASE"
exists="$(psql -v ON_ERROR_STOP=1 -tAq -c "SELECT count(*) FROM pg_database WHERE datname = '$target'")"
[ "$exists" = 0 ] || die "$target already exists: choose a new name"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
case "$src" in
  *.enc)
    key="${BACKUP_KEY:-}"
    [ -n "$key" ] || { [ -r "$here/app.env" ] && key="$(sed -n 's/^BACKUP_KEY=//p' "$here/app.env" | tail -1)"; }
    [ -n "$key" ] || die "$src is encrypted: set BACKUP_KEY (or keep it in $here/app.env)"
    # The workflow's parameters (etl-attempt.yml, Backup); OpenSSL 1.1.1+/3.x and macOS LibreSSL both read them.
    BACKUP_KEY="$key" openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -pass env:BACKUP_KEY \
      -in "$src" -out "$work/r.dump" 2>/dev/null || die "cannot decrypt $src (wrong BACKUP_KEY?)"
    unset key ;;
  *) cp "$src" "$work/r.dump" ;;
esac
# Before anything is created (and before the ERR trap): the file must be a pg_dump custom-format archive.
if ! listing_err="$(cd "$work" && pg18 pg_restore --list r.dump 2>&1 >/dev/null)"; then
  case "$listing_err" in
    *"Docker is not running"*|*"not found locally"*) die "${listing_err#error: }" ;;
    *) die "not a pg_dump custom-format archive: $src" ;;
  esac
fi

cleanup_failed() {
  trap - ERR
  echo "restore failed: dropping the partial $target; $live_db was not touched" >&2
  PGDATABASE="$admin_db" psql -v ON_ERROR_STOP=1 -qc "DROP DATABASE IF EXISTS \"$target\" WITH (FORCE)" || echo "could not drop $target" >&2
}
trap cleanup_failed ERR

echo "== create $target (owner starindex) next to $live_db"
psql -v ON_ERROR_STOP=1 -q -v dbname="$target" < "$here/create-db.sql"
echo "== pg_restore as starindex"
# No subshell here: with errtrace the ERR trap would run inside it and again in this shell.
cd "$work"
PGDATABASE="$target" pg18 pg_restore --role=starindex --no-owner --no-privileges --no-tablespaces \
  --exit-on-error --single-transaction -d "$target" r.dump

echo "== checks"
PGDATABASE="$target" psql -v ON_ERROR_STOP=1 -tA \
  -c "SELECT 'flyway latest ' || max(version::int) FROM flyway_schema_history WHERE version IS NOT NULL" \
  -c "SELECT 'region rows ' || count(*) FROM region" \
  -c "SELECT 'batch executions ' || count(*) FROM batch_job_execution" \
  -c "SELECT 'data_pack rows ' || count(*) || ', pinned ' || count(*) FILTER (WHERE pinned) FROM data_pack" \
  -c "SELECT 'tables not owned by starindex ' || count(*) FROM pg_tables WHERE schemaname = 'public' AND tableowner <> 'starindex'"
trap - ERR
new_url="$(setting DB_URL | sed -E "s#^(jdbc:postgresql://[^/]+/)[a-z0-9_]+#\1$target#")"
echo "restored into $target; the ETL still uses $live_db. To switch: printf '%s' '$new_url' | gh secret set DB_URL"
