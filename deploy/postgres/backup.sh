#!/usr/bin/env bash
# Daily full pg_dump → s3://$S3_BUCKET/backup/db/starindex-YYYY-MM-DD.dump (DB-PLAN 5.5); the bucket lifecycle expires
# backup/db/ after 7 days. Connects as the owner role from DB_URL, so it works the same for EC2 PostgreSQL and RDS.
# Run by starindex-pgdump.timer (KST 04:40); by hand: sudo -u starindex /opt/starindex/postgres/backup.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_db_env
bucket="$(env_get S3_BUCKET)"
[ -n "$bucket" ] || die "S3_BUCKET is empty in $APP_ENV"

dump="$(mktemp /var/tmp/starindex-XXXXXX.dump)"
trap 'rm -f "$dump"' EXIT
pg_dump -Fc --file="$dump"
pg_restore --list "$dump" >/dev/null           # the archive is readable before it replaces anything
key="backup/db/starindex-$(date -u +%F).dump"
aws s3 cp --region "$AWS_REGION" --only-show-errors "$dump" "s3://$bucket/$key"
echo "backup $(stat -c %s "$dump") bytes → s3://$bucket/$key"
