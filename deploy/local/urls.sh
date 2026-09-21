#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a; . ./.env; set +a
echo "  Secure GPT   http://${OPENWEBUI_BIND:-127.0.0.1:3000}"
echo "  LiteLLM UI   http://${LITELLM_BIND:-127.0.0.1:4000}/ui"
