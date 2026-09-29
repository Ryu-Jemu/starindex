#!/usr/bin/env bash
# Runs the SkyCore Swift package tests (G1a) on macOS.
#
# - Build products go OUTSIDE the repo: ~/Desktop is iCloud-synced (File Provider), which adds
#   FinderInfo xattrs to bundles and makes codesign fail ("resource fork, Finder information, or
#   similar detritus not allowed").
# - With the Command Line Tools toolchain, Swift Testing's macro plugin path must be passed
#   explicitly.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dev-env.sh
source "$here/dev-env.sh" >/dev/null

scratch="${XDG_CACHE_HOME:-$HOME/Library/Caches}/starindex/build/skycore"
extra=()
if [ "${DEVELOPER_DIR:-}" = "/Library/Developer/CommandLineTools" ]; then
  extra=(-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing)
fi

cd "$here/../ios/Packages/SkyCore"
# ${extra[@]+...}: bash 3.2 (macOS) treats an empty array as unbound under `set -u`.
exec swift test --scratch-path "$scratch" ${extra[@]+"${extra[@]}"} "$@"
