#!/usr/bin/env bash
# Run one ETL job locally against docker-compose PostgreSQL 18 + Valkey.
#
#   scripts/etl.sh check                          # 1 call per API: which data.go.kr APIs accept the key
#   scripts/etl.sh pipeline                       # latest 단기예보 issue → index → pack + manifest
#   scripts/etl.sh forecast base=202610121700     # one issue only (yyyyMMddHHmm)
#   scripts/etl.sh publish nightDate=2026-10-12   # recompute index + pack (stored forecasts last 2 days: not older nights)
#   scripts/etl.sh astro [from=2026-10-12]        # retention (+ KASI rise/set and cross-check with a key)
#   scripts/etl.sh events [month=2026-10]         # KASI 천문현상 (+ 특일·음양력 when approved)
#   scripts/etl.sh pin 20261012-1700-ab12cd34     # keep this pack version forever (demo, rollback); unpin to release
#
# The key goes in backend/.env as DATA_GO_KR_SERVICE_KEY=<data.go.kr 일반 인증키 (Decoding)>; nothing else to set.
# Packs are written to backend/build/packs (PACK_LOCAL_DIR). Exit code: 0 = COMPLETED, non-zero = FAILED.
set -euo pipefail

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage

here="$(cd "$(dirname "$0")/.." && pwd)"

# pin / unpin: retention never deletes a pinned pack (DB-PLAN 4.3). Local compose DB; on EC2 use deploy/postgres/pin.sh.
if [ "$1" = pin ] || [ "$1" = unpin ]; then
  [ $# -eq 2 ] || { echo "usage: scripts/etl.sh $1 <pack version>" >&2; exit 2; }
  value=false; [ "$1" = pin ] && value=true
  cd "$here/backend"
  docker compose -f docker-compose.yml up -d --wait postgres >/dev/null 2>&1
  out="$(printf "UPDATE data_pack SET pinned = %s WHERE version = :'version';\n" "$value" |
    docker compose -f docker-compose.yml exec -T postgres psql -U starindex -d starindex -tA -v ON_ERROR_STOP=1 -v version="$2" -f - 2>&1)"
  case "$out" in
    *"UPDATE 0"*) echo "no pack version $2 in data_pack" >&2; exit 1 ;;
    *"UPDATE "*)  echo "$1: $2" ;;
    *) echo "$out" >&2; exit 1 ;;
  esac
  exit 0
fi

case "$1" in
  check)    job=apiKeyCheckJob ;;
  pipeline) job=forecastPipelineJob ;;
  forecast) job=forecastIngestJob ;;
  publish)  job=starIndexPublishJob ;;
  astro)    job=astroDailyJob ;;
  events)   job=astroEventsJob ;;
  *Job)     job="$1" ;;
  -h|--help) usage ;;
  *) echo "unknown job: $1" >&2; usage ;;
esac
shift

cd "$here/backend"

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Start Docker Desktop first (open -a Docker)." >&2
  exit 3
fi
docker compose -f docker-compose.yml up -d --wait postgres valkey >/dev/null

# Every launch is a new JobInstance: Spring Batch 6 ignores caller parameters when a job has an incrementer,
# so the jobs have none and we pass a unique run.at here.
params="run.at=$(date +%s)"
for kv in "$@"; do
  case "$kv" in
    *=*) params="$params $kv" ;;
    *) echo "job parameters must be key=value: $kv" >&2; exit 2 ;;
  esac
done

# Build (incremental) and run the boot jar directly: clean output and the job's exit code (0 = COMPLETED).
# The [ETL] summary block replaces Spring Batch's step stack trace here (the server keeps it).
./gradlew -q --console=plain bootJar
jar="$(ls -t build/libs/*.jar | grep -v -- '-plain.jar' | head -1)"
# shellcheck disable=SC2086
exec java -jar "$jar" --spring.main.web-application-type=none --spring.main.banner-mode=off \
  --spring.batch.job.enabled=true --spring.batch.job.name="$job" \
  --logging.level.root=WARN --logging.level.ETL=INFO --logging.level.io.netty.resolver.dns=ERROR \
  --logging.level.org.springframework.batch.core.step.AbstractStep=OFF $params
