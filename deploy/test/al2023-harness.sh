#!/bin/bash
# Runs INSIDE the deploy/test image (scripts/deploy-check.sh): the real deploy/ scripts on Amazon Linux 2023 against a
# Neon stand-in (ADR-015). Only systemctl (no systemd in a container) and aws (no AWS) are replaced by local stand-ins.
# The stand-in is a PostgreSQL 18 server reached as ep-standin.ap-southeast-1.aws.neon.tech that, like Neon, accepts
# TLS only (SCRAM, channel binding) and has no usable superuser: the admin neondb_owner is CREATEDB CREATEROLE only.
# /work = deploy/, scripts/, app.jar.
set -uo pipefail
R=/work; pass=0; fail=0
ok()  { echo "PASS $*"; pass=$((pass+1)); }
bad() { echo "FAIL $*"; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
HOST=ep-standin.ap-southeast-1.aws.neon.tech
ADMIN_PW="admin-$(openssl rand -hex 12)"

echo "== Neon stand-in: TLS-only PostgreSQL 18, non-superuser admin"
echo "127.0.0.1 $HOST" >> /etc/hosts
install -d -o postgres -g postgres -m 700 /srv/neon && install -d -o postgres -g postgres /run/postgresql
runuser -u postgres -- initdb -D /srv/neon/data --locale=C.UTF-8 -E UTF8 --auth-local=trust --auth-host=scram-sha-256 >/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$HOST" -keyout /srv/neon/data/server.key -out /srv/neon/data/server.crt 2>/dev/null
chown postgres:postgres /srv/neon/data/server.*; chmod 600 /srv/neon/data/server.key
cat > /srv/neon/data/pg_hba.conf <<'HBA'
local    all  postgres                 trust
hostssl  all  all       127.0.0.1/32   scram-sha-256
HBA
runuser -u postgres -- pg_ctl -D /srv/neon/data -l /tmp/neon.log -w \
  -o "-c listen_addresses=127.0.0.1 -c ssl=on -c password_encryption=scram-sha-256" start >/dev/null
runuser -u postgres -- psql -qc "CREATE ROLE neondb_owner LOGIN CREATEDB CREATEROLE PASSWORD '$ADMIN_PW'" -c "CREATE DATABASE neondb OWNER neondb_owner"
check "stand-in refuses plain TCP" bash -c "! PGPASSWORD='$ADMIN_PW' psql 'host=$HOST user=neondb_owner dbname=neondb sslmode=disable' -tAc 'select 1' 2>/dev/null"
check "stand-in admin is not superuser" test "$(runuser -u postgres -- psql -tAc "SELECT rolsuper FROM pg_roles WHERE rolname='neondb_owner'")" = f

echo "== stand-ins for systemctl, aws, psql/pg_restore (argv log)"
mkdir -p /fake/ssm/starindex/db /fake/ssm/starindex/data-go-kr /fake/s3/starindex-test
openssl rand -base64 32 | tr -d '\n' > /fake/ssm/starindex/db/password
chmod -R a+rwX /fake
cat > /usr/local/bin/systemctl <<'SH'
#!/bin/bash
echo "systemctl $*" >> /tmp/systemctl.log 2>/dev/null
case "$*" in
  "start starindex"|"restart starindex") touch /tmp/starindex.active ;;
  "stop starindex") rm -f /tmp/starindex.active ;;
  "is-active -q starindex") [ -f /tmp/starindex.active ]; exit $? ;;
  "enable --now valkey"|"restart valkey")
    pkill -x valkey-server 2>/dev/null; sleep 0.3
    install -d -o valkey -g valkey -m 755 /run/valkey   # RuntimeDirectory=valkey of the real unit
    runuser -u valkey -- valkey-server /etc/valkey/valkey.conf --daemonize yes --dir /var/lib/valkey >/dev/null ;;
  *) : ;;
esac
SH
cat > /usr/local/bin/aws <<'SH'
#!/bin/bash
# aws stand-in: ssm get-parameter from /fake/ssm, s3 cp/ls on /fake/s3
printf '%s\n' "$*" >> /tmp/argv.log 2>/dev/null
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
for t in psql pg_restore pg_dump; do
cat > /usr/local/bin/$t <<SH
#!/bin/bash
printf '%s\n' "\$*" >> /tmp/argv.log 2>/dev/null
if [ "$t" = pg_restore ] && [ -f /tmp/fail-restore ] && [[ " \$* " == *" -d "* ]]; then echo "pg_restore stand-in: forced failure" >&2; exit 1; fi
exec /usr/bin/$t "\$@"
SH
done
chmod 755 /usr/local/bin/{systemctl,aws,psql,pg_restore,pg_dump}
touch /tmp/systemctl.log /tmp/argv.log && chmod 666 /tmp/systemctl.log /tmp/argv.log

mkdir -p /etc/starindex
sed -e "s/ep-REPLACE-ME.ap-southeast-1.aws.neon.tech/$HOST/" -e 's/^S3_BUCKET=$/S3_BUCKET=starindex-test/' \
    -e 's/^ETL_SCHEDULE_ENABLED=true/ETL_SCHEDULE_ENABLED=false/' -e 's#/var/log/starindex/gc.log#/tmp/gc-%p.log#' \
    $R/deploy/app/app.env.example > /etc/starindex/app.env
grep '^DB_URL=' /etc/starindex/app.env

echo "== install.sh (twice; the second from a 0700 home)"
check "install.sh first run" bash $R/deploy/ec2/install.sh > /tmp/install1.log 2>&1 || tail -20 /tmp/install1.log
mkdir -p /root/checkout && cp -R $R/deploy /root/checkout/ && chmod 700 /root /root/checkout
check "install.sh second run from a 0700 home" bash /root/checkout/deploy/ec2/install.sh > /tmp/install2.log 2>&1 || tail -20 /tmp/install2.log
check "install.sh says bootstrap is next" grep -q "bootstrap-db.sh" /tmp/install1.log
check "app.env root:starindex 0640" test "$(stat -c %U:%G:%a /etc/starindex/app.env)" = root:starindex:640
check "no local PostgreSQL server set up by install.sh" bash -c '! grep -qE "postgresql18-server|initdb|postgresql-setup" '"$R"'/deploy/ec2/install.sh'
check "valkey: maxmemory 128mb" test "$(valkey-cli config get maxmemory | tail -1)" = 134217728
check "valkey: running" test "$(valkey-cli ping)" = PONG
check "valkey: no RDB snapshots" test "$(valkey-cli config get save | wc -l)" = 2 -a -z "$(valkey-cli config get save | tail -1)"
check "valkey: managed block once after two runs" test "$(grep -c '^# >>> starindex' /etc/valkey/valkey.conf)" = 1
check "valkey restarted only when its config changed (once in two runs)" test "$(grep -c '^systemctl restart valkey$' /tmp/systemctl.log)" = 1
check "unit limits restarts (a crash loop must not keep Neon awake)" bash -c 'grep -q "^StartLimitBurst=5" /etc/systemd/system/starindex.service && grep -q "^RestartSec=120" /etc/systemd/system/starindex.service'
check "scripts and units installed" test -x /opt/starindex/postgres/bootstrap-db.sh -a -x /opt/starindex/start.sh -a -f /etc/systemd/system/starindex-pgdump.timer
check "backup timer enabled" grep -q "enable --now starindex-pgdump.timer" /tmp/systemctl.log
check "units do not depend on a local postgresql" bash -c '! grep -q postgresql /etc/systemd/system/starindex.service /etc/systemd/system/starindex-pgdump.service'

echo "== bootstrap-db.sh (admin login, password from env, then idempotent)"
check "bootstrap without password and terminal explains" bash -c 'bash /opt/starindex/postgres/bootstrap-db.sh </dev/null 2>&1 | grep -q "ADMIN_PGPASSWORD"'
check "bootstrap-db.sh" bash -c "ADMIN_PGPASSWORD='$ADMIN_PW' setsid bash /opt/starindex/postgres/bootstrap-db.sh > /tmp/bootstrap1.log 2>&1" || cat /tmp/bootstrap1.log
cat /tmp/bootstrap1.log | grep "connected as"
check "bootstrap-db.sh again (idempotent)" bash -c "ADMIN_PGPASSWORD='$ADMIN_PW' setsid bash /opt/starindex/postgres/bootstrap-db.sh > /tmp/bootstrap2.log 2>&1"
check "bootstrap with the app stopped does not restart it" bash -c '! grep -q "restart starindex" /tmp/systemctl.log'
check "app role: client TLS 1.2+ with channel binding required" grep -qE "client TLS: TLSv1\.[23] \(sslmode=require, channel_binding=require\)" /tmp/bootstrap1.log
check "app role: not superuser, no CREATEDB" test "$(runuser -u postgres -- psql -tAc "SELECT rolsuper::text || rolcreatedb::text FROM pg_roles WHERE rolname='starindex'")" = falsefalse
check "database starindex owned by starindex, locale C" test "$(runuser -u postgres -- psql -tAc "SELECT pg_get_userbyid(datdba) || '/' || datcollate FROM pg_database WHERE datname='starindex'")" = starindex/C
check "argv log is recording" test -s /tmp/argv.log
check "no password in argv or logs" bash -c "! grep -rqF -e \"\$(cat /fake/ssm/starindex/db/password)\" -e '$ADMIN_PW' /tmp/argv.log /tmp/install1.log /tmp/install2.log /tmp/bootstrap1.log /tmp/systemctl.log"

echo "== app through start.sh: Flyway over TLS + channel binding as the owner role"
python3 $R/scripts/ec2sim_stub.py 18089 & sleep 1
cp /work/app.jar /opt/starindex/app.jar
appenv() { grep -E '^[A-Z_]+=' /etc/starindex/app.env | sed 's/^\([A-Z_]*\)=\(.*\)$/export \1="\2"/'; }
run_app() {  # emulates systemd: EnvironmentFile, User=starindex, ExecStart=start.sh
  runuser -u starindex -- env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/var/lib/starindex bash -c "$(appenv); export $*; cd /opt/starindex && /opt/starindex/start.sh"
}
run_app STARINDEX_DATAGOKR_BASEURL=http://127.0.0.1:18089 SPRING_MAIN_WEBAPPLICATIONTYPE=none \
  SPRING_BATCH_JOB_ENABLED=true SPRING_BATCH_JOB_NAME=forecastPipelineJob LOGGING_LEVEL_ROOT=WARN > /tmp/app1.log 2>&1
check "start.sh without key → guided stop" grep -q "serviceKeyRequired: FAILED" /tmp/app1.log
check "start.sh warned about the missing key" grep -q "service-key not readable" /tmp/app1.log
FLYWAY_SQL="SELECT max(version::int)::text || '/' || min(installed_by) FROM flyway_schema_history WHERE version IS NOT NULL"
check "flyway V1..V6 applied as starindex" test "$(runuser -u postgres -- psql -d starindex -tAc "$FLYWAY_SQL")" = 6/starindex
printf 'ec2sim-not-a-real-key' > /fake/ssm/starindex/data-go-kr/service-key
run_app STARINDEX_DATAGOKR_BASEURL=http://127.0.0.1:18089 SPRING_MAIN_WEBAPPLICATIONTYPE=none \
  SPRING_BATCH_JOB_ENABLED=true SPRING_BATCH_JOB_NAME=astroEventsJob LOGGING_LEVEL_ROOT=WARN > /tmp/app2a.log 2>&1
app2a_rc=$?
check "start.sh with the SSM key → astroEventsJob exit 0" test "$app2a_rc" = 0

echo "== the pool drains: a running server holds no DB connection ~90 s after its last query (Neon can suspend)"
run_app STARINDEX_DATAGOKR_BASEURL=http://127.0.0.1:18089 > /tmp/server.log 2>&1 &
for _ in $(seq 1 60); do grep -q "Started StarIndexApplication" /tmp/server.log && break; sleep 2; done
check "server started" grep -q "Started StarIndexApplication" /tmp/server.log
conns() { runuser -u postgres -- psql -tAc "SELECT count(*) FROM pg_stat_activity WHERE usename = 'starindex'"; }
echo "   connections right after start: $(conns)"
sleep 100
check "no starindex connection after 100 s idle" test "$(conns)" = 0
check "server still running" pgrep -f "app.jar" >/dev/null
pkill -f "app.jar"; sleep 3

today="$(TZ=Asia/Seoul date +%Y%m%d)"; today_iso="$(TZ=Asia/Seoul date +%F)"
java_job() {  # java_job <db> <packdir> <args…>: the app as starindex with app.env, like start.sh but with job arguments
  local db="$1" packs="$2"; shift 2
  runuser -u starindex -- env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/var/lib/starindex bash -c "$(appenv); \
    export DB_URL=\$(echo \"\$DB_URL\" | sed -E 's#(neon.tech/)[a-z0-9_]+#\\1$db#') PACK_LOCAL_DIR=$packs DATA_GO_KR_SERVICE_KEY=ec2sim-not-a-real-key; \
    export DB_PASSWORD=\$(aws ssm get-parameter --with-decryption --name /starindex/db/password --query Parameter.Value --output text); \
    cd /opt/starindex && exec java \$JAVA_OPTS -jar app.jar --spring.main.web-application-type=none --spring.batch.job.enabled=true \
    --starindex.data-go-kr.base-url=http://127.0.0.1:18089 --logging.level.root=WARN --logging.level.ETL=INFO run.at=\$(date +%s%N) $*"
}
java_job starindex /var/lib/starindex/packs --spring.batch.job.name=forecastPipelineJob base=${today}1700 nightDate=$today_iso > /tmp/app2.log 2>&1
check "pipeline with key → COMPLETED" grep -q "forecastPipelineJob → COMPLETED" /tmp/app2.log
version="$(python3 -c 'import json;print(json.load(open("/var/lib/starindex/packs/packs/manifest/latest.json"))["packs"]["index"]["version"])' 2>/dev/null)"
night="$(python3 -c 'import json;print(json.load(open("/var/lib/starindex/packs/packs/manifest/latest.json"))["packs"]["index"]["nightDate"])' 2>/dev/null)"
echo "   live pack $version (night $night)"

echo "== backup.sh as starindex (timer user), over TLS"
check "backup.sh" runuser -u starindex -- env PATH=/usr/local/bin:/usr/bin:/bin /opt/starindex/postgres/backup.sh
ls -l /fake/s3/starindex-test/backup/db/ | tail -1

echo "== pin.sh"
PIN="runuser -u starindex -- env PATH=/usr/local/bin:/usr/bin:/bin /opt/starindex/postgres/pin.sh"
check "pin.sh pins" bash -c "$PIN $version | grep -q pinned"
check "pinned in DB" test "$(runuser -u postgres -- psql -d starindex -tAc "SELECT pinned FROM data_pack WHERE version='$version'")" = t
check "pin.sh unknown version fails" bash -c "! $PIN no-such-version 2>/dev/null"
check "pin.sh --unpin" bash -c "$PIN $version --unpin | grep -q unpinned"

echo "== restore.sh: rehearsal next to the live database (no root, no app stop)"
RESTORE="runuser -u starindex -- env PATH=/usr/local/bin:/usr/bin:/bin ADMIN_PGPASSWORD=$ADMIN_PW /opt/starindex/postgres/restore.sh"
stops0=$(grep -c "stop starindex" /tmp/systemctl.log)
check "restore.sh latest starindex_restoretest" bash -c "$RESTORE latest starindex_restoretest > /tmp/restore1.log 2>&1" || cat /tmp/restore1.log
tail -5 /tmp/restore1.log
check "rehearsal did not stop the app" test "$(grep -c "stop starindex" /tmp/systemctl.log)" = "$stops0"
check "restored tables owned by starindex" test "$(runuser -u postgres -- psql -d starindex_restoretest -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tableowner <> 'starindex'")" = 0
src_exec="$(runuser -u postgres -- psql -d starindex -tAc 'SELECT count(*) FROM batch_job_execution')"
check "batch executions equal the dump" grep -q "batch executions $src_exec" /tmp/restore1.log
check "manifest version exists in restored data_pack" test "$(runuser -u postgres -- psql -d starindex_restoretest -tAc "SELECT count(*) FROM data_pack WHERE version='$version'")" = 1
check "rehearsal twice (replaces its own copy)" bash -c "$RESTORE latest starindex_restoretest > /tmp/restore1b.log 2>&1"
java_job starindex_restoretest /var/lib/starindex/packs-restore --spring.batch.job.name=starIndexPublishJob nightDate=$night > /tmp/app3.log 2>&1
check "same pack version after restore" grep -q "팩 $version " /tmp/app3.log

echo "== restore.sh refusals and failure"
check "refuses the live database while it has tables (message)" bash -c "$RESTORE latest starindex 2>&1 | grep -q 'has tables'"
check "refuses the live database while it has tables (exit code)" bash -c "! $RESTORE latest starindex >/dev/null 2>&1"
check "refuses a bad name" bash -c "! $RESTORE latest 'x;drop' 2>/dev/null"
check "refuses an unknown option" bash -c "! $RESTORE latest starindex_x --now 2>/dev/null"
check "latest without backups explains itself" bash -c "S3_BUCKET=empty-bucket $RESTORE latest starindex_x 2>&1 | grep -q 'no backup in s3://empty-bucket'"
printf 'not an archive\n' > /tmp/bad.dump && chmod 644 /tmp/bad.dump
check "invalid archive refused" bash -c "! $RESTORE /tmp/bad.dump starindex_bad 2>/tmp/restore-bad.log && grep -q 'not a pg_dump archive' /tmp/restore-bad.log"
check "invalid archive: nothing created" test "$(runuser -u postgres -- psql -tAc "SELECT count(*) FROM pg_database WHERE datname='starindex_bad'")" = 0
touch /tmp/fail-restore
check "failed pg_restore exits non-zero" bash -c "! $RESTORE latest starindex_fail > /tmp/restore-fail.log 2>&1"
rm -f /tmp/fail-restore
check "failed restore: partial database dropped" test "$(runuser -u postgres -- psql -tAc "SELECT count(*) FROM pg_database WHERE datname='starindex_fail'")" = 0
check "failed restore: live database intact" test "$(runuser -u postgres -- psql -d starindex -tAc 'SELECT count(*) FROM region')" = 17
check "--switch needs root" bash -c "! $RESTORE latest starindex_r1 --switch 2>/dev/null"

echo "== restore.sh --switch (root): new database, app.env updated, app restarted, old database kept"
check "restore.sh latest starindex_r1 --switch" bash -c "ADMIN_PGPASSWORD='$ADMIN_PW' bash /opt/starindex/postgres/restore.sh latest starindex_r1 --switch > /tmp/restore2.log 2>&1" || cat /tmp/restore2.log
check "app.env DB_URL points at starindex_r1, TLS options kept" grep -q "^DB_URL=jdbc:postgresql://$HOST/starindex_r1?sslmode=require&channelBinding=require$" /etc/starindex/app.env
check "app.env backup kept, permissions kept" bash -c 'ls /etc/starindex/app.env.bak-* >/dev/null && test "$(stat -c %U:%G:%a /etc/starindex/app.env)" = root:starindex:640'
check "app stopped and started" bash -c 'tail -2 /tmp/systemctl.log | grep -q "stop starindex" && tail -1 /tmp/systemctl.log | grep -q "start starindex"'
check "old live database kept" test "$(runuser -u postgres -- psql -tAc "SELECT count(*) FROM pg_database WHERE datname='starindex'")" = 1
check "app role now lands in starindex_r1" test "$(runuser -u starindex -- bash -c '. /opt/starindex/postgres/lib.sh; load_db_env; psql -tAc "SELECT current_database()"')" = starindex_r1
check "refuses an existing database (the rollback copy kept by --switch)" bash -c "$RESTORE latest starindex 2>&1 | grep -q 'already exists'"
check "refuses an existing database (exit code)" bash -c "! $RESTORE latest starindex >/dev/null 2>&1"
check "rollback copy untouched" test "$(runuser -u postgres -- psql -d starindex -tAc 'SELECT count(*) FROM region')" = 17

echo "== password rotation: bootstrap restarts a running app"
touch /tmp/starindex.active
openssl rand -base64 32 | tr -d '\n' > /fake/ssm/starindex/db/password
check "bootstrap after rotation" bash -c "ADMIN_PGPASSWORD='$ADMIN_PW' setsid bash /opt/starindex/postgres/bootstrap-db.sh > /tmp/bootstrap3.log 2>&1"
check "bootstrap restarted the running app" grep -q "^systemctl restart starindex$" /tmp/systemctl.log
check "new password works for the app role" test "$(runuser -u starindex -- bash -c '. /opt/starindex/postgres/lib.sh; load_db_env; psql -tAc "SELECT 1"')" = 1

echo "== first fill of an EMPTY live database (RDS → Neon move, DB-PLAN 11.9)"
sed -i "s#^DB_URL=jdbc:postgresql://$HOST/[a-z0-9_]*?#DB_URL=jdbc:postgresql://$HOST/starindex_fresh?#" /etc/starindex/app.env
check "bootstrap creates the empty live database" bash -c "ADMIN_PGPASSWORD='$ADMIN_PW' setsid bash /opt/starindex/postgres/bootstrap-db.sh > /tmp/bootstrap4.log 2>&1"
check "restore fills the empty live database" bash -c "$RESTORE latest starindex_fresh > /tmp/restore3.log 2>&1" || cat /tmp/restore3.log
check "filled live database has the data" test "$(runuser -u postgres -- psql -d starindex_fresh -tAc 'SELECT count(*) FROM region')" = 17
check "second fill refused (no longer empty)" bash -c "! $RESTORE latest starindex_fresh >/dev/null 2>&1"

if [ "$fail" != 0 ]; then
  for f in /tmp/install1.log /tmp/install2.log /tmp/bootstrap1.log /tmp/app1.log /tmp/app2a.log /tmp/server.log /tmp/app2.log /tmp/restore1.log /tmp/app3.log /tmp/restore2.log /tmp/neon.log; do
    [ -f "$f" ] && { echo "--- $f"; grep -v '^\s*at ' "$f" | tail -15; }
  done
fi
echo "RESULT pass=$pass fail=$fail"
[ "$fail" = 0 ]
