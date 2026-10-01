#!/usr/bin/env bash
# The free production path end to end on the Mac (ADR-017), without keys or accounts:
#   fake data.go.kr (scripts/fake_datagokr.py) → the boot jar in batch mode, launched like .github/workflows/etl.yml
#   → PostgreSQL 18 + Valkey (compose) → S3Mock bucket starindex-packs (stand-in for the Neon public bucket)
#   → scripts/check-public-pack.py over anonymous HTTP, as the app reads it. (The fake KASI times are fixed, so the
#   KASI/Astronomy Engine cross-check differs by minutes here; its warning is silenced.)
#   scripts/etl-local-e2e.sh
# Afterwards the simulator can read the same bucket: build with STARINDEX_PACK_BASE_URL=http://127.0.0.1:19090/starindex-packs
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
docker info >/dev/null 2>&1 || { echo "Docker is not running (open -a Docker)." >&2; exit 3; }
cd "$here/backend"
docker compose -f docker-compose.yml --profile storage up -d --wait postgres valkey >/dev/null
docker compose -f docker-compose.yml --profile storage up -d storage >/dev/null
for _ in $(seq 1 30); do curl -fs -o /dev/null http://127.0.0.1:19090/ && break; sleep 1; done

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
  PACK_BUCKET=starindex-packs AWS_ENDPOINT_URL_S3=http://127.0.0.1:19090 AWS_REGION=ap-southeast-1 \
  AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local \
  java -Xmx512m -XX:+UseSerialGC -Duser.timezone=Asia/Seoul -jar "$jar" \
    --spring.main.web-application-type=none --spring.main.banner-mode=off \
    --spring.batch.job.enabled=true --spring.batch.job.name="$1" \
    --starindex.data-go-kr.base-url=http://127.0.0.1:18089 \
    --logging.level.root=WARN --logging.level.ETL=INFO --logging.level.dev.starindex.etl.AstroService=ERROR \
    --logging.level.org.springframework.batch.core.step.AbstractStep=OFF "run.at=$(date +%s%3N)" "${@:2}"
}
run forecastPipelineJob
run astroDailyJob
python3 "$here/scripts/check-public-pack.py" http://127.0.0.1:19090/starindex-packs --max-age-min 360
echo "OK: ETL → bucket → anonymous read. Simulator: STARINDEX_PACK_BASE_URL=http://127.0.0.1:19090/starindex-packs"
