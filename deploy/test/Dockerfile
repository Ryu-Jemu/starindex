# Amazon Linux 2023 with what the EC2 gets (DB-PLAN 5.1): PostgreSQL 18 from the core repository, Corretto 21, Valkey,
# AWS CLI v2. Used by scripts/deploy-check.sh only.
FROM amazonlinux:2023
RUN dnf -y --setopt=install_weak_deps=False install postgresql18-server postgresql18 java-21-amazon-corretto-headless \
      valkey awscli-2 python3 sudo procps-ng util-linux shadow-utils findutils openssl \
 && dnf clean all
