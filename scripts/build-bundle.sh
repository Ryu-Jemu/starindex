#!/usr/bin/env bash
# Builds the CodeDeploy revision (PLAN 3.5): appspec.yml at the root, app.jar, and the deploy/ scripts the hooks and
# install.sh use. Used by the GitHub Actions deploy job and by scripts/deploy-check.sh, so both test the same layout.
#   scripts/build-bundle.sh [out-dir]   → <out-dir>/bundle/ and <out-dir>/starindex-bundle.zip (default backend/build/bundle)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/backend/build/bundle}"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
(cd "$root/backend" && ./gradlew -q --console=plain bootJar)
jar=""
for f in "$root"/backend/build/libs/*.jar; do
  [[ "$f" == *-plain.jar ]] && continue
  { [ -z "$jar" ] || [ "$f" -nt "$jar" ]; } && jar="$f"
done
[ -n "$jar" ] || { echo "no boot jar in backend/build/libs" >&2; exit 1; }

rm -rf "$out/bundle" "$out/starindex-bundle.zip"
mkdir -p "$out/bundle/deploy"
cp "$root/deploy/codedeploy/appspec.yml" "$out/bundle/appspec.yml"
cp "$jar" "$out/bundle/app.jar"
for d in app codedeploy ec2 postgres systemd; do cp -R "$root/deploy/$d" "$out/bundle/deploy/"; done
find "$out/bundle" -name '.DS_Store' -delete
(cd "$out/bundle" && zip -q -r -X "$out/starindex-bundle.zip" .)
echo "$out/starindex-bundle.zip ($(du -h "$out/starindex-bundle.zip" | cut -f1))"
