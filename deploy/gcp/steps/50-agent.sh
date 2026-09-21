#!/usr/bin/env bash
# The ADK agent on Vertex AI Agent Runtime (formerly Agent Engine), A2A on.
#
# A2A is built into every ADK agent: the container serves the card and the
# JSON-RPC endpoint at /a2a/<app>, and Agent Runtime exposes them through its
# /api passthrough. There is no gcloud surface for Agent Runtime, so this uses
# agents-cli, which builds the same Dockerfile compose builds locally.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
step "Agent Runtime: ${AGENT_RUNTIME_NAME}"

command -v agents-cli >/dev/null || {
  echo "  agents-cli is not installed. Install it with:"
  echo "    uv tool install google-agents-cli"
  exit 1
}

GW="${GCP_LITELLM_URL:?litellm must be deployed first}"
AGENT_KEY="${ADK_AGENT_LITELLM_KEY:?run make provision once so the agent has a scoped key}"

cd adk-agent
agents-cli deploy \
  --project "$GCP_PROJECT" \
  --region "${GCP_AGENT_LOCATION:-$GCP_REGION}" \
  --service-name "$AGENT_RUNTIME_NAME" \
  --service-account "$SA_EMAIL" \
  --update-env-vars "LITELLM_BASE_URL=${GW}/v1,LITELLM_API_KEY=${AGENT_KEY},AGENT_MODEL=${ADK_AGENT_MODEL:-gemini-3.8-flash},APP_URL=${GW}" \
  --no-confirm-project
cd "$ROOT"

resource=$(python3 -c '
import json, sys
try:
    d = json.load(open("adk-agent/deployment_metadata.json"))
except Exception:
    sys.exit("could not read adk-agent/deployment_metadata.json")
print(d.get("remote_agent_engine_id") or d.get("resource_name") or "")')
[ -n "$resource" ] || { echo "  deploy finished but no resource name was recorded"; exit 1; }
put_env GCP_AGENT_ENGINE_RESOURCE "$resource"
say "deployed: $resource"
