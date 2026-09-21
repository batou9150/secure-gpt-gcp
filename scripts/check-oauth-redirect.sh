#!/usr/bin/env bash
# Asks Google whether it accepts this client + redirect URI pair.
# Exits 0 once the URI is registered, 1 while it is not.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
uri="${1:-${GOOGLE_REDIRECT_URI:-http://localhost:3000/oauth/google/callback}}"
[ -n "${GOOGLE_CLIENT_ID:-}" ] || { echo "GOOGLE_CLIENT_ID is not set"; exit 2; }
enc=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$uri")
body=$(curl -s -L -m 25 \
  "https://accounts.google.com/o/oauth2/v2/auth?client_id=${GOOGLE_CLIENT_ID}&response_type=code&scope=openid%20email&redirect_uri=${enc}" || true)
if grep -q 'redirect_uri_mismatch' <<<"$body"; then
  echo "NOT REGISTERED  $uri"; exit 1
elif grep -qiE 'identifierId|Sign in|Choose an account' <<<"$body"; then
  echo "REGISTERED      $uri"; exit 0
else
  echo "UNCLEAR         $uri  $(grep -oE 'Error [0-9]+: [a-z_]+' <<<"$body" | head -1)"; exit 1
fi
