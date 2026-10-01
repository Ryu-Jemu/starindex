#!/bin/bash
# Runs INSIDE the deploy/test image (scripts/deploy-check.sh): the real deploy/ scripts on Amazon Linux 2023, with only
# systemctl (no systemd in a container) and aws (no AWS) replaced by local stand-ins. /work = deploy/, scripts/, app.jar.
set -uo pipefail
R=/work; pass=0; fail=0
ok()  { echo "PASS $*"; pass=$((pass+1)); }
bad() { echo "FAIL $*"; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

mkdir -p /fake/ssm/starindex/db /fake/ssm/starindex/data-go-kr /fake/s3/starindex-test
openssl rand -base64 32 | tr -d '\n' > /fake/ssm/starindex/db/password
chmod -R a+rwX /fake

cat > /usr/local/bin/systemctl <<'SH'
#!/bin/bash
echo "systemctl $*" >> /tmp/systemctl.log 2>/dev/null
case "$*" in
  "show -p Environment postgresql.service") echo "Environment=PGDATA=/var/lib/pgsql/data" ;;
  "show -p NeedDaemonReload postgresql.service") echo "NeedDaemonReload=no" ;;
  show*) echo "" ;;
  "enable --now postgresql"|"restart postgresql")
    install -d -o postgres -g postgres -m 755 /run/postgresql   # systemd-tmpfiles does this on a real host
    pgc() { /usr/sbin/runuser -u postgres -- /usr/bin/pg_ctl -D /var/lib/pgsql/data -l /tmp/pg.log -w -t 60 "$@" >> /tmp/pgctl.out 2>&1; }
    if pgc status; then pgc restart; else pgc start; fi ;;
  *) : ;;
esac
SH
cat > /usr/local/bin/aws <<'SH'
#!/bin/bash
# aws stand-in: ssm get-parameter from /fake/ssm, s3 cp/ls on /fake/s3
args=("$@"); name=""; i=0
for a in "$@"; do [ "$a" = --name ] && name="${args[$((i+1))]}"; i=$((i+1)); done
pos=(); skip=0
for a in "$@"; do
  if [ $skip = 1 ]; then skip=0; continue; fi
  case "$a" in --region|--name|--query|--output) skip=1 ;; --*) ;; *) pos+=("$a") ;; esac
done
case "${pos[0]} ${pos[1]}" in
  "ssm get-parameter") [ -f "/fake/ssm$name" ] || { echo "An error occurred (ParameterNotFound)" >&2; exit 254; }; cat "/fake/ssm$name"; echo ;;
  "s3 cp") src="${pos[2]}"; dst="${pos[3]}"
           src="${src/s3:\/\//\/fake\/s3\/}"; dst="${dst/s3:\/\//\/fake\/s3\/}"
           mkdir -p "$(dirname "$dst")" && cp "$src" "$dst" ;;
  "s3 ls") d="${pos[2]/s3:\/\//\/fake\/s3\/}"; for f in "$d"*; do [ -f "$f" ] && echo "2026-10-01 00:00:00 $(stat -c %s "$f") $(basename "$f")"; done ;;
  *) echo "aws stand-in: unsupported $*" >&2; exit 2 ;;
esac
SH
chmod 755 /usr/local/bin/systemctl /usr/local/bin/aws
touch /tmp/systemctl.log && chmod 666 /tmp/systemctl.log

mkdir -p /etc/starindex
sed -e 's/^S3_BUCKET=$/S3_BUCKET=starindex-test/' -e 's/^ETL_SCHEDULE_ENABLED=true/ETL_SCHEDULE_ENABLED=false/' \
    -e 's#/var/log/starindex/gc.log#/tmp/gc-%p.log#' $R/deploy/app/app.env.example > /etc/starindex/app.env

echo "== install.sh (twice: idempotent)"
check "install.sh first run" bash $R/deploy/postgres/install.sh > /tmp/install1.log 2>&1 || { tail -30 /tmp/install1.log; }
check "install.sh second run" bash $R/deploy/postgres/install.sh > /tmp/install2.log 2>&1 || { tail -30 /tmp/install2.log; }
tail -8 /tmp/install2.log
check "locale C, utf8" test "$(runuser -u postgres -- psql -tAc "SELECT datcollate || '/' || pg_encoding_to_char(encoding) FROM pg_database WHERE datname='starindex'")" = "C/UTF8"
check "listen localhost only" test "$(runuser -u postgres -- psql -tAc 'SHOW listen_addresses')" = localhost
check "shared_buffers 128MB" test "$(runuser -u postgres -- psql -tAc 'SHOW shared_buffers')" = 128MB
check "starindex is not superuser" test "$(runuser -u postgres -- psql -tAc "SELECT rolsuper FROM pg_roles WHERE rolname='starindex'")" = f
check "password stored as SCRAM" test "$(runuser -u postgres -- psql -tAc "SELECT left(rolpassword, 13) FROM pg_authid WHERE rolname='starindex'")" = 'SCRAM-SHA-256'
check "password never in argv/history" bash -c '! grep -rqF "$(cat /fake/ssm/starindex/db/password)" /tmp/install1.log /tmp/systemctl.log /root/.bash_history 2>/dev/null'
check "scripts installed" test -x /opt/starindex/postgres/backup.sh -a -x /opt/starindex/start.sh -a -f /etc/systemd/system/starindex-pgdump.timer
check "backup timer enabled" grep -q "enable --now starindex-pgdump.timer" /tmp/systemctl.log
check "peer auth for other local users refused" bash -c '! runuser -u starindex -- psql -h /var/run/postgresql -d postgres -tAc "select 1" >/dev/null 2>&1'

echo "== app: valkey, data.go.kr stub, first start through start.sh (Flyway as the owner role over scram)"
valkey-server --daemonize yes --bind 127.0.0.1 --port 6379 --maxmemory 128mb --save "" >/dev/null
python3 $R/scripts/ec2sim_stub.py 18089 & sleep 1
cp /work/app.jar /opt/starindex/app.jar
appenv() { grep -E '^[A-Z_]+=' /etc/starindex/app.env | sed 's/^\([A-Z_]*\)=\(.*\)$/export \1="\2"/'; }
run_app() {  # run_app <extra env…> -- emulates systemd: EnvironmentFile, User=starindex, ExecStart=start.sh
  runuser -u starindex -- env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/var/lib/starindex bash -c "$(appenv); export $*; cd /opt/starindex && /opt/starindex/start.sh" 
}
run_app STARINDEX_DATAGOKR_BASEURL=http://127.0.0.1:18089 SPRING_MAIN_WEBAPPLICATIONTYPE=none \
  SPRING_BATCH_JOB_ENABLED=true SPRING_BATCH_JOB_NAME=forecastPipelineJob LOGGING_LEVEL_ROOT=WARN LOGGING_LEVEL_ETL=INFO > /tmp/app1.log 2>&1
check "start.sh pipeline (no key in SSM → guided stop, exit≠0 expected)" grep -q "serviceKeyRequired: FAILED\|활용신청\|인증키" /tmp/app1.log
check "start.sh warned about the missing key" grep -q "service-key not readable" /tmp/app1.log
check "flyway V1..V6 applied as starindex" test "$(runuser -u postgres -- psql -d starindex -tAc 'SELECT max(version::int) FROM flyway_schema_history WHERE version IS NOT NULL')" = 6
printf 'ec2sim-not-a-real-key' > /fake/ssm/starindex/data-go-kr/service-key
run_app STARINDEX_DATAGOKR_BASEURL=http://127.0.0.1:18089 SPRING_MAIN_WEBAPPLICATIONTYPE=none \
  SPRING_BATCH_JOB_ENABLED=true SPRING_BATCH_JOB_NAME=astroEventsJob LOGGING_LEVEL_ROOT=WARN > /tmp/app2a.log 2>&1
app2a_rc=$?
check "start.sh with the SSM key → astroEventsJob exit 0 (env base-url binding, key from SSM)" test "$(tail -c 0 /tmp/app2a.log; echo $app2a_rc)" = 0
today="$(TZ=Asia/Seoul date +%Y%m%d)"; today_iso="$(TZ=Asia/Seoul date +%F)"
java_job() {  # java_job <db> <packdir> <args…>: the app as starindex with app.env, like start.sh but with job arguments
  local db="$1" packs="$2"; shift 2
  runuser -u starindex -- env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/var/lib/starindex bash -c "$(appenv); \
    export DB_URL=jdbc:postgresql://127.0.0.1:5432/$db PACK_LOCAL_DIR=$packs DATA_GO_KR_SERVICE_KEY=ec2sim-not-a-real-key; \
    export DB_PASSWORD=\$(aws ssm get-parameter --with-decryption --name /starindex/db/password --query Parameter.Value --output text); \
    cd /opt/starindex && exec java \$JAVA_OPTS -jar app.jar --spring.main.web-application-type=none --spring.batch.job.enabled=true \
    --starindex.data-go-kr.base-url=http://127.0.0.1:18089 --logging.level.root=WARN --logging.level.ETL=INFO run.at=\$(date +%s%N) $*"
}
java_job starindex /var/lib/starindex/packs --spring.batch.job.name=forecastPipelineJob base=${today}1700 nightDate=$today_iso > /tmp/app2.log 2>&1
check "pipeline with key → COMPLETED" grep -q "forecastPipelineJob → COMPLETED" /tmp/app2.log
grep -A3 "^\[ETL\]" /tmp/app2.log | cut -c1-200
version="$(python3 -c 'import json;print(json.load(open("/var/lib/starindex/packs/packs/manifest/latest.json"))["packs"]["index"]["version"])')"
night="$(python3 -c 'import json;print(json.load(open("/var/lib/starindex/packs/packs/manifest/latest.json"))["packs"]["index"]["nightDate"])')"
echo "live pack $version (night $night)"

echo "== backup.sh as starindex (timer user)"
check "backup.sh" runuser -u starindex -- env PATH=/usr/local/bin:/usr/bin:/bin /opt/starindex/postgres/backup.sh
ls -l /fake/s3/starindex-test/backup/db/

echo "== pin.sh"
check "pin.sh pins" bash -c "runuser -u starindex -- env PATH=/usr/local/bin:/usr/bin:/bin /opt/starindex/postgres/pin.sh $version | grep -q pinned"
check "pinned in DB" test "$(runuser -u postgres -- psql -d starindex -tAc "SELECT pinned FROM data_pack WHERE version='$version'")" = t
check "pin.sh unknown version fails" bash -c '! runuser -u starindex -- env PATH=/usr/local/bin:/usr/bin:/bin /opt/starindex/postgres/pin.sh no-such-version 2>/dev/null'
check "pin.sh --unpin" bash -c "runuser -u starindex -- env PATH=/usr/local/bin:/usr/bin:/bin /opt/starindex/postgres/pin.sh $version --unpin | grep -q unpinned"

echo "== restore.sh latest → starindex_restoretest (rehearsal)"
check "restore.sh rehearsal" bash /opt/starindex/postgres/restore.sh latest starindex_restoretest > /tmp/restore1.log 2>&1
cat /tmp/restore1.log | tail -6
check "rehearsal did not stop the app" bash -c '! grep -q "stop starindex" /tmp/systemctl.log'
check "restored tables owned by starindex" test "$(runuser -u postgres -- psql -d starindex_restoretest -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tableowner <> 'starindex'")" = 0
src_exec="$(runuser -u postgres -- psql -d starindex -tAc 'SELECT count(*) FROM batch_job_execution')"
check "batch executions equal the dump" grep -q "batch executions $src_exec" /tmp/restore1.log
check "manifest version exists in restored data_pack" test "$(runuser -u postgres -- psql -d starindex_restoretest -tAc "SELECT count(*) FROM data_pack WHERE version='$version'")" = 1

echo "== publish the same night from the restored DB → same version (DB-PLAN 5.6)"
java_job starindex_restoretest /var/lib/starindex/packs-restore --spring.batch.job.name=starIndexPublishJob nightDate=$night > /tmp/app3.log 2>&1
grep -A2 "^\[ETL\]" /tmp/app3.log | cut -c1-200
check "same pack version after restore" grep -q "팩 $version " /tmp/app3.log

echo "== restore.sh into the live DB stops and starts the app"
check "restore.sh live" bash /opt/starindex/postgres/restore.sh latest > /tmp/restore2.log 2>&1 || cat /tmp/restore2.log
check "app stopped and started" bash -c 'grep -q "stop starindex" /tmp/systemctl.log && grep -q "start starindex" /tmp/systemctl.log'
check "restore.sh refuses a bad name" bash -c '! bash /opt/starindex/postgres/restore.sh latest "x;drop" 2>/dev/null'

echo "== RDS-like target: a fresh cluster where a NON-superuser master (CREATEROLE CREATEDB) runs create-db.sql (DB-PLAN 5.2, 5.7)"
mkdir -p /tmp/rds && chown postgres /tmp/rds
runuser -u postgres -- initdb -D /tmp/rds/data --locale=C -E UTF8 --auth-local=trust --auth-host=scram-sha-256 >/dev/null
runuser -u postgres -- pg_ctl -D /tmp/rds/data -o "-p 5433 -c listen_addresses=127.0.0.1 -k /tmp/rds" -l /tmp/rds/log -w start >/dev/null
runuser -u postgres -- psql -h /tmp/rds -p 5433 -qc "CREATE ROLE rdsmaster LOGIN CREATEROLE CREATEDB PASSWORD 'm'"
M="env PGPASSWORD=m psql -h 127.0.0.1 -p 5433 -U rdsmaster -d postgres -v ON_ERROR_STOP=1 -q"
check "create-db.sql as non-superuser master" bash -c "$M -v dbname=starindex -f /opt/starindex/postgres/create-db.sql > /tmp/rds1.log 2>&1" 
check "create-db.sql idempotent (master)" $M -v dbname=starindex -f /opt/starindex/postgres/create-db.sql
check "rds db owned by starindex" test "$(runuser -u postgres -- psql -h /tmp/rds -p 5433 -tAc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='starindex'")" = starindex
check "rds master is not superuser" test "$(runuser -u postgres -- psql -h /tmp/rds -p 5433 -tAc "SELECT rolsuper FROM pg_roles WHERE rolname='rdsmaster'")" = f
printf "ALTER ROLE starindex PASSWORD 's';\n" | $M
dump="$(ls /fake/s3/starindex-test/backup/db/*.dump | tail -1)"
check "cutover restore into RDS-like as owner" env PGPASSWORD=s pg_restore --no-owner --no-privileges --exit-on-error -h 127.0.0.1 -p 5433 -U starindex -d starindex "$dump"
check "rds region 17 rows" test "$(env PGPASSWORD=s psql -h 127.0.0.1 -p 5433 -U starindex -d starindex -tAc 'SELECT count(*) FROM region')" = 17

if [ "$fail" != 0 ]; then
  for f in /tmp/install1.log /tmp/install2.log /tmp/app1.log /tmp/app2a.log /tmp/app2.log /tmp/restore1.log /tmp/restore2.log /tmp/app3.log /tmp/rds1.log; do
    [ -f "$f" ] && { echo "--- $f"; grep -v '^\s*at ' "$f" | tail -15; }
  done
fi
echo "RESULT pass=$pass fail=$fail"
[ "$fail" = 0 ]
