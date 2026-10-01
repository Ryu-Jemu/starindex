#!/usr/bin/env bash
# Verifies ops/neon/*.sh against a Neon stand-in in a postgres:18 container (TLS only, non-superuser admin):
# bootstrap (twice, rotation), refusals, restore into a new database (owned by starindex, failure cleanup), pin.
# Nothing reaches Neon or GitHub. Needs Docker.
#   scripts/neon-ops-check.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
docker info >/dev/null 2>&1 || { echo "Docker is not running." >&2; exit 3; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$here/ops/neon" "$work/neon"
rm -f "$work/neon/neon.env"   # never the operator's real settings
docker run --rm -v "$work:/work:ro" postgres:18 bash /work/neon/test/harness.sh
