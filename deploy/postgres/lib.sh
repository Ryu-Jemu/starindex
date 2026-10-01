# shellcheck shell=bash
# Shared by the deploy scripts (ADR-015). The database is Neon (or RDS / any PostgreSQL 18): the app's connection comes
# from DB_URL in the EnvironmentFile, its password from SSM. Administrative steps (role and databases) use a separate
# admin login (Neon: neondb_owner on neondb) whose password is typed or passed in ADMIN_PGPASSWORD, never stored.
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

valid_db_name() { [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; }

# DB_URL=jdbc:postgresql://host[:port]/db[?sslmode=…&channelBinding=…]
#   → PGHOST PGPORT PGDATABASE, PGSSLMODE and PGCHANNELBINDING when given (libpq names for pgjdbc's parameters).
parse_db_url() {
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
  if [[ "$query" =~ (^|&)channelBinding=([^&]+) ]]; then export PGCHANNELBINDING="${BASH_REMATCH[2]}"; fi
  valid_db_name "$PGDATABASE" || die "unexpected database name in DB_URL: $PGDATABASE"
}

# The app role (DB_USERNAME, password from SSM).
load_db_env() {
  parse_db_url
  PGUSER="$(env_get DB_USERNAME)"; export PGUSER="${PGUSER:-starindex}"
  PGPASSWORD="$(ssm /starindex/db/password)" || die "cannot read /starindex/db/password from SSM"
  export PGPASSWORD
}

# The admin login on the same server: ADMIN_USER (default neondb_owner) on ADMIN_DB (default neondb).
# RDS: ADMIN_USER=<master user> ADMIN_DB=postgres.
load_admin_env() {
  parse_db_url
  export PGUSER="${ADMIN_USER:-neondb_owner}" PGDATABASE="${ADMIN_DB:-neondb}"
  if [ -z "${ADMIN_PGPASSWORD:-}" ]; then
    # /dev/tty exists even without a controlling terminal; only opening it tells.
    { : </dev/tty; } 2>/dev/null || die "no terminal: set ADMIN_PGPASSWORD (the $PGUSER password) in the environment"
    read -rsp "password for $PGUSER@$PGHOST/$PGDATABASE: " ADMIN_PGPASSWORD </dev/tty \
      || die "no password: set ADMIN_PGPASSWORD or run this from a terminal"
    echo >&2
  fi
  export PGPASSWORD="$ADMIN_PGPASSWORD"
}
