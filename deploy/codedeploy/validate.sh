#!/usr/bin/env bash
# ValidateService: the app must answer on both ports — actuator health on loopback:8081 (DB included: Flyway and the
# pool work) and the public /api/health on 8080 — within VALIDATE_TIMEOUT seconds. A pending first deployment
# (database not bootstrapped) passes with instructions; any other failure fails the deployment (auto-rollback).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$here/common.sh"
timeout="${VALIDATE_TIMEOUT:-150}"

if [ -f "$PENDING" ]; then
  log "PENDING since $(cat "$PENDING"): files installed, app not started (database not bootstrapped)."
  log "run: sudo /opt/starindex/postgres/bootstrap-db.sh && sudo systemctl enable --now starindex"
  exit 0
fi

deadline=$((SECONDS + timeout))
while [ $SECONDS -lt $deadline ]; do
  if curl -fsS --max-time 5 http://127.0.0.1:8081/actuator/health 2>/dev/null | grep -q '"status":"UP"' \
     && curl -fsS --max-time 5 http://127.0.0.1:8080/api/health 2>/dev/null | grep -q '"status":"UP"'; then
    log "healthy after $((timeout - (deadline - SECONDS))) s"
    exit 0
  fi
  sleep 3
done
echo "[deploy] ERROR: not healthy within ${timeout}s" >&2
journalctl -u starindex -n 60 --no-pager 2>/dev/null || true
exit 1
