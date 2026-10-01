# shellcheck shell=bash
# Shared by ops/neon/*.sh (ADR-017): run from the operator's Mac (or a CI runner) against the Neon project.
# Settings: the environment, else ops/neon/neon.env (see neon.env.example). Passwords are never stored in files:
#   NEON_ADMIN_PASSWORD  the neondb_owner password (typed when unset)
NEON_ENV_FILE="${NEON_ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/neon.env}"

die() { echo "error: $*" >&2; exit 1; }

# setting <NAME>: the environment first, then the last NAME=… line of neon.env (read, never sourced: values hold & ?).
setting() {
  local v="${!1-}"
  if [ -n "$v" ]; then printf '%s\n' "$v"; return; fi
  [ -r "$NEON_ENV_FILE" ] && sed -n "s/^$1=//p" "$NEON_ENV_FILE" | tail -1
}

valid_db_name() { [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; }

# DB_URL=jdbc:postgresql://host[:port]/db[?sslmode=…&channelBinding=…] → PGHOST PGPORT PGDATABASE PGSSLMODE PGCHANNELBINDING
parse_db_url() {
  local url rest hostport path query
  url="$(setting DB_URL)"
  [ -n "$url" ] || die "DB_URL is not set (environment or $NEON_ENV_FILE)"
  rest="${url#jdbc:postgresql://}"
  [ "$rest" != "$url" ] || die "DB_URL is not jdbc:postgresql://…"
  hostport="${rest%%/*}"; path="${rest#*/}"
  export PGHOST="${hostport%%:*}"
  if [[ "$hostport" == *:* ]]; then export PGPORT="${hostport##*:}"; else export PGPORT=5432; fi
  [[ "$PGHOST" == *-pooler* ]] && die "DB_URL uses the pooled endpoint ($PGHOST): use the direct host (without -pooler)"
  export PGDATABASE="${path%%\?*}"
  query=""; [[ "$path" == *\?* ]] && query="${path#*\?}"
  export PGSSLMODE=require
  if [[ "$query" =~ (^|&)sslmode=([^&]+) ]]; then PGSSLMODE="${BASH_REMATCH[2]}"; fi
  if [[ "$query" =~ (^|&)channelBinding=([^&]+) ]]; then export PGCHANNELBINDING="${BASH_REMATCH[2]}"; fi
  case "$PGSSLMODE" in require|verify-ca|verify-full) ;; *) die "DB_URL must require TLS (sslmode=$PGSSLMODE)" ;; esac
  valid_db_name "$PGDATABASE" || die "unexpected database name in DB_URL: $PGDATABASE"
  # shellcheck disable=SC2034  # read by the scripts that source this file
  APP_DB="$PGDATABASE"
}

# The admin login (neondb_owner on neondb). PGPASSWORD lives in this shell only, never in argv or a file.
load_admin_env() {
  export PGUSER PGDATABASE
  PGUSER="$(setting NEON_ADMIN_USER)"; PGUSER="${PGUSER:-neondb_owner}"
  PGDATABASE="$(setting NEON_ADMIN_DB)"; PGDATABASE="${PGDATABASE:-neondb}"
  if [ -z "${NEON_ADMIN_PASSWORD:-}" ]; then
    { : </dev/tty; } 2>/dev/null || die "no terminal: set NEON_ADMIN_PASSWORD (the $PGUSER password) for this command"
    read -rsp "password for $PGUSER@$PGHOST/$PGDATABASE: " NEON_ADMIN_PASSWORD </dev/tty || die "no password"
    echo >&2
  fi
  export PGPASSWORD="$NEON_ADMIN_PASSWORD"
}

# pg18 <tool> [args…]: a PostgreSQL 18 client tool. pg_dump/pg_restore must be at least the server's major (18); the
# Mac has Homebrew 17, so fall back to the postgres:18 image (stdin/stdout and the PG* environment pass through;
# the current directory is mounted for dump files).
pg18() {
  local tool="$1"; shift
  local major=0 v=""
  # No failing pipeline inside $(…): with errtrace, macOS bash 3.2 runs the caller's ERR trap there too.
  if command -v "$tool" >/dev/null 2>&1; then v="$("$tool" --version 2>/dev/null || true)"; fi
  if [[ "$v" =~ ([0-9]+)\. ]]; then major="${BASH_REMATCH[1]}"; fi
  if [ "$major" -ge 18 ]; then "$tool" "$@"; return; fi
  { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; } \
    || die "$tool 18 not found locally (have ${major/#0/none}) and Docker is not running: start Docker Desktop"
  # A server on this Mac (a local stand-in) is host.docker.internal from inside the container.
  local host="$PGHOST"
  case "$host" in localhost|127.0.0.1|::1) host=host.docker.internal ;; esac
  PGHOST="$host" docker run --rm -i -v "$PWD:/w" -w /w -e PGHOST -e PGPORT -e PGDATABASE -e PGUSER -e PGPASSWORD \
    -e PGSSLMODE -e PGCHANNELBINDING postgres:18 "$tool" "$@"
}
