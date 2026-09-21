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

# On Agent Runtime the agent reaches Vertex directly with its service
# account: Cloud Run is IAM-protected here and the LiteLLM client cannot mint
# an identity token, and there is no sidecar slot on Agent Runtime to do it.
# See _model() in weather_time_agent/agent.py.
: "${GCP_LITELLM_URL:?litellm must be deployed first}"

cd adk-agent
agents-cli deploy \
  --project "$GCP_PROJECT" \
  --region "${GCP_AGENT_LOCATION:-$GCP_REGION}" \
  --service-name "$AGENT_RUNTIME_NAME" \
  --service-account "$SA_EMAIL" \
  --update-env-vars "AGENT_LLM_ROUTE=vertex,AGENT_MODEL=${ADK_AGENT_MODEL:-gemini-3.8-flash},GOOGLE_GENAI_USE_VERTEXAI=1,GOOGLE_CLOUD_PROJECT=${GCP_PROJECT},GOOGLE_CLOUD_LOCATION=${VERTEX_LOCATION:-eu}" \
  --no-confirm-project
cd "$ROOT"

resource=$(python3 -c '
import json, sys
try:
    d = json.load(open("adk-agent/deployment_metadata.json"))
except Exception:
    sys.exit("could not read adk-agent/deployment_metadata.json")
print(d.get("remote_agent_runtime_id") or d.get("remote_agent_engine_id") or "")')
[ -n "$resource" ] || { echo "  deploy finished but no resource name was recorded"; exit 1; }
put_env GCP_AGENT_ENGINE_RESOURCE "$resource"
say "deployed: $resource"
a2a=$(python3 -c 'import json;print(json.load(open("adk-agent/deployment_metadata.json")).get("is_a2a"))')
say "A2A enabled: ${a2a}"
