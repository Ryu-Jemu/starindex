#!/bin/bash
# Runs INSIDE postgres:18 (scripts/neon-ops-check.sh): the real ops/neon scripts against a Neon stand-in — a
# PostgreSQL 18 server reached as ep-standin.ap-southeast-1.aws.neon.tech that, like Neon, accepts TLS only (SCRAM,
# channel binding) and whose admin neondb_owner is CREATEDB CREATEROLE but not a superuser. /work = ops/.
set -uo pipefail
R=/work; pass=0; fail=0
ok()  { echo "PASS $*"; pass=$((pass+1)); }
bad() { echo "FAIL $*"; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
HOST=ep-standin.ap-southeast-1.aws.neon.tech
ADMIN_PW="admin-$(openssl rand -hex 12)"

echo "== Neon stand-in: TLS-only PostgreSQL 18, non-superuser admin"
echo "127.0.0.1 $HOST" >> /etc/hosts
D=/srv/neon/data
install -d -o postgres -g postgres -m 700 /srv/neon
runuser -u postgres -- initdb -D $D --locale=C.UTF-8 -E UTF8 --auth-local=trust --auth-host=scram-sha-256 >/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$HOST" -keyout $D/server.key -out $D/server.crt 2>/dev/null
chown postgres:postgres $D/server.*; chmod 600 $D/server.key
printf 'local all postgres trust\nhostssl all all 127.0.0.1/32 scram-sha-256\n' > $D/pg_hba.conf
runuser -u postgres -- pg_ctl -D $D -l /tmp/neon.log -w -o "-c listen_addresses=127.0.0.1 -c ssl=on" start >/dev/null
runuser -u postgres -- psql -qc "CREATE ROLE neondb_owner LOGIN CREATEDB CREATEROLE PASSWORD '$ADMIN_PW'" -c "CREATE DATABASE neondb OWNER neondb_owner"
su_psql() { runuser -u postgres -- psql -tA "$@"; }
check "stand-in refuses plain TCP" bash -c "! PGPASSWORD='$ADMIN_PW' psql 'host=$HOST user=neondb_owner dbname=neondb sslmode=disable' -tAc 'select 1' 2>/dev/null"

echo "== argv log for psql/pg_restore/pg_dump (no password may appear)"
mkdir -p /fakebin
for t in psql pg_restore pg_dump; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> /tmp/argv.log\nif [ "%s" = pg_restore ] && [ -f /tmp/fail-restore ] && [[ " $* " == *" -d "* ]]; then echo "forced failure" >&2; exit 1; fi\nexec /usr/bin/%s "$@"\n' "$t" "$t" > /fakebin/$t
done
chmod 755 /fakebin/*; export PATH=/fakebin:$PATH; : > /tmp/argv.log
export NEON_ENV_FILE=/tmp/neon.env
sed "s#ep-REPLACE-ME.ap-southeast-1.aws.neon.tech#$HOST#" $R/neon/neon.env.example > $NEON_ENV_FILE
grep '^DB_URL=' $NEON_ENV_FILE

echo "== bootstrap.sh"
check "no password and no terminal → explains NEON_ADMIN_PASSWORD" bash -c "setsid bash $R/neon/bootstrap.sh </dev/null 2>&1 | grep -q NEON_ADMIN_PASSWORD"
check "bootstrap" bash -c "NEON_ADMIN_PASSWORD='$ADMIN_PW' setsid bash $R/neon/bootstrap.sh > /tmp/b1.log 2>&1" || cat /tmp/b1.log
grep -E 'connected as|client TLS' /tmp/b1.log
APP_PW="$(tail -1 /tmp/b1.log)"
check "app role: not superuser, no CREATEDB" grep -q "connected as starindex to starindex, PostgreSQL 18.*superuser false, createdb false" /tmp/b1.log
check "client TLS 1.2+ with channel binding required" grep -qE "client TLS: TLSv1\.[23] \(sslmode=require, channel_binding=require\)" /tmp/b1.log
check "generated password printed once (44 base64 chars)" test "${#APP_PW}" -eq 44
check "generated password works for the app role" bash -c "PGPASSWORD='$APP_PW' psql 'host=$HOST user=starindex dbname=starindex sslmode=require' -tAc 'select 1' | grep -qx 1"
check "database starindex owned by starindex, locale C" test "$(su_psql -c "SELECT pg_get_userbyid(datdba) || '/' || datcollate FROM pg_database WHERE datname='starindex'")" = starindex/C
FIXED="fixed-$(openssl rand -hex 16)"
check "bootstrap again with APP_DB_PASSWORD (idempotent, rotates)" bash -c "NEON_ADMIN_PASSWORD='$ADMIN_PW' APP_DB_PASSWORD='$FIXED' setsid bash $R/neon/bootstrap.sh > /tmp/b2.log 2>&1"
check "a given password is not echoed" bash -c "! grep -qF '$FIXED' /tmp/b2.log && grep -q 'APP_DB_PASSWORD you gave' /tmp/b2.log"
check "rotated password works, old one does not" bash -c "PGPASSWORD='$FIXED' psql 'host=$HOST user=starindex dbname=starindex sslmode=require' -tAc 'select 1' >/dev/null && ! PGPASSWORD='$APP_PW' psql 'host=$HOST user=starindex dbname=starindex sslmode=require' -tAc 'select 1' >/dev/null 2>&1"
check "short APP_DB_PASSWORD refused" bash -c "! NEON_ADMIN_PASSWORD='$ADMIN_PW' APP_DB_PASSWORD=short bash $R/neon/bootstrap.sh >/dev/null 2>&1"
check "pooled endpoint refused" bash -c "DB_URL='jdbc:postgresql://ep-x-pooler.neon.tech/starindex?sslmode=require' NEON_ADMIN_PASSWORD=x bash $R/neon/bootstrap.sh 2>&1 | grep -q 'without -pooler'"
check "plaintext DB_URL refused" bash -c "DB_URL='jdbc:postgresql://$HOST/starindex?sslmode=disable' NEON_ADMIN_PASSWORD=x bash $R/neon/bootstrap.sh 2>&1 | grep -q 'must require TLS'"

echo "== an app schema like Flyway's, then a dump as the app role"
app() { PGPASSWORD="$FIXED" psql "host=$HOST user=starindex dbname=${1:-starindex} sslmode=require" -v ON_ERROR_STOP=1 -tAq "${@:2}"; }
app starindex -c "CREATE TABLE flyway_schema_history (version varchar(50)); INSERT INTO flyway_schema_history VALUES ('1'),('6'),(NULL);
  CREATE TABLE region (id bigint PRIMARY KEY); INSERT INTO region SELECT g FROM generate_series(1,17) g;
  CREATE TABLE batch_job_execution (job_execution_id bigint); INSERT INTO batch_job_execution VALUES (1),(2),(3);
  CREATE TABLE data_pack (version text PRIMARY KEY, pinned boolean NOT NULL DEFAULT false);
  INSERT INTO data_pack VALUES ('20261012-1700-b2a3bf8b', false), ('20261012-2000-0123abcd', true);"
PGPASSWORD="$FIXED" /usr/bin/pg_dump -Fc "host=$HOST user=starindex dbname=starindex sslmode=require" -f /tmp/s.dump
check "dump made" test -s /tmp/s.dump

echo "== restore.sh"
cd /tmp || exit 1
check "restore into a new database" bash -c "NEON_ADMIN_PASSWORD='$ADMIN_PW' bash $R/neon/restore.sh /tmp/s.dump starindex_r1 > /tmp/r1.log 2>&1" || cat /tmp/r1.log
grep -E 'region rows|not owned|To switch' /tmp/r1.log
check "restored data equal" bash -c "grep -q 'region rows 17' /tmp/r1.log && grep -q 'batch executions 3' /tmp/r1.log && grep -q 'data_pack rows 2, pinned 1' /tmp/r1.log && grep -q 'flyway latest 6' /tmp/r1.log"
check "every restored table owned by starindex" grep -q 'tables not owned by starindex 0' /tmp/r1.log
check "switch hint keeps TLS options" grep -qF "jdbc:postgresql://$HOST/starindex_r1?sslmode=require&channelBinding=require" /tmp/r1.log
check "app role can use the restored database" test "$(app starindex_r1 -c 'SELECT count(*) FROM region')" = 17
check "refuses an existing database" bash -c "NEON_ADMIN_PASSWORD='$ADMIN_PW' bash $R/neon/restore.sh /tmp/s.dump starindex_r1 2>&1 | grep -q 'already exists'"
check "refuses the live database" bash -c "NEON_ADMIN_PASSWORD='$ADMIN_PW' bash $R/neon/restore.sh /tmp/s.dump starindex 2>&1 | grep -q 'live database'"
check "refuses a bad name" bash -c "! NEON_ADMIN_PASSWORD='$ADMIN_PW' bash $R/neon/restore.sh /tmp/s.dump 'x;drop' 2>/dev/null"
printf 'not an archive\n' > /tmp/bad.dump
check "invalid archive refused before creating anything" bash -c "NEON_ADMIN_PASSWORD='$ADMIN_PW' bash $R/neon/restore.sh /tmp/bad.dump starindex_bad 2>&1 | grep -q 'not a pg_dump' && test \"\$(runuser -u postgres -- psql -tAc \"SELECT count(*) FROM pg_database WHERE datname='starindex_bad'\")\" = 0"
touch /tmp/fail-restore
check "failed pg_restore exits non-zero" bash -c "! NEON_ADMIN_PASSWORD='$ADMIN_PW' bash $R/neon/restore.sh /tmp/s.dump starindex_fail > /tmp/rf.log 2>&1"
rm -f /tmp/fail-restore
check "failed restore: partial database dropped" test "$(su_psql -c "SELECT count(*) FROM pg_database WHERE datname='starindex_fail'")" = 0
check "live database intact" test "$(app starindex -c 'SELECT count(*) FROM region')" = 17

echo "== pin.sh"
check "pin" bash -c "NEON_ADMIN_PASSWORD='$ADMIN_PW' bash $R/neon/pin.sh 20261012-1700-b2a3bf8b | grep -q 'pinned: 20261012-1700-b2a3bf8b'"
check "pinned in DB" test "$(app starindex -c "SELECT pinned FROM data_pack WHERE version='20261012-1700-b2a3bf8b'")" = t
check "unpin" bash -c "NEON_ADMIN_PASSWORD='$ADMIN_PW' bash $R/neon/pin.sh 20261012-1700-b2a3bf8b --unpin | grep -q unpinned && test \"\$(PGPASSWORD='$FIXED' psql 'host=$HOST user=starindex dbname=starindex sslmode=require' -tAc \"SELECT pinned FROM data_pack WHERE version='20261012-1700-b2a3bf8b'\")\" = f"
check "unknown version fails" bash -c "! NEON_ADMIN_PASSWORD='$ADMIN_PW' bash $R/neon/pin.sh 20990101-0000-deadbeef 2>/dev/null"
check "malformed version refused" bash -c "NEON_ADMIN_PASSWORD='$ADMIN_PW' bash $R/neon/pin.sh \"x'; drop table data_pack; --\" 2>&1 | grep -q 'not a pack version'"

check "argv log is recording" test -s /tmp/argv.log
grep -nF -e "$ADMIN_PW" -e "$FIXED" /tmp/argv.log /tmp/b2.log /tmp/r1.log | sed 's/^/   leak? /' | head -5
check "no password in argv or logs" bash -c "! grep -rqF -e '$ADMIN_PW' -e '$FIXED' /tmp/argv.log /tmp/b2.log /tmp/r1.log"

if [ "$fail" != 0 ]; then for f in /tmp/b1.log /tmp/r1.log /tmp/rf.log /tmp/neon.log; do [ -f "$f" ] && { echo "--- $f"; tail -15 "$f"; }; done; fi
echo "RESULT pass=$pass fail=$fail"
[ "$fail" = 0 ]
