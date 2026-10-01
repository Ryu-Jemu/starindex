#!/usr/bin/env bash
# The admin page on the Mac against the PRODUCTION data (ADR-017): Neon PostgreSQL and, when configured, the public
# pack bucket. Loopback only: http://localhost:8080/admin. No scheduler (ETL runs in GitHub Actions).
#   scripts/admin-neon.sh
# Reads ops/neon/app.env (written by ops/neon/bootstrap.sh --save-local; DB_URL, DB_USERNAME, DB_PASSWORD, and
# optionally PACK_BUCKET, AWS_ENDPOINT_URL_S3, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY) and backend/.env for the
# admin login (ADMIN_PASSWORD_HASH). Kept apart from backend/.env so local development never writes to Neon.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
envf="$here/ops/neon/app.env"
[ -r "$envf" ] || { echo "no $envf: run ops/neon/bootstrap.sh --save-local first" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "Docker is not running (open -a Docker)." >&2; exit 3; }
(cd "$here/backend" && docker compose -f docker-compose.yml up -d --wait valkey >/dev/null)
# KEY=value lines exported verbatim (values hold & ? / + =; never sourced as shell).
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  key="${line%%=*}"
  case "$key" in DB_URL|DB_USERNAME|DB_PASSWORD|PACK_BUCKET|AWS_ENDPOINT_URL_S3|AWS_REGION|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY) export "$key=${line#*=}" ;; esac
done < "$envf"
export ETL_SCHEDULE_ENABLED=false
echo "admin page: http://localhost:8080/admin  (database $(printf '%s' "$DB_URL" | sed -E 's#^jdbc:postgresql://([^/?]+)/([^?]+).*#\1/\2#'))"
cd "$here/backend" && exec ./gradlew -q --console=plain bootRun
