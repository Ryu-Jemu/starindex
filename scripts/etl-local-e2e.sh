#!/usr/bin/env bash
# The free production path end to end on the Mac (ADR-017), without keys or accounts:
#   fake data.go.kr (scripts/fake_datagokr.py) → the boot jar in batch mode, launched like .github/workflows/etl.yml
#   → PostgreSQL 18 + Valkey (compose) → S3Mock bucket starindex-packs (stand-in for the Neon public bucket)
#   → scripts/check-public-pack.py over anonymous HTTP, as the app reads it. (The fake KASI times are fixed, so the
#   KASI/Astronomy Engine cross-check differs by minutes here; its warning is silenced.)
#   scripts/etl-local-e2e.sh
# Against a real S3-compatible bucket instead of S3Mock (e.g. a throwaway Neon public bucket, never the live one):
#   STORAGE_ENDPOINT=https://br-….storage.c-N.<region>.aws.neon.tech STORAGE_BUCKET=starindex-check \
#   STORAGE_KEY_ID=… STORAGE_SECRET=… scripts/etl-local-e2e.sh
# Afterwards the simulator can read the same bucket: build with STARINDEX_PACK_BASE_URL=<endpoint>/<bucket>
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
docker info >/dev/null 2>&1 || { echo "Docker is not running (open -a Docker)." >&2; exit 3; }
cd "$here/backend"
endpoint="${STORAGE_ENDPOINT:-http://127.0.0.1:19090}"
bucket="${STORAGE_BUCKET:-starindex-packs}"
[ "$bucket" = starindex-packs ] && [ -n "${STORAGE_ENDPOINT:-}" ] && { echo "refusing to write fake data to the live bucket" >&2; exit 2; }
docker compose -f docker-compose.yml --profile storage up -d --wait postgres valkey >/dev/null
if [ -z "${STORAGE_ENDPOINT:-}" ]; then
  docker compose -f docker-compose.yml --profile storage up -d storage >/dev/null
  for _ in $(seq 1 30); do curl -fs -o /dev/null http://127.0.0.1:19090/ && break; sleep 1; done
fi

python3 "$here/scripts/fake_datagokr.py" 18089 >/dev/null 2>&1 &
stub=$!
trap 'kill $stub 2>/dev/null || true' EXIT
sleep 1

./gradlew -q --console=plain bootJar
jar=""
for f in build/libs/*.jar; do [[ "$f" == *-plain.jar ]] || jar="$f"; done

run() {  # the workflow's java line, with local stand-ins for Neon and data.go.kr
  DB_URL=jdbc:postgresql://127.0.0.1:15432/starindex DB_USERNAME=starindex DB_PASSWORD=starindex-local \
  REDIS_PORT=16379 DATA_GO_KR_SERVICE_KEY=fake-local-key \
  PACK_BUCKET="$bucket" AWS_ENDPOINT_URL_S3="$endpoint" AWS_REGION=ap-southeast-1 \
  AWS_ACCESS_KEY_ID="${STORAGE_KEY_ID:-local}" AWS_SECRET_ACCESS_KEY="${STORAGE_SECRET:-local}" \
  java -Xmx512m -XX:+UseSerialGC -Duser.timezone=Asia/Seoul -jar "$jar" \
    --spring.main.web-application-type=none --spring.main.banner-mode=off \
    --spring.batch.job.enabled=true --spring.batch.job.name="$1" \
    --starindex.data-go-kr.base-url="${DATA_GO_KR_BASE:-http://127.0.0.1:18089}" \
    --logging.level.root=WARN --logging.level.ETL=INFO --logging.level.dev.starindex.etl.AstroService=ERROR \
    --logging.level.org.springframework.batch.core.step.AbstractStep=OFF "run.at=$(date +%s%3N)" "${@:2}"
}
run forecastPipelineJob
run astroDailyJob
python3 "$here/scripts/check-public-pack.py" "$endpoint/$bucket" --max-age-min 360
# A runner data.go.kr refuses (here: a closed port, every call a connection error) must exit 75, the code the workflow
# retries on a fresh runner; retentionJob (Neon only) is what its last attempt still runs.
rc=0; DATA_GO_KR_BASE=http://127.0.0.1:9 run forecastPipelineJob >/dev/null 2>&1 || rc=$?
[ "$rc" = 75 ] || { echo "data.go.kr unreachable: expected exit 75, got $rc" >&2; exit 1; }
run retentionJob
echo "OK: ETL → bucket → anonymous read, unreachable data.go.kr → exit 75. Simulator: STARINDEX_PACK_BASE_URL=$endpoint/$bucket"
