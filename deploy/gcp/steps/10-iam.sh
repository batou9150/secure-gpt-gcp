#!/usr/bin/env bash
# One runtime identity shared by both Cloud Run services and the agent.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
step "Service account and IAM"
if ! gc iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  gc iam service-accounts create "$GCP_SA" --display-name "Secure GPT runtime" >/dev/null
  say "created $SA_EMAIL"
else
  say "$SA_EMAIL exists"
fi
for role in roles/cloudsql.client roles/secretmanager.secretAccessor roles/aiplatform.user; do
  gc projects add-iam-policy-binding "$GCP_PROJECT" \
    --member "serviceAccount:${SA_EMAIL}" --role "$role" --condition=None --quiet >/dev/null
  say "granted $role"
done
