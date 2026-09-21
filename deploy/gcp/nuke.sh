#!/usr/bin/env bash
# Deletes every Google Cloud resource this stack created. Irreversible.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

cat <<EOF
This permanently deletes, in project ${GCP_PROJECT}:
  - Cloud Run services   litellm, open-webui
  - Cloud SQL instance   ${GCP_SQL_INSTANCE}  (all databases and backups)
  - Agent Runtime        ${GCP_AGENT_ENGINE_RESOURCE:-<none>}
  - Secrets              secure-gpt-*
EOF
read -rp "Type the project id to confirm: " confirm
[ "$confirm" = "$GCP_PROJECT" ] || { echo "aborted"; exit 1; }

for svc in open-webui litellm; do
  gc run services delete "$svc" --region "$GCP_REGION" --quiet >/dev/null 2>&1 && say "deleted run/$svc" || true
done
if [ -n "${GCP_AGENT_ENGINE_RESOURCE:-}" ]; then
  python3 deploy/gcp/steps/delete_agent.py "$GCP_AGENT_ENGINE_RESOURCE" || true
fi
gc sql instances delete "$GCP_SQL_INSTANCE" --quiet >/dev/null 2>&1 && say "deleted sql/$GCP_SQL_INSTANCE" || true
for s in $(gc secrets list --filter='name:secure-gpt-' --format='value(name)' 2>/dev/null); do
  gc secrets delete "$s" --quiet >/dev/null 2>&1 && say "deleted secret/$s" || true
done
say "done"
