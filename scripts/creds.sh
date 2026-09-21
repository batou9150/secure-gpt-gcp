#!/usr/bin/env bash
# Prints admin credentials and the URLs for the active target.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
TARGET="${TARGET:-local}"

if [ "$TARGET" = gcp ]; then
  ui="${GCP_OPENWEBUI_URL:-<not deployed yet — run make up>}"
  gw="${GCP_LITELLM_URL:-<not deployed yet>}"
else
  ui="http://${OPENWEBUI_BIND:-127.0.0.1:3000}"
  gw="http://${LITELLM_BIND:-127.0.0.1:4000}"
fi

echo "Secure GPT  $ui"
echo "  email     ${ADMIN_EMAIL}"
echo "  password  ${ADMIN_PASSWORD}"
echo "LiteLLM UI  ${gw}/ui"
echo "  username  admin"
echo "  password  ${LITELLM_UI_PASSWORD}"
