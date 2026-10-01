#!/usr/bin/env bash
# Keep a pack version forever (demo, rollback) or release it (DB-PLAN 4.3): retention never deletes a pinned pack.
#   ops/neon/pin.sh <pack version> [--unpin]
# Runs as the admin login with SET ROLE starindex (the table owner); no app password needed on the Mac.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
version="${1:?usage: pin.sh <pack version> [--unpin]}"
value=true
case "${2:-}" in "") ;; --unpin) value=false ;; *) die "usage: pin.sh <pack version> [--unpin]" ;; esac
[[ "$version" =~ ^[0-9]{8}-[0-9]{4}-[0-9a-f]{8}$ ]] || die "not a pack version (yyyyMMdd-HHmm-<hash8>): $version"
parse_db_url
app_db="$APP_DB"
load_admin_env
out="$(PGDATABASE="$app_db" psql -v ON_ERROR_STOP=1 -tA -v version="$version" <<SQL
SET ROLE starindex;
UPDATE data_pack SET pinned = $value WHERE version = :'version';
SQL
)"
case "$out" in
  *"UPDATE 0"*) die "no pack version $version in data_pack" ;;
  *"UPDATE "*) [ "$value" = true ] && echo "pinned: $version" || echo "unpinned: $version" ;;
  *) echo "$out" >&2; exit 1 ;;
esac
