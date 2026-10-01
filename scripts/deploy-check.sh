#!/usr/bin/env bash
# Verifies deploy/ on Amazon Linux 2023 in a container against a Neon stand-in (ADR-015, DB-PLAN 11): a TLS-only
# PostgreSQL 18 with a non-superuser admin (neondb_owner). Covers install.sh twice, bootstrap-db.sh, Flyway as the
# owner role over TLS + channel binding, start.sh with/without the SSM key, the pool draining to 0 connections,
# backup.sh → restore.sh next to the live database → the same pack version, --switch, pin.sh and failure paths, and the
# CodeDeploy hooks on the bundle from scripts/build-bundle.sh (stack.env merge, pending first start, validate).
# systemctl and aws are local stand-ins: nothing reaches AWS or Neon. Needs Docker (arm64; Apple Silicon or Graviton).
#   scripts/deploy-check.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
docker info >/dev/null 2>&1 || { echo "Docker is not running." >&2; exit 3; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Copy instead of mounting the repository: bind mounts of some paths fail with I/O errors under Docker Desktop.
cp -R "$here/deploy" "$here/scripts" "$work/"
# The CodeDeploy revision exactly as the GitHub Actions deploy job builds it (also builds the boot jar).
"$here/scripts/build-bundle.sh" "$work/out" >/dev/null
cp -R "$work/out/bundle" "$work/bundle"
cp "$work/bundle/app.jar" "$work/app.jar"
docker build --platform linux/arm64 -q -t starindex-deploy-check "$here/deploy/test" >/dev/null
docker run --rm --platform linux/arm64 -v "$work:/work:ro" starindex-deploy-check bash /work/deploy/test/al2023-harness.sh
