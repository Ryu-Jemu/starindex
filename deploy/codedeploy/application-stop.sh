#!/usr/bin/env bash
# ApplicationStop: stop the running app before files change. A missing unit (first install) is not an error.
set -euo pipefail
if systemctl cat starindex >/dev/null 2>&1; then
  systemctl stop starindex || true
fi
echo "[deploy] application stopped"
