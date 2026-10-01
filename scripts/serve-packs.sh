#!/usr/bin/env bash
# Serves index packs to the iOS simulator at http://127.0.0.1:8090 (the Debug STARINDEX_PACK_BASE_URL,
# ios/project.yml), with the same layout as the S3 bucket behind CloudFront:
#   packs/manifest/latest.json
#   packs/index/<version>/index.json.gz
#
# Usage:
#   scripts/serve-packs.sh            # backend/build/packs (LocalPackStore root, filled by `scripts/etl.sh publish`)
#   scripts/serve-packs.sh <dir>      # any directory with that layout
#   scripts/serve-packs.sh --golden   # contracts/golden staged into a temp dir (manifest + gz at its path)
#   PORT=8091 scripts/serve-packs.sh  # another port (the app's Debug build expects 8090)
#
# python's http.server sends .gz as application/gzip without Content-Encoding (like S3/CloudFront here), so the
# app gunzips and verifies the sha256 itself, and answers If-Modified-Since with 304 (the app's conditional GET).
# It binds to 127.0.0.1 only: the simulator shares the Mac's loopback; nothing is exposed on the network.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
port="${PORT:-8090}"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

tmp=""
cleanup() { if [ -n "$tmp" ]; then rm -rf "$tmp"; fi; }
trap cleanup EXIT

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --golden)
    golden="$root/contracts/golden"
    manifest="$golden/manifest-v1.json"
    [ -f "$manifest" ] || { echo "missing $manifest" >&2; exit 1; }
    # Path from the manifest itself, so the staged layout is exactly what the app will request.
    rel="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["packs"]["index"]["path"])' "$manifest")"
    case "$rel" in
      /*|*..*|"") echo "unsafe pack path in manifest: '$rel'" >&2; exit 1 ;;
    esac
    tmpbase="${TMPDIR:-/tmp}"
    tmp="$(mktemp -d "${tmpbase%/}/starindex-packs.XXXXXX")"
    mkdir -p "$tmp/packs/manifest" "$tmp/$(dirname "$rel")"
    cp "$manifest" "$tmp/packs/manifest/latest.json"
    cp "$golden/index-pack-v2.json.gz" "$tmp/$rel"
    dir="$tmp"
    ;;
  "")
    dir="$root/backend/build/packs"
    ;;
  -*)
    echo "unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
  *)
    dir="$1"
    ;;
esac

[ -d "$dir" ] || { echo "no such directory: $dir (run a local publish first, or use --golden)" >&2; exit 1; }
if [ ! -f "$dir/packs/manifest/latest.json" ]; then
  echo "warning: $dir/packs/manifest/latest.json does not exist yet; the app will show an HTTP 404 error" >&2
fi

echo "serving $dir on http://127.0.0.1:$port (Ctrl-C to stop)"
# Not exec: the EXIT trap must still remove the --golden staging directory.
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir"
