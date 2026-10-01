# shellcheck shell=bash
# Shared by backup.sh, restore.sh, pin.sh (DB-PLAN 5.4–5.6). The connection comes from DB_URL in the app's
# EnvironmentFile, so the same scripts work for EC2 PostgreSQL and RDS; the password comes from SSM.
APP_ENV="${APP_ENV:-/etc/starindex/app.env}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

die() { echo "$*" >&2; exit 1; }

ssm() { aws ssm get-parameter --region "$AWS_REGION" --with-decryption --name "$1" --query Parameter.Value --output text; }

# A value comes from the environment when systemd already exported it (EnvironmentFile of the unit), otherwise from
# the file. The file is systemd syntax (unquoted values with spaces), so it is read, not sourced.
env_get() {
  local v="${!1-}"
  if [ -n "$v" ]; then printf '%s\n' "$v"; return; fi
  [ -r "$APP_ENV" ] || die "cannot read $APP_ENV (install.sh makes it root:starindex 0640)"
  sed -n "s/^$1=//p" "$APP_ENV" | tail -1
}

# DB_URL=jdbc:postgresql://host[:port]/db[?sslmode=…] → PGHOST PGPORT PGDATABASE [PGSSLMODE]; PGUSER, PGPASSWORD.
load_db_env() {
  local url rest hostport path query
  url="$(env_get DB_URL)"
  rest="${url#jdbc:postgresql://}"
  [ "$rest" != "$url" ] || die "DB_URL is not jdbc:postgresql://…: $url"
  hostport="${rest%%/*}"; path="${rest#*/}"
  export PGHOST="${hostport%%:*}"
  if [[ "$hostport" == *:* ]]; then export PGPORT="${hostport##*:}"; else export PGPORT=5432; fi
  export PGDATABASE="${path%%\?*}"
  query=""; [[ "$path" == *\?* ]] && query="${path#*\?}"
  if [[ "$query" =~ (^|&)sslmode=([^&]+) ]]; then export PGSSLMODE="${BASH_REMATCH[2]}"; fi
  PGUSER="$(env_get DB_USERNAME)"; export PGUSER="${PGUSER:-starindex}"
  PGPASSWORD="$(ssm /starindex/db/password)" || die "cannot read /starindex/db/password from SSM"
  export PGPASSWORD
}

# Administrative commands on the local server: peer auth as postgres over the socket, never the app's PG* settings.
as_postgres() {
  runuser -u postgres -- env -u PGHOST -u PGPORT -u PGDATABASE -u PGUSER -u PGPASSWORD -u PGSSLMODE "$@"
}

# Run psql as postgres on an SQL file that root opens: works even when the checkout is in a 0700 home directory.
psql_postgres_file() {  # psql_postgres_file <file> [psql args…]
  local file="$1"; shift
  as_postgres psql -v ON_ERROR_STOP=1 -q "$@" < "$file"
}

db_exists() { [ "$(as_postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$1'")" = 1 ]; }

is_local_db() { [ "$PGHOST" = 127.0.0.1 ] || [ "$PGHOST" = localhost ] || [ "$PGHOST" = "::1" ]; }
