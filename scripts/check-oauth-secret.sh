#!/usr/bin/env bash
# Asks Google whether this client_id + client_secret pair is valid.
#
# A deliberately fake authorisation code is sent: Google rejects a bad secret
# with invalid_client before it ever looks at the code, and answers
# invalid_grant once the credentials check out. No real code is consumed.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
[ -n "${GOOGLE_CLIENT_ID:-}" ] || { echo "GOOGLE_CLIENT_ID is not set"; exit 2; }
[ -n "${GOOGLE_CLIENT_SECRET:-}" ] || { echo "GOOGLE_CLIENT_SECRET is not set"; exit 2; }
python3 - <<'PY'
import json, os, sys, urllib.parse, urllib.request
data = urllib.parse.urlencode({
    "code": "4/0Aprobe-not-a-real-code",
    "client_id": os.environ["GOOGLE_CLIENT_ID"],
    "client_secret": os.environ["GOOGLE_CLIENT_SECRET"],
    "redirect_uri": os.environ.get("GOOGLE_REDIRECT_URI", "http://localhost:3000/oauth/google/callback"),
    "grant_type": "authorization_code"}).encode()
try:
    urllib.request.urlopen(urllib.request.Request(
        "https://oauth2.googleapis.com/token", data=data), timeout=25)
    print("UNEXPECTED  Google accepted a fake code"); sys.exit(1)
except urllib.error.HTTPError as e:
    err = json.loads(e.read()).get("error", "?")
if err == "invalid_grant":
    print("VALID       client id and secret are accepted by Google"); sys.exit(0)
if err == "invalid_client":
    print("INVALID     Google rejects this client id / secret pair"); sys.exit(1)
print(f"UNCLEAR     {err}"); sys.exit(1)
PY
