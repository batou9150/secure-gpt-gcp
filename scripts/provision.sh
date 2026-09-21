#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Idempotent post-start provisioning.
#
#   1. Issues two scoped LiteLLM virtual keys (chat, embeddings) so that bulk
#      document indexing cannot exhaust the interactive chat budget.
#   2. Creates the OpenWebUI admin account on first run.
#   3. Pushes connection + RAG settings into OpenWebUI.
#
# OpenWebUI treats most of its settings as "persistent config": the value is
# copied into its database on first boot and environment variables are ignored
# from then on. That is why these have to be applied over the API.
#
# Safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

GW="http://${LITELLM_BIND:-127.0.0.1:4000}"
UI="http://${OPENWEBUI_BIND:-127.0.0.1:3000}"
# The config file IS the allow-list; derive key scopes from it so the two
# cannot drift and so this works for whichever provider is selected.
CFG="${LITELLM_CONFIG:-./litellm/config.aistudio.yaml}"
models_of() {
  python3 -c 'import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
want=sys.argv[2]
out=[]
for m in d["model_list"]:
    mode=m["model_info"]["mode"]
    is_a2a=str(m["litellm_params"]["model"]).startswith("a2a/")
    if want=="chat" and mode=="chat": out.append(m["model_name"])
    elif want=="embedding" and mode=="embedding": out.append(m["model_name"])
    # chat models an agent may call: excludes A2A agents, so an agent cannot
    # invoke itself (or another agent) and recurse through the gateway.
    elif want=="agent_llm" and mode=="chat" and not is_a2a: out.append(m["model_name"])
print(",".join("\"%s\"" % n for n in out))' "$CFG" "$1"
}
CHAT_MODELS=$(models_of chat)
EMBED_MODELS=$(models_of embedding)
AGENT_LLM_MODELS=$(models_of agent_llm)
[ -n "$CHAT_MODELS" ] && [ -n "$EMBED_MODELS" ] || { echo "  ERROR: could not read the allow-list from $CFG"; exit 1; }

say() { printf '  %s\n' "$*"; }

say "config: ${LITELLM_CONFIG:-./litellm/config.aistudio.yaml}"

jqp() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

curl -s -o /dev/null --retry 60 --retry-delay 2 --retry-all-errors -m 10 "$GW/health/liveliness"
curl -s -o /dev/null --retry 60 --retry-delay 2 --retry-all-errors -m 10 "$UI/health"

# --- 1. virtual keys -------------------------------------------------------
key_valid() {
  [ -n "${1:-}" ] || return 1
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
      "$GW/key/info?key=$1")" = 200 ]
}

put_env() {  # put_env NAME VALUE
  if grep -q "^$1=" .env; then
    python3 - "$1" "$2" <<'PY'
import sys,re
n,v=sys.argv[1],sys.argv[2]
s=open(".env").read()
open(".env","w").write(re.sub(rf'^{n}=.*$', f'{n}={v}', s, flags=re.M))
PY
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}

mint() {  # mint ALIAS MODELS_JSON RPM PARALLEL  -> echoes key
  curl -s -m 30 -X POST "$GW/key/generate" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
    -d "{\"key_alias\":\"$1-$(date +%s)\",\"models\":[$2],\"rpm_limit\":$3,\"max_parallel_requests\":$4}" \
    | jqp 'd["key"]'
}

# A key that exists but whose scope no longer matches the allow-list is worse
# than no key: the UI would offer models the key cannot call. Reconcile it.
# Current models on a key, as a sorted plain-name CSV.
scope_of() {
  curl -s -m 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" "$GW/key/info?key=$1" \
    | python3 -c 'import sys,json
d=json.load(sys.stdin)
print(",".join(sorted(d["info"]["models"] or [])))' 2>/dev/null
}

# Turn the JSON-ish list ("a","b") into a sorted plain-name CSV for comparison.
plain() { printf '%s' "$1" | tr -d \" | tr ',' '\n' | sort | paste -sd, -; }

ensure_key() {  # ensure_key VARNAME ALIAS MODELS RPM PARALLEL LABEL
  local var=$1 alias=$2 models=$3 rpm=$4 par=$5 label=$6
  local cur="${!var:-}"
  if key_valid "$cur"; then
    if [ "$(scope_of "$cur")" = "$(plain "$models")" ]; then
      say "$label key: reusing existing"
      return
    fi
    curl -s -o /dev/null -m 30 -X POST "$GW/key/update" \
      -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
      -d "{\"key\":\"$cur\",\"models\":[$models],\"rpm_limit\":$rpm,\"max_parallel_requests\":$par}"
    say "$label key: scope re-synced to the allow-list"
    return
  fi
  local k; k=$(mint "$alias" "$models" "$rpm" "$par")
  put_env "$var" "$k"
  printf -v "$var" '%s' "$k"
  say "$label key: issued (${rpm} rpm, ${par} parallel)"
}

ensure_key OPENWEBUI_CHAT_KEY  open-webui-chat  "$CHAT_MODELS"  "$CHAT_RPM_LIMIT"  "$CHAT_PARALLEL"  chat
ensure_key OPENWEBUI_EMBED_KEY open-webui-embed "$EMBED_MODELS" "$EMBED_RPM_LIMIT" "$EMBED_PARALLEL" embedding

# The ADK agent calls the gateway for its own reasoning. Its key deliberately
# excludes A2A models so it cannot call itself back through the gateway.
if [ -n "$AGENT_LLM_MODELS" ]; then
  before="${ADK_AGENT_LITELLM_KEY:-}"
  ensure_key ADK_AGENT_LITELLM_KEY adk-agent "$AGENT_LLM_MODELS" \
             "${AGENT_RPM_LIMIT:-300}" "${AGENT_PARALLEL:-10}" "ADK agent"
  if [ "$before" != "$ADK_AGENT_LITELLM_KEY" ]; then
    docker compose up -d adk-agent >/dev/null 2>&1 || true
    say "ADK agent: restarted with its new key"
  fi
fi

# --- 2. admin account ------------------------------------------------------
TOKEN=$(curl -s -m 30 -X POST "$UI/api/v1/auths/signin" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" | jqp 'd.get("token","")' 2>/dev/null || true)

if [ -z "${TOKEN:-}" ]; then
  TOKEN=$(curl -s -m 30 -X POST "$UI/api/v1/auths/signup" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$ADMIN_NAME\",\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" \
    | jqp 'd.get("token","")')
  [ -n "$TOKEN" ] || { echo "  ERROR: could not create or sign in the admin account"; exit 1; }
  say "admin account: created ($ADMIN_EMAIL)"
else
  say "admin account: already exists ($ADMIN_EMAIL)"
fi

# --- 3. OpenWebUI settings -------------------------------------------------
curl -s -o /dev/null -m 30 -X POST "$UI/openai/config/update" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"ENABLE_OPENAI_API\":true,
       \"OPENAI_API_BASE_URLS\":[\"http://litellm:4000/v1\"],
       \"OPENAI_API_KEYS\":[\"$OPENWEBUI_CHAT_KEY\"],
       \"OPENAI_API_CONFIGS\":{\"0\":{\"enable\":true,\"model_ids\":[$CHAT_MODELS]}}}"
say "connection: LiteLLM only, chat models only, scoped key"

curl -s -o /dev/null -m 60 -X POST "$UI/api/v1/retrieval/embedding/update" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"RAG_EMBEDDING_ENGINE\":\"openai\",
       \"RAG_EMBEDDING_MODEL\":\"${EMBEDDING_MODEL:-gemini-embedding-001}\",
       \"RAG_EMBEDDING_BATCH_SIZE\":16,
       \"RAG_EMBEDDING_CONCURRENT_REQUESTS\":4,
       \"openai_config\":{\"url\":\"http://litellm:4000/v1\",\"key\":\"$OPENWEBUI_EMBED_KEY\"}}"
say "RAG: embeddings via LiteLLM on the separate embedding key"

# Display names. An entry whose id equals the base model id renames that model
# in place rather than adding a duplicate to the picker. Declared as
# model_info.display_name in the config file, so that stays the source of truth.
python3 - "$CFG" "$UI" "$TOKEN" <<'PY'
import json, sys, urllib.request, urllib.error, yaml

cfg, ui, token = sys.argv[1], sys.argv[2], sys.argv[3]
models = yaml.safe_load(open(cfg))["model_list"]
wanted = [(m["model_name"], m["model_info"]["display_name"],
           m["model_info"].get("supports_native_streaming", True))
          for m in models if m["model_info"].get("display_name")]

def call(path, payload):
    req = urllib.request.Request(
        ui + path, data=json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:200]

for mid, name, native_stream in wanted:
    # LiteLLM's A2A provider does not perform the upstream call when
    # stream=true (it returns only a terminal chunk), so models declaring
    # supports_native_streaming: false are marked non-streaming here and
    # Open WebUI requests them without streaming.
    params = {} if native_stream else {"stream_response": False}
    body = {"id": mid, "name": name, "base_model_id": None,
            "meta": {"description": None}, "params": params, "is_active": True}
    code, _ = call("/api/v1/models/create", body)
    if code != 200:
        code, _ = call("/api/v1/models/model/update?id=" + urllib.parse.quote(mid), body)
    note = "" if native_stream else " [non-streaming]"
    print("  display name: %-24s -> %r%s%s" % (
        mid, name, note, "" if code == 200 else " (FAILED %s)" % code))
PY

echo
echo "Provisioned. Sign in at $UI"
