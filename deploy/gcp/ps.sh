#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
echo "== Cloud Run =="
gc run services list --region "$GCP_REGION" \
  --format='table(metadata.name, status.conditions[0].status:label=READY, status.url)' 2>/dev/null || true
echo; echo "== Cloud SQL =="
gc sql instances describe "$GCP_SQL_INSTANCE" \
  --format='table(name, state, databaseVersion, region)' 2>/dev/null || echo "  (not created)"
echo; echo "== Agent Runtime =="
if [ -n "${GCP_AGENT_ENGINE_RESOURCE:-}" ]; then echo "  ${GCP_AGENT_ENGINE_RESOURCE}"; else echo "  (not deployed)"; fi
