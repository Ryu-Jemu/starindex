#!/usr/bin/env bash
# BeforeInstall: start from an empty bundle directory so files removed from the repository do not linger.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$here/common.sh"
case "$BUNDLE" in /opt/starindex/bundle|/tmp/*) ;; *) die "refusing to clean unexpected BUNDLE=$BUNDLE" ;; esac
rm -rf "$BUNDLE"
install -d -m 755 "$BUNDLE"
log "bundle directory reset: $BUNDLE"
