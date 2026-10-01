#!/usr/bin/env bash
# ExecStart of starindex.service (DB-PLAN 5.4). Secrets are read from SSM SecureString at every start and handed to the
# JVM as environment variables; nothing secret is written to disk. Non-secret settings: /etc/starindex/app.env.
set -euo pipefail
region="${AWS_REGION:-ap-northeast-2}"
ssm() { aws ssm get-parameter --region "$region" --with-decryption --name "$1" --query Parameter.Value --output text; }

DB_PASSWORD="$(ssm /starindex/db/password)"
export DB_PASSWORD
# The data.go.kr key may not exist yet: the app then runs the key-free steps and stops the others with guidance.
if ! DATA_GO_KR_SERVICE_KEY="$(ssm /starindex/data-go-kr/service-key 2>/dev/null)"; then
  echo "warning: /starindex/data-go-kr/service-key not readable; key-dependent ETL steps will stop" >&2
  DATA_GO_KR_SERVICE_KEY=""
fi
export DATA_GO_KR_SERVICE_KEY

# shellcheck disable=SC2086  # JAVA_OPTS is a list of JVM flags
exec java ${JAVA_OPTS:-} -jar /opt/starindex/app.jar
