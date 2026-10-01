#!/usr/bin/env bash
# Verifies deploy/ on Amazon Linux 2023 in a container (DB-PLAN 5.8): install.sh twice (idempotent), Flyway as the
# non-superuser owner over scram, start.sh with/without the SSM key, backup.sh → restore.sh → the same pack version,
# pin.sh, and create-db.sql + cutover restore as an RDS-like non-superuser master. systemctl and aws are local
# stand-ins: nothing reaches AWS. Needs Docker (arm64 image; Apple Silicon or Graviton).
#   scripts/deploy-check.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
docker info >/dev/null 2>&1 || { echo "Docker is not running." >&2; exit 3; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Copy instead of mounting the repository: bind mounts of some paths fail with I/O errors under Docker Desktop.
cp -R "$here/deploy" "$here/scripts" "$work/"
(cd "$here/backend" && ./gradlew -q --console=plain bootJar)
jar=""
for f in "$here"/backend/build/libs/*.jar; do
  [[ "$f" == *-plain.jar ]] && continue
  { [ -z "$jar" ] || [ "$f" -nt "$jar" ]; } && jar="$f"
done
cp "$jar" "$work/app.jar"
docker build --platform linux/arm64 -q -t starindex-deploy-check "$here/deploy/test" >/dev/null
docker run --rm --platform linux/arm64 -v "$work:/work:ro" starindex-deploy-check bash /work/deploy/test/al2023-harness.sh
