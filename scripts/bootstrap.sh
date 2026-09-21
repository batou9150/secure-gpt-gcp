#!/usr/bin/env bash
# Generates .env with fresh random secrets. Never overwrites an existing .env.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then
  echo ".env already exists — leaving it alone."
  echo "Delete it first if you want to regenerate secrets."
  exit 0
fi

[ -n "${GEMINI_API_KEY:-}" ] || read -rsp "Google AI Studio API key: " GEMINI_API_KEY </dev/tty && echo
[ -n "${ADMIN_EMAIL:-}"    ] || read -rp  "Admin email for Secure GPT: " ADMIN_EMAIL </dev/tty
[ -n "${ADMIN_NAME:-}"     ] || read -rp  "Admin display name: " ADMIN_NAME </dev/tty

gen()  { openssl rand -hex 32; }
pass() { openssl rand -base64 18 | tr -d '/+='; }

ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(pass)}"

sed \
  -e "s|^GEMINI_API_KEY=.*|GEMINI_API_KEY=${GEMINI_API_KEY}|" \
  -e "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=sk-$(gen)|" \
  -e "s|^LITELLM_SALT_KEY=.*|LITELLM_SALT_KEY=$(gen)|" \
  -e "s|^LITELLM_UI_PASSWORD=.*|LITELLM_UI_PASSWORD=$(pass)|" \
  -e "s|^OPENWEBUI_SECRET_KEY=.*|OPENWEBUI_SECRET_KEY=$(gen)|" \
  -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(gen)|" \
  -e "s|^ADMIN_NAME=.*|ADMIN_NAME=\"${ADMIN_NAME}\"|" \
  -e "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=${ADMIN_EMAIL}|" \
  -e "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ADMIN_PASSWORD}|" \
  .env.example > .env

chmod 600 .env
# Placeholder so the gateway's credential bind mount always resolves to a file.
mkdir -p secrets && [ -s secrets/gcp-credentials.json ] || echo '{}' > secrets/gcp-credentials.json
chmod 600 secrets/gcp-credentials.json
echo "Wrote .env (mode 600) with freshly generated secrets."
echo "Admin password: ${ADMIN_PASSWORD}   (also in .env; run 'make creds' anytime)"
