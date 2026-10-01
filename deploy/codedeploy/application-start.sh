#!/usr/bin/env bash
# ApplicationStart: start the app only once the database accepts the app role. Before bootstrap-db.sh has run (first
# deployment), a start would fail and every systemd retry would wake Neon (ADR-015); instead the deployment is marked
# pending and validate.sh reports what to do.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$here/common.sh"
# shellcheck source=../postgres/lib.sh
. /opt/starindex/postgres/lib.sh

install -d -o starindex -g starindex -m 750 "$(dirname "$PENDING")"
if ( load_db_env && psql -v ON_ERROR_STOP=1 -tAc "SELECT 1" >/dev/null 2>&1 ); then
  rm -f "$PENDING"
  systemctl enable starindex
  systemctl restart starindex
  log "starindex restarted"
else
  date -u +%FT%TZ > "$PENDING"
  log "database not reachable as the app role yet: app NOT started."
  log "next: aws ssm start-session --target <instance>; sudo /opt/starindex/postgres/bootstrap-db.sh; sudo systemctl enable --now starindex"
fi
