#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ui=$(run_url open-webui || true)
gw=$(run_url litellm || true)
echo "  Secure GPT   ${ui:-<not deployed>}"
echo "  LiteLLM UI   ${gw:+$gw/ui}"
echo "  Agent        ${GCP_AGENT_ENGINE_RESOURCE:-<not deployed>}"
echo "  Cloud SQL    ${SQL_CONN}"
