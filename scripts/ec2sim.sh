#!/usr/bin/env bash
# EC2 memory rehearsal, DB-PLAN 6.2 and 11 (ADR-015: the database is Neon, so the EC2 runs the JVM and Valkey only).
# Needs Docker; no data.go.kr key (scripts/ec2sim_stub.py answers). The local postgres stands in for Neon.
#
#   scripts/ec2sim.sh [idle-seconds]      # default 600 (10 min server baseline)
#
# 1. valkey recreated with its EC2 limit (docker-compose.ec2sim.yml); a throwaway DB starindex_ec2sim on the local
#    postgres (the dev database is not touched).
# 2. The app jar in a linux/arm64 JVM container (--cpus=2 --memory=1g) with the JAVA_OPTS of deploy/app/app.env.example
#    plus Native Memory Tracking, configured as in production: web server + scheduler, and one forecastPipelineJob run
#    inside that JVM at start. Kept for the idle period, checked still running, then stopped (NMT printed on exit).
# 3. Then CLI JVMs one at a time (EC2 runs one JVM; these exercise every job): pipeline ×3, publish, astro, events;
#    then pg_dump.
# 4. Report: peak memory of the EC2 processes (JVM, Valkey) against t4g.small and, for reference, t4g.micro; exit codes;
#    Metaspace; max connections; and whether the idle server drained its pool to 0 connections (Neon can then suspend).
#    Missing measurements count as failures.
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
    c="$(docker exec starindex-postgres psql -U starindex -d starindex -tAc \
      "SELECT count(*) FROM pg_stat_activity WHERE usename = 'starindex' AND datname = '$db'" 2>/dev/null)" \
      && echo "$(date +%s) $c" >> "$out/conn.log"
    sleep 2
  done
) & sampler_pid=$!

jvm() {  # jvm <container name> [docker -e options… --] <java args…>
  local name="$1"; shift
  local extra=()
  if [[ " $* " == *" -- "* ]]; then
    while [ "$1" != -- ]; do extra+=("$1"); shift; done
    shift
  fi
  # shellcheck disable=SC2086
  docker run -d --name "$name" --platform linux/arm64 --cpus=2 --memory=1g --memory-swap=1g ${extra[@]+"${extra[@]}"} \
    --network "$network" --add-host=host.docker.internal:host-gateway \
    -e MALLOC_ARENA_MAX="$malloc" -e TZ=UTC \
    -e DB_URL="jdbc:postgresql://$net_alias_db:5432/$db" -e DB_USERNAME=starindex -e DB_PASSWORD=starindex-local \
    -e REDIS_HOST=valkey -e REDIS_PORT=6379 -e PACK_LOCAL_DIR=/tmp/packs \
    -e DATA_GO_KR_SERVICE_KEY=ec2sim-not-a-real-key \
    -v "$here/backend/$jar:/app/app.jar:ro" "$image" \
    java $java_opts $nmt -jar /app/app.jar --starindex.data-go-kr.base-url="http://host.docker.internal:$port" "$@" >/dev/null
}

oom() { docker inspect "$1" -f '{{.State.OOMKilled}}'; }
results=()

kst_day="$(TZ=Asia/Seoul date +%Y%m%d)"; kst_iso="$(TZ=Asia/Seoul date +%F)"; kst_month="$(TZ=Asia/Seoul date +%Y-%m)"
echo "== server (web + scheduler + one pipeline in-process), idle ${idle}s"
server_t0="$(date +%s)"
jvm starindex-ec2sim-app -e ETL_SCHEDULE_ENABLED=true -- --spring.batch.job.enabled=true \
  --spring.batch.job.name=forecastPipelineJob "run.at=$(date +%s%N)" "base=${kst_day}1700" "nightDate=$kst_iso"
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
server_t1="$(date +%s)"
running="$(docker inspect starindex-ec2sim-app -f '{{.State.Running}}')"
docker stop -t 60 starindex-ec2sim-app >/dev/null
docker logs starindex-ec2sim-app > "$out/server.log" 2>&1
in_process="$(grep -c 'forecastPipelineJob → COMPLETED' "$out/server.log" || true)"
results+=("server running-after-idle=$running in-process-pipeline=$([ "$in_process" -ge 1 ] && echo COMPLETED || echo MISSING) OOMKilled=$(oom starindex-ec2sim-app)")
docker rm starindex-ec2sim-app >/dev/null

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
python3 - "$out" "$server_t0" "$server_t1" "${results[@]}" <<'PY' | tee "$out/report.txt"
import collections, re, sys
out, t0, t1, results = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:]
unit = {"B": 1 / 2**20, "KiB": 1 / 1024, "MiB": 1, "GiB": 1024}
peak = collections.defaultdict(float)
for line in open(f"{out}/mem.log"):
    _, name, usage = line.split()
    m = re.match(r"([\d.]+)(B|KiB|MiB|GiB)", usage)
    if m:
        peak[name] = max(peak[name], float(m.group(1)) * unit[m.group(2)])
samples = [tuple(map(int, l.split())) for l in open(f"{out}/conn.log") if len(l.split()) == 2 and l.split()[1].isdigit()]
conns = [c for _, c in samples]
# After the in-process pipeline (first ~2 min) the idle server must reach 0 connections: Neon then suspends 5 min later.
idle_window = [c for t, c in samples if t0 + 150 <= t <= t1]
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
limits = {"starindex-valkey": 150, "starindex-ec2sim-app": 900, "starindex-ec2sim-cli": 900}
print("EC2 memory rehearsal (DB-PLAN 6.2, ADR-015: database on Neon)")
ok = True
for name, lim in limits.items():
    v = peak.get(name)
    flag = "OK" if v is not None and v <= lim else "OVER" if v is not None else "NO DATA"
    ok &= flag == "OK"
    print(f"  peak {name:24s} {'n/a' if v is None else round(v):>5} MiB  (limit {lim})  {flag}")
pg = peak.get("starindex-postgres")
print(f"  peak starindex-postgres (Neon stand-in, not on the EC2) {'n/a' if pg is None else round(pg)} MiB")
jvm = max(peak.get("starindex-ec2sim-app", 0), peak.get("starindex-ec2sim-cli", 0))
total = peak.get("starindex-valkey", 0) + jvm + 270
print(f"  t4g.small: valkey + one JVM + OS/agents 270 = {round(total)} MiB (limit 1600)  {'OK' if total <= 1600 else 'OVER'}")
ok &= total <= 1600
print(f"  t4g.micro (reference, ~900 MiB usable [assumed], needs -Xmx384m): {round(total)} MiB  {'fits' if total <= 900 else 'does not fit'}")
conn_ok = bool(conns) and max(conns) <= 6
ok &= conn_ok
print(f"  max starindex connections {max(conns) if conns else 'n/a'} (limit 6)  {'OK' if conn_ok else 'FAIL'}")
drained = bool(idle_window) and min(idle_window) == 0
ok &= drained
print(f"  idle server drained its pool to 0 connections: {'yes' if drained else 'NO'} "
      f"({sum(1 for c in idle_window if c == 0)}/{len(idle_window)} idle samples at 0)")
for k, v in metas.items():
    print(f"  NMT {k:18s} " + ("n/a" if v is None else f"metaspace committed {v[0]:.0f} MiB, total committed {v[1]:.0f} MiB"))
for r in results:
    print("  " + r)
    ok &= ("OOMKilled=true" not in r and ("exit=" not in r or "exit=0" in r)
           and "running-after-idle=false" not in r and "MISSING" not in r)
print("RESULT", "PASS" if ok else "FAIL")
PY
