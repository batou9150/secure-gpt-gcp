#!/usr/bin/env bash
# Configures "Sign in with Google" for Open WebUI.
#
# Google has no public API for creating a generic Web OAuth client, so that
# one step is manual. This prints exactly what to register, then stores the
# credentials for whichever targets you use.
#
#   ./scripts/google-oauth.sh            # show what to register, and status
#   ./scripts/google-oauth.sh <id> <secret>
#   ./scripts/google-oauth.sh --disable
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

LOCAL_URL="http://${OPENWEBUI_BIND:-127.0.0.1:3000}"
# Cloud Run gives a service two hostnames and either can be used, so both
# have to be registered or a redirect from the other one is rejected.
GCP_URLS=$(gcloud --project "${GCP_PROJECT:-}" run services describe open-webui \
  --region "${GCP_REGION:-europe-west1}" \
  --format='value(metadata.annotations."run.googleapis.com/urls")' 2>/dev/null \
  | tr -d '[]"' | tr ',' '\n' | grep -E '^https' || true)
# gcloud credentials expire under this org's reauth policy; fall back to what
# the deploy recorded so this still prints something usable.
[ -z "$GCP_URLS" ] && GCP_URLS="${GCP_OPENWEBUI_URL:-}"

put_env() {
  python3 - "$1" "$2" <<'PY'
import re, sys
name, value = sys.argv[1], sys.argv[2]
s = open(".env").read()
if re.search(rf'^{name}=', s, flags=re.M):
    s = re.sub(rf'^{name}=.*$', f'{name}={value}', s, flags=re.M)
else:
    s = s.rstrip("\n") + f"\n{name}={value}\n"
open(".env", "w").write(s)
PY
}

if [ "${1:-}" = "--disable" ]; then
  put_env GOOGLE_CLIENT_ID ""
  put_env GOOGLE_CLIENT_SECRET ""
  echo "  Google sign-in disabled. Re-run 'make up' to apply."
  exit 0
fi

if [ "${1:-}" = "--interactive" ] || [ "${1:-}" = "-i" ]; then
  # Reads the secret without echoing it, so it never lands in a shell history
  # or a transcript.
  read -rp  "Google OAuth client ID: " cid </dev/tty
  read -rsp "Google OAuth client secret: " csec </dev/tty; echo
  [ -n "$cid" ] && [ -n "$csec" ] || { echo "  both values are required"; exit 1; }
  put_env GOOGLE_CLIENT_ID "$cid"
  put_env GOOGLE_CLIENT_SECRET "$csec"
  chmod 600 .env
  echo "  stored in .env (mode 600)"
  echo "  apply with: make up"
  exit 0
fi

if [ $# -ge 2 ]; then
  put_env GOOGLE_CLIENT_ID "$1"
  put_env GOOGLE_CLIENT_SECRET "$2"
  chmod 600 .env
  echo "  stored in .env (mode 600)"
  echo "  apply with: make up"
  exit 0
fi

cat <<EOF
== Sign in with Google for Open WebUI ==

Google exposes no API for creating a Web OAuth client, so create it once at:

  https://console.cloud.google.com/auth/clients?project=${GCP_PROJECT:-<project>}

  Application type:  Web application
  Name:              Secure GPT

  Authorised redirect URIs — add every target you will use:
    ${LOCAL_URL}/oauth/google/callback
    http://localhost:3000/oauth/google/callback
EOF
for u in $GCP_URLS; do echo "    ${u}/oauth/google/callback"; done
[ -n "$GCP_URLS" ] && cat <<'EOF'

  Cloud Run serves a service on two hostnames. Add the other one too — the
  console's Service details page lists both next to "URL".
EOF
cat <<EOF

Then store the credentials:

  ./scripts/google-oauth.sh --interactive     # prompts, secret is not echoed
  make up

Only ${OAUTH_ALLOWED_DOMAINS:-<unset>} accounts are admitted (OAUTH_ALLOWED_DOMAINS).

-- current state --
EOF
if [ -n "${GOOGLE_CLIENT_ID:-}" ]; then
  echo "  client id:     ${GOOGLE_CLIENT_ID:0:24}…"
  echo "  client secret: $([ -n "${GOOGLE_CLIENT_SECRET:-}" ] && echo 'set' || echo 'MISSING')"
else
  echo "  not configured — Google sign-in is off, password login is used"
fi
