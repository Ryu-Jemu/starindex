#!/bin/bash
# Phase 2 of scripts/neon-ops-check.sh, ON THE MAC: the ops scripts under macOS /bin/bash 3.2 with Homebrew psql 17,
# so pg_dump/pg_restore 18 take the Docker fallback of lib.sh pg18() — the path an operator actually runs. The server
# is a TLS-only PostgreSQL 18 container with a non-superuser admin (like Neon), published on 127.0.0.1:25432.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS $*"; pass=$((pass+1)); }
bad() { echo "FAIL $*"; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
BASH32=/bin/bash
NAME=starindex-neon-standin-mac
PORT=25432
ADMIN_PW="admin-$(openssl rand -hex 12)"
work="$(mktemp -d)"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

echo "== stand-in on 127.0.0.1:$PORT (TLS only, admin neondb_owner not superuser)"
cat > "$work/init.sh" <<'SH'
#!/bin/bash
set -e
cd "$PGDATA"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=localhost" -keyout server.key -out server.crt 2>/dev/null
chmod 600 server.key
printf 'local all all trust\nhostssl all all 0.0.0.0/0 scram-sha-256\nhostssl all all ::/0 scram-sha-256\n' > pg_hba.conf
psql -v ON_ERROR_STOP=1 -U postgres -qc "ALTER SYSTEM SET ssl = on" \
  -c "CREATE ROLE neondb_owner LOGIN CREATEDB CREATEROLE PASSWORD '$ADMIN_PW'" -c "CREATE DATABASE neondb OWNER neondb_owner"
SH
chmod 755 "$work/init.sh"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=unused -e ADMIN_PW="$ADMIN_PW" -e POSTGRES_INITDB_ARGS="--locale=C.UTF-8" \
  -v "$work/init.sh:/docker-entrypoint-initdb.d/init.sh:ro" -p "127.0.0.1:$PORT:5432" postgres:18 >/dev/null
for _ in $(seq 1 60); do
  PGPASSWORD="$ADMIN_PW" psql "host=127.0.0.1 port=$PORT user=neondb_owner dbname=neondb sslmode=require" -tAc 'select 1' >/dev/null 2>&1 && break
  sleep 1
done
check "stand-in up over TLS" bash -c "PGPASSWORD='$ADMIN_PW' psql 'host=127.0.0.1 port=$PORT user=neondb_owner dbname=neondb sslmode=require' -tAc 'select 1' | grep -qx 1"
check "stand-in refuses plain TCP" bash -c "! PGPASSWORD='$ADMIN_PW' psql 'host=127.0.0.1 port=$PORT user=neondb_owner dbname=neondb sslmode=disable' -tAc 'select 1' 2>/dev/null"
check "local psql is older than 18 (Docker fallback is exercised)" bash -c "[ \"\$(pg_restore --version | grep -oE '[0-9]+' | head -1)\" -lt 18 ]"

export NEON_ENV_FILE="$work/neon.env"
printf 'DB_URL=jdbc:postgresql://127.0.0.1:%s/starindex?sslmode=require&channelBinding=require\n' "$PORT" > "$NEON_ENV_FILE"
QPW="q'uote-$(openssl rand -hex 16)"   # a single quote: the bash 3.2 escaping bug of ${pw//…}

echo "== bootstrap.sh under $($BASH32 --version | head -1)"
check "bootstrap with a quote in APP_DB_PASSWORD" bash -c "NEON_ADMIN_PASSWORD='$ADMIN_PW' APP_DB_PASSWORD=\"$QPW\" LOCAL_ENV='$work/app.env' $BASH32 '$here/bootstrap.sh' --save-local > '$work/b.log' 2>&1" || cat "$work/b.log"
check "the quoted password works" bash -c "PGPASSWORD=\"$QPW\" psql 'host=127.0.0.1 port=$PORT user=starindex dbname=starindex sslmode=require' -tAc 'select 1' | grep -qx 1"
check "app.env written 0600 with the exact password" bash -c "[ \"\$(stat -f %Lp '$work/app.env')\" = 600 ] && grep -qxF \"DB_PASSWORD=$QPW\" '$work/app.env'"
check "password not in the bootstrap output" bash -c "! grep -qF \"$QPW\" '$work/b.log'"

echo "== schema, dump (pg_dump 18 in Docker), restore.sh and pin.sh under bash 3.2"
app() { PGPASSWORD="$QPW" psql "host=127.0.0.1 port=$PORT user=starindex dbname=${1:-starindex} sslmode=require" -v ON_ERROR_STOP=1 -tAq "${@:2}"; }
app starindex -c "CREATE TABLE flyway_schema_history (version varchar(50)); INSERT INTO flyway_schema_history VALUES ('6');
  CREATE TABLE region (id bigint PRIMARY KEY); INSERT INTO region SELECT g FROM generate_series(1,17) g;
  CREATE TABLE batch_job_execution (job_execution_id bigint); INSERT INTO batch_job_execution VALUES (1);
  CREATE TABLE data_pack (version text PRIMARY KEY, pinned boolean NOT NULL DEFAULT false);
  INSERT INTO data_pack VALUES ('20261012-1700-b2a3bf8b', false);"
PGPASSWORD="$QPW" docker run --rm -e PGPASSWORD postgres:18 pg_dump -Fc \
  "host=host.docker.internal port=$PORT user=starindex dbname=starindex sslmode=require" > "$work/s.dump"
check "dump made" test -s "$work/s.dump"
(cd "$work" && NEON_ADMIN_PASSWORD="$ADMIN_PW" $BASH32 "$here/restore.sh" "$work/s.dump" starindex_r1 > "$work/r.log" 2>&1)
rc=$?
check "restore.sh via the Docker pg_restore" test "$rc" = 0
grep -E 'region rows|not owned' "$work/r.log" | sed 's/^/   /'
check "restored rows and ownership" bash -c "grep -q 'region rows 17' '$work/r.log' && grep -q 'tables not owned by starindex 0' '$work/r.log'"
printf 'not an archive\n' > "$work/bad.dump"
check "bad archive refused, nothing created" bash -c "(cd '$work' && NEON_ADMIN_PASSWORD='$ADMIN_PW' $BASH32 '$here/restore.sh' '$work/bad.dump' starindex_bad 2>&1 | grep -q 'not a pg_dump') \
  && [ \"\$(PGPASSWORD='$ADMIN_PW' psql 'host=127.0.0.1 port=$PORT user=neondb_owner dbname=neondb sslmode=require' -tAc \"SELECT count(*) FROM pg_database WHERE datname='starindex_bad'\")\" = 0 ]"
check "pin.sh under bash 3.2" bash -c "NEON_ADMIN_PASSWORD='$ADMIN_PW' $BASH32 '$here/pin.sh' 20261012-1700-b2a3bf8b | grep -q pinned"
check "pinned in DB" test "$(app starindex -c "SELECT pinned FROM data_pack WHERE version='20261012-1700-b2a3bf8b'")" = t

[ "$fail" = 0 ] || { echo "--- bootstrap"; tail -5 "$work/b.log"; echo "--- restore"; tail -8 "$work/r.log"; }
echo "RESULT(mac) pass=$pass fail=$fail"
[ "$fail" = 0 ]
