# shellcheck shell=bash
# Shared by the CodeDeploy hooks. BUNDLE is where CodeDeploy copied the revision (appspec files: → destination).
BUNDLE="${BUNDLE:-/opt/starindex/bundle}"
APP_ENV="${APP_ENV:-/etc/starindex/app.env}"
# Written by the CloudFormation UserData (deploy/aws/starindex.yaml): infrastructure values only, no secrets.
STACK_ENV="${STACK_ENV:-/etc/starindex/stack.env}"
# Set by application-start.sh when the database is not bootstrapped yet; read by validate.sh.
# shellcheck disable=SC2034
PENDING="${PENDING:-/var/lib/starindex/deploy-pending}"
# Keys stack.env may set in app.env. Anything else in stack.env is ignored.
# shellcheck disable=SC2034  # used by the hooks that source this file
STACK_KEYS="DB_URL S3_BUCKET CLOUDFRONT_DISTRIBUTION_ID CLOUDFRONT_DOMAIN AWS_REGION"

log() { echo "[deploy] $*"; }
die() { echo "[deploy] ERROR: $*" >&2; exit 1; }

# set_env_key FILE KEY VALUE: replaces KEY=… (or appends it) without interpreting VALUE (URLs carry & ? / =).
set_env_key() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp "$file.XXXXXX")"
  KEY="$key" VALUE="$value" awk 'BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"]; done = 0 }
    index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$file" > "$tmp"
  chown --reference="$file" "$tmp" 2>/dev/null || true
  chmod --reference="$file" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
}

# stack_get KEY: the last KEY=value line of stack.env, verbatim.
stack_get() { sed -n "s/^$1=//p" "$STACK_ENV" | tail -1; }
