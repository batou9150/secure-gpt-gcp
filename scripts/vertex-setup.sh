#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Prepares the Vertex AI path: checks credentials, finds an EU location that
# actually serves the model, and installs the credential file the gateway
# mounts.
#
# Vertex is the option to pick when EU data residency matters: the request is
# pinned to a named location and authenticated with IAM rather than a key.
#
# Locations are probed EU-first and the `global` endpoint is never selected —
# it routes worldwide and would defeat the point.
#
# Usage:
#   ./scripts/vertex-setup.sh                      # use your gcloud ADC
#   ./scripts/vertex-setup.sh path/to/sa-key.json  # use a service account key
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

PROJECT="${VERTEX_PROJECT:-your-project-id}"
MODEL="gemini-3.8-flash"
EMBED="gemini-embedding-001"
DEST="secrets/gcp-credentials.json"
SRC="${1:-$HOME/.config/gcloud/application_default_credentials.json}"

command -v gcloud >/dev/null || { echo "gcloud is not installed."; exit 1; }

echo "== Vertex AI setup =="
echo "   project: $PROJECT"

if ! TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null | tr -d '\r\n') || [ -z "$TOKEN" ]; then
  cat <<'MSG'

   Your application-default credentials need refreshing. Run:

       gcloud auth application-default login

   then re-run this script. (In Claude Code, prefix it with `! ` to run it here.)
MSG
  exit 1
fi
echo "   credentials: OK"
[ -f "$SRC" ] || { echo "   credential file not found: $SRC"; exit 1; }

# `eu` is a multi-region served by the plain host; single regions get a
# <loc>-aiplatform host. Neither is the `global` endpoint, which we skip.
host_for() { [ "$1" = eu ] && echo aiplatform.googleapis.com || echo "$1-aiplatform.googleapis.com"; }

probe_chat() {
  curl -s -o /dev/null -w '%{http_code}' -m 40 -X POST \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -H "x-goog-user-project: $PROJECT" \
    "https://$(host_for "$1")/v1/projects/$PROJECT/locations/$1/publishers/google/models/$2:generateContent" \
    -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}],"generationConfig":{"maxOutputTokens":8}}'
}
probe_embed() {
  curl -s -o /dev/null -w '%{http_code}' -m 40 -X POST \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -H "x-goog-user-project: $PROJECT" \
    "https://$(host_for "$1")/v1/projects/$PROJECT/locations/$1/publishers/google/models/$2:predict" \
    -d '{"instances":[{"content":"hello"}]}'
}

echo
echo "   chat — probing EU locations for $MODEL"
CHAT_LOC=""
for LOC in eu europe-west1 europe-west4 europe-west9 europe-north1; do
  C=$(probe_chat "$LOC" "$MODEL")
  if [ "$C" = 200 ]; then printf '     %-16s serves it\n' "$LOC"; [ -n "$CHAT_LOC" ] || CHAT_LOC="$LOC"
  else printf '     %-16s no (HTTP %s)\n' "$LOC" "$C"; fi
done
[ -n "$CHAT_LOC" ] || { echo; echo "   No EU location serves $MODEL. Refusing to fall back to 'global'."; exit 1; }

# LiteLLM's embedding handler derives aiplatform.<loc>.rep.googleapis.com,
# which does not exist for the `eu` multi-region, so embeddings need a single
# EU region. Still the EU, just a narrower location.
echo
echo "   embeddings — probing single EU regions for $EMBED"
EMBED_LOC=""
for LOC in europe-west1 europe-west4 europe-west9 europe-north1; do
  C=$(probe_embed "$LOC" "$EMBED")
  if [ "$C" = 200 ]; then printf '     %-16s serves it\n' "$LOC"; [ -n "$EMBED_LOC" ] || EMBED_LOC="$LOC"
  else printf '     %-16s no (HTTP %s)\n' "$LOC" "$C"; fi
done
[ -n "$EMBED_LOC" ] || { echo; echo "   No EU region serves $EMBED."; exit 1; }

install -m 600 "$SRC" "$DEST"
python3 - "$CHAT_LOC" "$EMBED_LOC" <<'PY'
import sys, re
chat, emb = sys.argv[1], sys.argv[2]
s = open(".env").read()
s = re.sub(r'^VERTEX_LOCATION=.*$',       f'VERTEX_LOCATION={chat}', s, flags=re.M)
s = re.sub(r'^VERTEX_EMBED_LOCATION=.*$', f'VERTEX_EMBED_LOCATION={emb}', s, flags=re.M)
s = re.sub(r'^LITELLM_CONFIG=.*$', 'LITELLM_CONFIG=./litellm/config.vertex.yaml', s, flags=re.M)
open(".env", "w").write(s)
PY

echo
echo "   chat location:      $CHAT_LOC"
echo "   embedding location: $EMBED_LOC"
echo "   credentials:        $DEST (mode 600)"
echo "   provider:           Vertex AI, EU"
echo
echo "   Apply it:  docker compose up -d litellm && make provision && make smoke"
