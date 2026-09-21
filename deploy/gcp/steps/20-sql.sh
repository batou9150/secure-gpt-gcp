#!/usr/bin/env bash
# Cloud SQL for PostgreSQL, reached from Cloud Run over the built-in unix
# socket (/cloudsql/...) so the instance needs no public IP exposure.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
step "Cloud SQL"
if gc sql instances describe "$GCP_SQL_INSTANCE" >/dev/null 2>&1; then
  say "$GCP_SQL_INSTANCE exists"
  gc sql instances patch "$GCP_SQL_INSTANCE" --activation-policy=ALWAYS --quiet >/dev/null 2>&1 || true
else
  say "creating $GCP_SQL_INSTANCE (a few minutes)…"
  gc sql instances create "$GCP_SQL_INSTANCE" \
    --database-version=POSTGRES_16 --tier="$GCP_SQL_TIER" --region="$GCP_REGION" \
    --storage-auto-increase --no-assign-ip --network=default \
    --database-flags=cloudsql.iam_authentication=on --quiet >/dev/null 2>&1 \
  || gc sql instances create "$GCP_SQL_INSTANCE" \
    --database-version=POSTGRES_16 --tier="$GCP_SQL_TIER" --region="$GCP_REGION" \
    --storage-auto-increase --quiet >/dev/null
  say "created"
fi
gc sql users set-password securegpt --instance="$GCP_SQL_INSTANCE" \
  --password="$POSTGRES_PASSWORD" --quiet >/dev/null 2>&1 \
  || gc sql users create securegpt --instance="$GCP_SQL_INSTANCE" \
       --password="$POSTGRES_PASSWORD" --quiet >/dev/null
say "user securegpt configured"
for db in litellm openwebui; do
  gc sql databases describe "$db" --instance="$GCP_SQL_INSTANCE" >/dev/null 2>&1 \
    || gc sql databases create "$db" --instance="$GCP_SQL_INSTANCE" --quiet >/dev/null
  say "database $db ready"
done
