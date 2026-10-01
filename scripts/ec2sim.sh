#!/usr/bin/env bash
# EC2 (t4g.small) memory rehearsal, DB-PLAN 6.2. Needs Docker; no data.go.kr key (scripts/ec2sim_stub.py answers).
#
#   scripts/ec2sim.sh [idle-seconds]      # default 600 (10 min server baseline)
#
# 1. postgres/valkey recreated with the EC2 limits (docker-compose.ec2sim.yml); a throwaway DB starindex_ec2sim
#    (the dev database is not touched).
# 2. The app jar in a linux/arm64 JVM container (--cpus=2 --memory=1g) with the JAVA_OPTS of deploy/app/app.env.example
#    plus Native Memory Tracking: server mode for the idle period, then stopped (NMT summary printed on exit).
# 3. One JVM at a time, as on EC2: CLI pipeline ×3, publish, astro, events; then pg_dump.
# 4. Report: peak memory per container, OOMKilled, Metaspace committed, max starindex connections.
#    → backend/build/ec2sim/report.txt. Containers are recreated without limits at the end.
set -euo pipefail

idle="${1:-600}"
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/backend/build/ec2sim"
port=18089
net_alias_db=postgres
db=starindex_ec2sim
image=eclipse-temurin:21-jre
mkdir -p "$out"
: > "$out/mem.log"; : > "$out/conn.log"

cd "$here/backend"
docker info >/dev/null 2>&1 || { echo "Docker is not running." >&2; exit 3; }

# The memory values of the override must be the ones EC2 gets from tune.sql.
python3 - "$here/deploy/postgres/tune.sql" docker-compose.ec2sim.yml <<'PY'
import re, sys
tune = dict(re.findall(r"ALTER SYSTEM SET (\w+) = '?([^';]+)'?;", open(sys.argv[1]).read()))
yml = dict(re.findall(r'"-c", "(\w+)=([^"]+)"', open(sys.argv[2]).read()))
bad = {k: (tune[k], yml.get(k)) for k in ("max_connections", "shared_buffers", "effective_cache_size", "work_mem",
                                           "maintenance_work_mem", "huge_pages", "max_wal_size", "min_wal_size")
       if tune[k] != yml.get(k)}
if bad:
    sys.exit(f"docker-compose.ec2sim.yml differs from tune.sql: {bad}")
PY

java_opts="$(sed -n 's/^JAVA_OPTS=//p' "$here/deploy/app/app.env.example" | sed 's#/var/log/starindex/gc.log#/tmp/gc.log#')"
malloc="$(sed -n 's/^MALLOC_ARENA_MAX=//p' "$here/deploy/app/app.env.example")"
nmt="-XX:NativeMemoryTracking=summary -XX:+UnlockDiagnosticVMOptions -XX:+PrintNMTStatistics"

compose_sim=(docker compose -f docker-compose.yml -f docker-compose.ec2sim.yml)
compose_dev=(docker compose -f docker-compose.yml)

stub_pid=""; sampler_pid=""
cleanup() {
  set +e
  [ -n "$sampler_pid" ] && kill "$sampler_pid" 2>/dev/null
  [ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null
  docker rm -f starindex-ec2sim-app starindex-ec2sim-cli >/dev/null 2>&1
  docker exec starindex-postgres psql -U starindex -d starindex -qc "DROP DATABASE IF EXISTS $db" >/dev/null 2>&1
  echo "restoring dev containers without limits…"
  "${compose_dev[@]}" up -d --wait postgres valkey >/dev/null 2>&1
}
trap cleanup EXIT

echo "== build + containers with EC2 limits"
./gradlew -q --console=plain bootJar
jar=""   # newest boot jar (not the -plain one)
for f in build/libs/*.jar; do
  [[ "$f" == *-plain.jar ]] && continue
  { [ -z "$jar" ] || [ "$f" -nt "$jar" ]; } && jar="$f"
done
[ -n "$jar" ] || { echo "no boot jar in backend/build/libs" >&2; exit 1; }
docker pull -q --platform linux/arm64 "$image" >/dev/null
"${compose_sim[@]}" up -d --wait postgres valkey >/dev/null 2>&1
docker exec starindex-postgres psql -U starindex -d starindex -qc "DROP DATABASE IF EXISTS $db" -c "CREATE DATABASE $db OWNER starindex"
network="$(docker inspect starindex-postgres -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')"

python3 "$here/scripts/ec2sim_stub.py" "$port" & stub_pid=$!

# Peak memory: docker stats every 2 s for starindex-* containers; connections of the starindex role.
(
  while :; do
    docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null | awk -v t="$(date +%s)" '$1 ~ /^starindex-/ {print t, $1, $2}' >> "$out/mem.log"
    docker exec starindex-postgres psql -U starindex -d starindex -tAc \
      "SELECT count(*) FROM pg_stat_activity WHERE usename = 'starindex' AND pid <> pg_backend_pid()" >> "$out/conn.log" 2>/dev/null
    sleep 2
  done
) & sampler_pid=$!

jvm() {  # jvm <container name> <java args…>
  local name="$1"; shift
  # shellcheck disable=SC2086
  docker run -d --name "$name" --platform linux/arm64 --cpus=2 --memory=1g --memory-swap=1g \
    --network "$network" --add-host=host.docker.internal:host-gateway \
    -e MALLOC_ARENA_MAX="$malloc" -e TZ=UTC \
    -e DB_URL="jdbc:postgresql://$net_alias_db:5432/$db" -e DB_USERNAME=starindex -e DB_PASSWORD=starindex-local \
    -e REDIS_HOST=valkey -e REDIS_PORT=6379 -e PACK_LOCAL_DIR=/tmp/packs -e ETL_SCHEDULE_ENABLED=false \
    -e DATA_GO_KR_SERVICE_KEY=ec2sim-not-a-real-key \
    -v "$here/backend/$jar:/app/app.jar:ro" "$image" \
    java $java_opts $nmt -jar /app/app.jar --starindex.data-go-kr.base-url="http://host.docker.internal:$port" "$@" >/dev/null
}

oom() { docker inspect "$1" -f '{{.State.OOMKilled}}'; }
results=()

echo "== server mode, idle ${idle}s"
jvm starindex-ec2sim-app
started=""
for _ in $(seq 1 60); do
  if docker logs starindex-ec2sim-app 2>&1 | grep -q "Started StarIndexApplication"; then started=1; break; fi
  [ "$(docker inspect starindex-ec2sim-app -f '{{.State.Running}}')" = true ] || break
  sleep 2
done
if [ -z "$started" ]; then
  docker logs starindex-ec2sim-app > "$out/server.log" 2>&1
  echo "server did not start; see $out/server.log" >&2
  exit 1
fi
sleep "$idle"
docker stop -t 60 starindex-ec2sim-app >/dev/null
docker logs starindex-ec2sim-app > "$out/server.log" 2>&1
results+=("server OOMKilled=$(oom starindex-ec2sim-app)")
docker rm starindex-ec2sim-app >/dev/null

kst_day="$(TZ=Asia/Seoul date +%Y%m%d)"; kst_iso="$(TZ=Asia/Seoul date +%F)"; kst_month="$(TZ=Asia/Seoul date +%Y-%m)"
cli() {  # cli <label> <job> <params…>
  local label="$1" job="$2"; shift 2
  jvm starindex-ec2sim-cli --spring.main.web-application-type=none --spring.main.banner-mode=off \
    --spring.batch.job.enabled=true --spring.batch.job.name="$job" \
    --logging.level.root=WARN --logging.level.ETL=INFO "run.at=$(date +%s%N)" "$@"
  local code; code="$(docker wait starindex-ec2sim-cli)"
  docker logs starindex-ec2sim-cli > "$out/cli-$label.log" 2>&1
  results+=("cli $label exit=$code OOMKilled=$(oom starindex-ec2sim-cli)")
  docker rm starindex-ec2sim-cli >/dev/null
  echo "   $label: exit $code"
}
echo "== CLI jobs (one JVM at a time)"
for i in 1 2 3; do cli "pipeline$i" forecastPipelineJob "base=${kst_day}1700" "nightDate=$kst_iso"; done
cli publish starIndexPublishJob "nightDate=$kst_iso"
cli astro astroDailyJob "from=$kst_iso"
cli events astroEventsJob "month=$kst_month"

echo "== pg_dump"
docker exec starindex-postgres pg_dump -Fc -U starindex "$db" | wc -c | awk '{printf "   dump %d bytes\n", $1}'
sleep 4
results+=("postgres OOMKilled=$(oom starindex-postgres)" "valkey OOMKilled=$(oom starindex-valkey)")

kill "$sampler_pid" 2>/dev/null; sampler_pid=""
python3 - "$out" "${results[@]}" <<'PY' | tee "$out/report.txt"
import collections, re, sys
out, results = sys.argv[1], sys.argv[2:]
unit = {"B": 1 / 2**20, "KiB": 1 / 1024, "MiB": 1, "GiB": 1024}
peak = collections.defaultdict(float)
for line in open(f"{out}/mem.log"):
    _, name, usage = line.split()
    m = re.match(r"([\d.]+)(B|KiB|MiB|GiB)", usage)
    if m:
        peak[name] = max(peak[name], float(m.group(1)) * unit[m.group(2)])
conns = [int(x) for x in open(f"{out}/conn.log").read().split() if x.isdigit()]
def nmt(log):
    """(metaspace committed, NMT total committed) in MiB from -XX:+PrintNMTStatistics (bytes), or None."""
    text = open(log, errors="replace").read()
    md = re.search(r"Metadata:\s*\)\s*\n\s*\(\s*reserved=\d+, committed=(\d+)\)", text)
    cs = re.search(r"Class space:\)\s*\n\s*\(\s*reserved=\d+, committed=(\d+)\)", text)
    total = re.search(r"Total: reserved=\d+, committed=(\d+)", text)
    if not md:
        return None
    return (int(md.group(1)) + (int(cs.group(1)) if cs else 0)) / 2**20, int(total.group(1)) / 2**20 if total else float("nan")
import glob
metas = {p.rsplit("/", 1)[1]: nmt(p) for p in sorted(glob.glob(f"{out}/*.log")) if p.endswith("server.log") or "/cli-" in p}
limits = {"starindex-postgres": 250, "starindex-valkey": 150, "starindex-ec2sim-app": 900, "starindex-ec2sim-cli": 900}
print("EC2 memory rehearsal (DB-PLAN 6.2)")
ok = True
for name, lim in limits.items():
    v = peak.get(name)
    flag = "OK" if v is not None and v <= lim else "OVER" if v is not None else "n/a"
    ok &= flag != "OVER"
    print(f"  peak {name:24s} {'n/a' if v is None else round(v):>5} MiB  (limit {lim})  {flag}")
jvm = max(peak.get("starindex-ec2sim-app", 0), peak.get("starindex-ec2sim-cli", 0))
total = peak.get("starindex-postgres", 0) + peak.get("starindex-valkey", 0) + jvm + 270
print(f"  total postgres + valkey + one JVM + OS/agents 270 = {round(total)} MiB (limit 1600)  {'OK' if total <= 1600 else 'OVER'}")
ok &= total <= 1600
print(f"  max starindex connections {max(conns) if conns else 'n/a'} (limit 6)  {'OK' if conns and max(conns) <= 6 else 'CHECK'}")
for k, v in metas.items():
    print(f"  NMT {k:18s} " + ("n/a" if v is None else f"metaspace committed {v[0]:.0f} MiB, total committed {v[1]:.0f} MiB"))
for r in results:
    print("  " + r)
    ok &= "OOMKilled=true" not in r and ("exit=" not in r or "exit=0" in r)
print("RESULT", "PASS" if ok else "FAIL")
PY
