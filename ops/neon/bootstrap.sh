#!/usr/bin/env bash
# One-time database setup on Neon (ADR-015, ADR-017), from the Mac:
#   ops/neon/bootstrap.sh            # asks the neondb_owner password; creates the role starindex and its database
#   ops/neon/bootstrap.sh --github   # … and stores DB_URL / DB_PASSWORD as GitHub Actions secrets (gh, logged in)
#   ops/neon/bootstrap.sh --github --save-local   # … and in backend/.env (git-ignored, 0600) for the local admin page
# The app role gets a fresh random password on every run (re-run = rotation); APP_DB_PASSWORD sets a given one instead.
# Without --github a generated password is printed once at the end: put it in the GitHub secret DB_PASSWORD yourself.
# Idempotent: the role and database are created only when missing (create-db.sql).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
github=""; save_local=""
for a in "$@"; do
  case "$a" in --github) github=1 ;; --save-local) save_local=1 ;; *) die "usage: bootstrap.sh [--github] [--save-local]" ;; esac
done
LOCAL_ENV="${LOCAL_ENV:-$(cd "$here/../.." && pwd)/backend/.env}"
if [ -n "$github" ]; then gh auth status >/dev/null 2>&1 || die "--github: gh is not logged in (gh auth login)"; fi
parse_db_url
db_url="$(setting DB_URL)"
generated=""
if [ -n "${APP_DB_PASSWORD:-}" ]; then pw="$APP_DB_PASSWORD"; else pw="$(openssl rand -base64 32 | tr -d '\n')"; generated=1; fi
[ "${#pw}" -ge 24 ] || die "APP_DB_PASSWORD is too short (Neon wants ≥60 bits of entropy; use ≥24 random characters)"

echo "== role starindex and database $APP_DB (admin login)"
load_admin_env
psql -v ON_ERROR_STOP=1 -q -v dbname="$APP_DB" < "$here/create-db.sql"
# stdin only: the password never appears in argv or shell history. Neon rejects pre-hashed passwords.
printf "ALTER ROLE starindex PASSWORD '%s';\n" "${pw//\'/\'\'}" | psql -v ON_ERROR_STOP=1 -q

echo "== check as the app role"
( export PGUSER=starindex PGDATABASE="$APP_DB" PGPASSWORD="$pw"
  psql -v ON_ERROR_STOP=1 -tA -c "SELECT 'connected as ' || current_user || ' to ' || current_database()
    || ', PostgreSQL ' || current_setting('server_version')
    || ', superuser ' || (SELECT rolsuper::text FROM pg_roles WHERE rolname = current_user)
    || ', createdb ' || (SELECT rolcreatedb::text FROM pg_roles WHERE rolname = current_user)"
  # TLS as the client sees it (Neon ends TLS at its proxy, so pg_stat_ssl on the compute shows none).
  tls="$(psql -tA -c '\conninfo' 2>/dev/null | grep -oE 'TLSv1\.[0-9]' | head -1)" || true
  echo "client TLS: ${tls:-none} (sslmode=$PGSSLMODE, channel_binding=${PGCHANNELBINDING:-default})" )

if [ -n "$save_local" ]; then
  echo "== $LOCAL_ENV (DB_URL, DB_USERNAME, DB_PASSWORD for the local admin page)"
  touch "$LOCAL_ENV" && chmod 600 "$LOCAL_ENV"
  for kv in "DB_URL=$db_url" "DB_USERNAME=starindex" "DB_PASSWORD=$pw"; do
    k="${kv%%=*}"
    tmp="$(mktemp "$LOCAL_ENV.XXXXXX")"
    # Replace or append without interpreting the value (URLs carry & ? / =; passwords carry + / =).
    KEY="$k" LINE="$kv" awk 'BEGIN { k = ENVIRON["KEY"]; l = ENVIRON["LINE"]; done = 0 }
      index($0, k "=") == 1 { if (!done) print l; done = 1; next } { print } END { if (!done) print l }' "$LOCAL_ENV" > "$tmp"
    chmod 600 "$tmp" && mv -f "$tmp" "$LOCAL_ENV"
  done
fi

if [ -n "$github" ]; then
  echo "== GitHub Actions secrets (DB_URL, DB_PASSWORD) for the ETL workflow"
  printf '%s' "$db_url" | gh secret set DB_URL
  printf '%s' "$pw" | gh secret set DB_PASSWORD
  echo "done. The next scheduled ETL run (or: gh workflow run etl) creates the tables with Flyway."
elif [ -n "$generated" ] && [ -z "$save_local" ]; then
  echo "done. App role password (shown once; store it as the GitHub secret DB_PASSWORD, then forget it):"
  echo "$pw"
else
  echo "done. The app role password is in ${save_local:+$LOCAL_ENV}${save_local:-the APP_DB_PASSWORD you gave}."
fi
