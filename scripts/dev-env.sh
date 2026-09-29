#!/usr/bin/env bash
# Usage: source scripts/dev-env.sh
#
# Until the Xcode license is accepted (`sudo xcodebuild -license accept`), the /usr/bin/git and
# swift shims refuse to run. This falls back to the Command Line Tools toolchain. It also works
# around stale *.private.swiftinterface files left in the CLT's SwiftPM ManifestAPI by an older
# CLT install, which make every Package.swift fail to link. The fix uses a cleaned copy of the
# ManifestAPI in a user cache directory. System files are never modified.

if xcodebuild -license check >/dev/null 2>&1; then
  unset SWIFTPM_CUSTOM_LIBS_DIR
  echo "[dev-env] Xcode toolchain is usable (license accepted)."
else
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  _cache="${XDG_CACHE_HOME:-$HOME/Library/Caches}/starindex/swiftpm-libs"
  if [ ! -d "$_cache/ManifestAPI" ]; then
    mkdir -p "$_cache"
    cp -R /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI "$_cache/"
    cp -R /Library/Developer/CommandLineTools/usr/lib/swift/pm/PluginAPI "$_cache/" 2>/dev/null || true
    find "$_cache" -name "*.private.swiftinterface" -delete
  fi
  export SWIFTPM_CUSTOM_LIBS_DIR="$_cache"
  echo "[dev-env] Xcode license not accepted → using CommandLineTools ($DEVELOPER_DIR)"
  echo "[dev-env] SWIFTPM_CUSTOM_LIBS_DIR=$SWIFTPM_CUSTOM_LIBS_DIR"
  unset _cache
fi
