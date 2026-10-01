#!/usr/bin/env bash
# Pin a pack version so retention never deletes it (demo pack, rollback target), or release it. DB-PLAN 4.3.
#   /opt/starindex/postgres/pin.sh <version>            # pin
#   /opt/starindex/postgres/pin.sh <version> --unpin    # release
# Locally: scripts/etl.sh pin|unpin <version>.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
version="${1:?usage: pin.sh <version> [--unpin]}"
value=true; [ "${2:-}" = --unpin ] && value=false
load_db_env
out="$(printf "UPDATE data_pack SET pinned = %s WHERE version = :'version';\n" "$value" |
  psql -v ON_ERROR_STOP=1 -tA -v version="$version" -f - 2>&1)" || die "$out"
case "$out" in
  *"UPDATE 0"*) die "no pack version $version in data_pack" ;;
  *"UPDATE "*)  echo "$([ "$value" = true ] && echo pinned || echo unpinned): $version" ;;
  *) die "$out" ;;
esac
