#!/usr/bin/env bash
# Scales the Cloud Run services to zero and stops the SQL instance.
# Data is kept; `nuke.sh` is what deletes it.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
for svc in open-webui litellm; do
  if run_url "$svc" >/dev/null 2>&1; then
    gc run services update "$svc" --region "$GCP_REGION" --min-instances=0 --quiet >/dev/null
    say "$svc: scaled to zero"
  fi
done
if gc sql instances describe "$GCP_SQL_INSTANCE" >/dev/null 2>&1; then
  gc sql instances patch "$GCP_SQL_INSTANCE" --activation-policy=NEVER --quiet >/dev/null
  say "$GCP_SQL_INSTANCE: stopped"
fi
say "Agent Runtime bills only while serving; nothing to stop."
