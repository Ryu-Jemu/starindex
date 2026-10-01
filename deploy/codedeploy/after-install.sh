#!/usr/bin/env bash
# AfterInstall: app.env from the example on first deployment, infrastructure values from stack.env, host setup
# (deploy/ec2/install.sh, idempotent), then the new jar. Secrets never pass through here: start.sh reads SSM.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$here/common.sh"
[ -f "$BUNDLE/app.jar" ] || die "no app.jar in $BUNDLE"

install -d -m 755 /etc/starindex
if [ ! -f "$APP_ENV" ]; then
  install -m 640 "$BUNDLE/deploy/app/app.env.example" "$APP_ENV"
  log "created $APP_ENV from app.env.example"
fi
if [ -f "$STACK_ENV" ]; then
  for k in $STACK_KEYS; do
    v="$(stack_get "$k")"
    [ -n "$v" ] && set_env_key "$APP_ENV" "$k" "$v"
  done
  log "infrastructure values from $STACK_ENV applied: $STACK_KEYS"
else
  log "no $STACK_ENV (not provisioned by CloudFormation): app.env left as is"
fi
grep -q '^DB_URL=jdbc:postgresql://ep-REPLACE-ME' "$APP_ENV" && die "DB_URL in $APP_ENV is still the placeholder: set it (stack parameter DbUrl) and redeploy"

bash "$BUNDLE/deploy/ec2/install.sh"

tmp="$(mktemp /opt/starindex/app.jar.XXXXXX)"
install -m 644 "$BUNDLE/app.jar" "$tmp"
mv -f "$tmp" /opt/starindex/app.jar
log "app.jar installed ($(sha256sum /opt/starindex/app.jar | cut -c1-12))"
