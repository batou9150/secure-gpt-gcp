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
  # The edition must be explicit: a project defaulting to ENTERPRISE_PLUS
  # rejects shared-core tiers like db-g1-small.
  common=(--database-version=POSTGRES_16 --tier="$GCP_SQL_TIER"
          --edition="${GCP_SQL_EDITION:-ENTERPRISE}" --region="$GCP_REGION"
          --storage-auto-increase --quiet)
  # Prefer a private IP. It needs service-networking peering on the VPC, which
  # not every project has, so fall back to an instance with no authorised
  # networks — Cloud Run still reaches it over the Cloud SQL unix socket.
  if gc sql instances create "$GCP_SQL_INSTANCE" "${common[@]}" \
       --no-assign-ip --network=default >/dev/null 2>&1; then
    say "created with a private IP"
  else
    say "private IP unavailable (no VPC peering) — creating without public authorised networks"
    gc sql instances create "$GCP_SQL_INSTANCE" "${common[@]}" >/dev/null
    say "created"
  fi
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
