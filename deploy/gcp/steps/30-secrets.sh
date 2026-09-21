#!/usr/bin/env bash
# Everything sensitive goes to Secret Manager; nothing is passed as a plain
# Cloud Run env var. The LiteLLM config travels as a secret too, so the
# gateway image stays stock.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
step "Secrets"
printf '%s' "$LITELLM_MASTER_KEY"   | put_secret secure-gpt-litellm-master-key
printf '%s' "$LITELLM_SALT_KEY"     | put_secret secure-gpt-litellm-salt-key
printf '%s' "$LITELLM_UI_PASSWORD"  | put_secret secure-gpt-litellm-ui-password
printf '%s' "$OPENWEBUI_SECRET_KEY" | put_secret secure-gpt-openwebui-secret-key
printf '%s' "$POSTGRES_PASSWORD"    | put_secret secure-gpt-postgres-password
printf '%s' "${GEMINI_API_KEY:-unused-on-vertex}" | put_secret secure-gpt-gemini-api-key
# Always present so the service can mount it; empty disables Google sign-in.
printf '%s' "${GOOGLE_CLIENT_SECRET:-}" | put_secret secure-gpt-google-client-secret
# On Cloud Run the agent is not a neighbouring container: it lives on Agent
# Runtime behind the A2A auth sidecar, so the agent url is rewritten to the
# sidecar's localhost address before the config is stored.
python3 deploy/gcp/rewrite_agent_url.py "${LITELLM_CONFIG:-./litellm/config.vertex.yaml}" \
  | put_secret secure-gpt-litellm-config
say "7 secrets + the gateway config (agent url -> sidecar) stored"
