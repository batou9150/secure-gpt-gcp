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

# --- endpoints for the active target ----------------------------------------
# local: docker compose on this machine.
#
# gcp: both Cloud Run services are IAM-protected (this org forbids allUsers),
# and their APIs want their own bearer token in Authorization — which would
# collide with the platform identity token. `gcloud run services proxy` opens
# an authenticated local tunnel instead, so Authorization stays free for the
# application's own key and everything below is target-agnostic.
if [ "${TARGET:-local}" = gcp ]; then
  : "${GCP_LITELLM_URL:?litellm is not deployed yet — run: make up}"
  IN_CLOUD=1
  _proxy_pids=()
  _start_proxy() {  # _start_proxy <service> <local-port>
    gcloud --project "$GCP_PROJECT" run services proxy "$1" \
      --region "${GCP_REGION:-europe-west1}" --port "$2" >/dev/null 2>&1 &
    _proxy_pids+=($!)
    # curl does the waiting: retry through connection-refused while the
    # tunnel comes up. `|| true` because set -e is on and a refused
    # connection here is expected, not fatal.
    curl -s -o /dev/null --retry 40 --retry-delay 1 --retry-connrefused \
      --retry-all-errors -m 5 "http://127.0.0.1:$2/" || true
  }
  _stop_proxies() { for p in "${_proxy_pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
  trap _stop_proxies EXIT
  _start_proxy litellm 8401
  GW="http://127.0.0.1:8401"
  # What Open WebUI itself should use from inside its own container: the
  # auth-proxy sidecar, not the tunnel we use from this machine.
  OWUI_GATEWAY="http://localhost:4000/v1"
  # Open WebUI is deployed after the keys exist, so on the first pass it is
  # not there yet. Provision what we can and say so.
  if [ -z "${GCP_OPENWEBUI_URL:-}" ]; then
    UI=""
  elif [ "$(gcloud --project "$GCP_PROJECT" run services describe open-webui \
             --region "${GCP_REGION:-europe-west1}" \
             --format='value(metadata.annotations."run.googleapis.com/invoker-iam-disabled")' \
             2>/dev/null)" = "true" ]; then
    UI="$GCP_OPENWEBUI_URL"
  else
    _start_proxy open-webui 8301
    UI="http://127.0.0.1:8301"
  fi
else
  GW="http://${LITELLM_BIND:-127.0.0.1:4000}"
  UI="http://${OPENWEBUI_BIND:-127.0.0.1:3000}"
  OWUI_GATEWAY="http://litellm:4000/v1"   # the compose service name
  IN_CLOUD=0
fi

# Virtual keys live in each target's own database, so they are recorded under
# a per-target name: OPENWEBUI_CHAT_KEY for local, GCP_OPENWEBUI_CHAT_KEY for
# Cloud Run. Sharing one name would point each target at the other's keys.
KEY_PREFIX=""
[ "$IN_CLOUD" = 1 ] && KEY_PREFIX="GCP_"
_k() { local n="${KEY_PREFIX}$1"; echo "${!n:-}"; }

# The config file IS the allow-list; derive key scopes from it so the two
# cannot drift and so this works for whichever provider is selected.
CFG="${LITELLM_CONFIG:-./litellm/config.aistudio.yaml}"
# A registered agent is exposed by LiteLLM as the model id "a2a/<agent_name>";
# it is not (and need not be) in model_list.
models_of() {
  python3 -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
want = sys.argv[2]
plain = [m["model_name"] for m in d["model_list"] if m["model_info"]["mode"] == "chat"]
embed = [m["model_name"] for m in d["model_list"] if m["model_info"]["mode"] == "embedding"]
agents = ["a2a/" + a["agent_name"] for a in (d.get("agents") or [])]
out = {"chat": plain + agents,
       "embedding": embed,
       # What an agent itself may call. Excludes agents, so an agent cannot
       # invoke itself (or another) and recurse through the gateway.
       "agent_llm": plain}[want]
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
[ -n "$UI" ] && curl -s -o /dev/null --retry 60 --retry-delay 2 --retry-all-errors -m 10 "$UI/health" || true

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

mint() {  # mint ALIAS MODELS_JSON RPM PARALLEL [EXTRA_JSON] -> echoes key
  curl -s -m 30 -X POST "$GW/key/generate" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
    -d "{\"key_alias\":\"$1-$(date +%s)\",\"models\":[$2],\"rpm_limit\":$3,\"max_parallel_requests\":$4${5:+,$5}}" \
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

ensure_key() {  # ensure_key VARNAME ALIAS MODELS RPM PARALLEL LABEL [EXTRA_JSON]
  local var=$1 alias=$2 models=$3 rpm=$4 par=$5 label=$6 extra="${7:-}"
  local cur="${!var:-}"
  if key_valid "$cur"; then
    # Always push the desired shape rather than only on model drift: limits
    # and allowed_routes can change too, and /key/update is idempotent.
    local drift=""
    [ "$(scope_of "$cur")" = "$(plain "$models")" ] || drift=" (models re-scoped)"
    curl -s -o /dev/null -m 30 -X POST "$GW/key/update" \
      -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
      -d "{\"key\":\"$cur\",\"models\":[$models],\"rpm_limit\":$rpm,\"max_parallel_requests\":$par${extra:+,$extra}}"
    say "$label key: synced${drift}"
    return
  fi
  local k; k=$(mint "$alias" "$models" "$rpm" "$par" "$extra")
  put_env "$var" "$k"
  printf -v "$var" '%s' "$k"
  say "$label key: issued (${rpm} rpm, ${par} parallel)"
}

# Every virtual key that has no business reaching an agent is pinned away
# from the A2A routes. The native /a2a/{agent} endpoint authenticates a key
# but does NOT apply its model allow-list, so without this any valid key
# could invoke any registered agent.
CHAT_ROUTES='"allowed_routes":["/v1/models","/models","/v1/chat/completions","/chat/completions"]'
EMBED_ROUTES='"allowed_routes":["/v1/models","/models","/v1/embeddings","/embeddings"]'

ensure_key "${KEY_PREFIX}OPENWEBUI_CHAT_KEY"  open-webui-chat  "$CHAT_MODELS"  "$CHAT_RPM_LIMIT"  "$CHAT_PARALLEL"  chat "$CHAT_ROUTES"
ensure_key "${KEY_PREFIX}OPENWEBUI_EMBED_KEY" open-webui-embed "$EMBED_MODELS" "$EMBED_RPM_LIMIT" "$EMBED_PARALLEL" embedding "$EMBED_ROUTES"

# A key bound to the agent via agent_id. This is what the Agents page in the
# LiteLLM UI counts: with none, the agent shows "Needs Setup". It also gives
# the agent its own spend line, and is the key direct A2A clients should use.
AGENT_IDS=$(curl -s -m 20 -H "Authorization: Bearer $LITELLM_MASTER_KEY" "$GW/v1/agents" \
  | python3 -c 'import sys, json
try:
    print(" ".join(a["agent_name"] + "=" + a["agent_id"] for a in json.load(sys.stdin)))
except Exception:
    print("")')
for pair in $AGENT_IDS; do
  aname="${pair%%=*}"; aid="${pair##*=}"
  var="${KEY_PREFIX}A2A_KEY_$(printf '%s' "$aname" | tr 'a-z-' 'A-Z_')"
  cur="${!var:-}"
  if key_valid "$cur"; then
    say "agent key ($aname): reusing existing"
  else
    k=$(curl -s -m 30 -X POST "$GW/key/generate" \
      -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
      -d "{\"key_alias\":\"a2a-$aname-$(date +%s)\",\"agent_id\":\"$aid\",\"models\":[\"$aname\"]}" \
      | jqp 'd.get("key","")')
    if [ -n "$k" ]; then
      put_env "$var" "$k"; printf -v "$var" '%s' "$k"
      say "agent key ($aname): issued and bound to agent_id"
    else
      say "agent key ($aname): could not be issued"
    fi
  fi
done

# The ADK agent calls the gateway for its own reasoning. Its key deliberately
# excludes A2A models so it cannot call itself back through the gateway.
if [ -n "$AGENT_LLM_MODELS" ]; then
  before="$(_k ADK_AGENT_LITELLM_KEY)"
  # Model scoping alone is not enough: the native /a2a/{agent} endpoint
  # authenticates the key but does not apply the model allow-list, so the
  # agent's own key could still reach an agent there. allowed_routes is an
  # allowlist enforced for every route, so pin the key to the chat route.
  ensure_key "${KEY_PREFIX}ADK_AGENT_LITELLM_KEY" adk-agent "$AGENT_LLM_MODELS" \
             "${AGENT_RPM_LIMIT:-300}" "${AGENT_PARALLEL:-10}" "ADK agent" \
             '"allowed_routes":["/v1/chat/completions","/chat/completions"]' 
  if [ "$before" != "$(_k ADK_AGENT_LITELLM_KEY)" ]; then
    if [ "$IN_CLOUD" = 0 ]; then
      docker compose up -d adk-agent >/dev/null 2>&1 || true
      say "ADK agent: restarted with its new key"
    else
      say "ADK agent: re-run 'make up' to redeploy it with the new key"
    fi
  fi
fi

if [ -z "$UI" ]; then
  say "Open WebUI not deployed yet — keys are provisioned; re-run after it is up"
  echo
  echo "Provisioned (gateway only)."
  exit 0
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
       \"OPENAI_API_BASE_URLS\":[\"$OWUI_GATEWAY\"],
       \"OPENAI_API_KEYS\":[\"$(_k OPENWEBUI_CHAT_KEY)\"],
       \"OPENAI_API_CONFIGS\":{\"0\":{\"enable\":true,\"model_ids\":[$CHAT_MODELS]}}}"
say "connection: LiteLLM only, chat models only, scoped key"

curl -s -o /dev/null -m 60 -X POST "$UI/api/v1/retrieval/embedding/update" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"RAG_EMBEDDING_ENGINE\":\"openai\",
       \"RAG_EMBEDDING_MODEL\":\"${EMBEDDING_MODEL:-gemini-embedding-001}\",
       \"RAG_EMBEDDING_BATCH_SIZE\":16,
       \"RAG_EMBEDDING_CONCURRENT_REQUESTS\":4,
       \"openai_config\":{\"url\":\"$OWUI_GATEWAY\",\"key\":\"$(_k OPENWEBUI_EMBED_KEY)\"}}"
say "RAG: embeddings via LiteLLM on the separate embedding key"

# Display names. An entry whose id equals the base model id renames that model
# in place rather than adding a duplicate to the picker. Declared as
# model_info.display_name in the config file, so that stays the source of truth.
python3 - "$CFG" "$UI" "$TOKEN" <<'PY'
import json, sys, urllib.request, urllib.error, yaml

cfg, ui, token = sys.argv[1], sys.argv[2], sys.argv[3]
cfgd = yaml.safe_load(open(cfg))
wanted = [(m["model_name"], m["model_info"]["display_name"],
           m["model_info"].get("supports_native_streaming", True))
          for m in cfgd["model_list"] if m["model_info"].get("display_name")]
# Agents are exposed as "a2a/<name>"; their label is agent_card_params.name.
# The chat bridge cannot stream (see the config), so mark them non-streaming.
for a in cfgd.get("agents") or []:
    label = (a.get("agent_card_params") or {}).get("name") or a["agent_name"]
    wanted.append(("a2a/" + a["agent_name"], label, False))

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
    # LiteLLM's A2A -> OpenAI chat bridge returns an empty body for a
    # streamed reply, so models declaring supports_native_streaming: false
    # are marked non-streaming here and Open WebUI requests them without
    # streaming.
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
