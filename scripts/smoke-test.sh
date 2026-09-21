#!/usr/bin/env bash
# End-to-end verification of the Secure GPT stack: function and containment.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

GW="http://${LITELLM_BIND:-127.0.0.1:4000}"
UI="http://${OPENWEBUI_BIND:-127.0.0.1:3000}"
MK="$LITELLM_MASTER_KEY"
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; echo "        $2"; fail=$((fail+1)); }

# One admin session reused by the checks below.
TOKEN=$(curl -s -m 20 -X POST "$UI/api/v1/auths/signin" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])' 2>/dev/null)

echo "== Secure GPT smoke test =="
echo "   config: $(basename "${LITELLM_CONFIG:-config.aistudio.yaml}")"
echo "-- gateway --"

code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$GW/health/liveliness")
[ "$code" = 200 ] && ok "gateway is live" || no "gateway is live" "HTTP $code"

code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$GW/v1/models")
[ "$code" = 401 ] && ok "unauthenticated request rejected (401)" \
                  || no "unauthenticated request rejected" "expected 401, got $code"

CFG="${LITELLM_CONFIG:-./litellm/config.aistudio.yaml}"
pick() { python3 -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
ms = d["model_list"]
agents = ["a2a/" + a["agent_name"] for a in (d.get("agents") or [])]
chat = [m["model_name"] for m in ms if m["model_info"]["mode"] == "chat"] + agents
what = sys.argv[2]
if what == "all":       print(",".join(sorted(m["model_name"] for m in ms) + sorted(agents)))
elif what == "chat":    print(",".join(sorted(chat)))
elif what == "primary": print(next(m["model_name"] for m in ms if m["model_info"]["mode"] == "chat"))
elif what == "agent":   print(agents[0] if agents else "")
elif what == "plain":   print(",".join(sorted(m["model_name"] for m in ms)))
else:                   print(next(m["model_name"] for m in ms if m["model_info"]["mode"] == "embedding"))' "$CFG" "$1"; }
want=$(pick plain)
want_chat=$(pick chat)
an_embed=$(pick embed)
# The PRIMARY chat model is the first one listed in the config, not the
# alphabetically first — that is the model users actually get by default.
a_chat=$(pick primary)

models=$(curl -s -m 15 -H "Authorization: Bearer $MK" "$GW/v1/models" \
  | python3 -c 'import sys,json;print(",".join(sorted(m["id"] for m in json.load(sys.stdin)["data"])))' 2>/dev/null)
# Agents are not in this list by design — LiteLLM adds them only for keys
# scoped to them, which the picker check below covers.
[ "$models" = "$want" ] && ok "allow-list matches $(basename "$CFG") model_list: $want" \
                        || no "allow-list" "config says [$want], gateway says [${models:-<none>}]"

body=$(curl -s -m 20 -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}' "$GW/v1/chat/completions")
echo "$body" | grep -qi 'invalid model\|not.*valid model\|model_list\|BadRequest' \
  && ok "model outside the allow-list refused" || no "model outside allow-list refused" "$(echo "$body"|head -c 200)"

echo "-- least privilege --"

[ -n "${OPENWEBUI_CHAT_KEY:-}" ] && [ "$OPENWEBUI_CHAT_KEY" != "$MK" ] \
  && ok "frontend uses a scoped key, not the master key" \
  || no "frontend key" "OPENWEBUI_CHAT_KEY missing or equals master key"

body=$(curl -s -m 20 -H "Authorization: Bearer $OPENWEBUI_CHAT_KEY" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$an_embed\",\"input\":\"x\"}" "$GW/v1/embeddings")
echo "$body" | grep -q 'key_model_access_denied' \
  && ok "chat key cannot reach the embedding model" || no "chat key scope" "$(echo "$body"|head -c 200)"

body=$(curl -s -m 20 -H "Authorization: Bearer $OPENWEBUI_EMBED_KEY" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$a_chat\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" "$GW/v1/chat/completions")
echo "$body" | grep -q 'key_model_access_denied' \
  && ok "embedding key cannot reach chat models" || no "embedding key scope" "$(echo "$body"|head -c 200)"

stored=$(curl -s -m 15 -H "Authorization: Bearer $TOKEN" "$UI/openai/config" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["OPENAI_API_KEYS"][0])' 2>/dev/null)
if [ -z "$stored" ]; then
  no "master key absent from OpenWebUI database" "could not read stored connection key"
elif [ "$stored" = "$MK" ]; then
  no "master key absent from OpenWebUI database" "OpenWebUI is storing the master key"
else
  ok "master key absent from OpenWebUI database (holds ${stored:0:9}…)"
fi

leak=""
docker compose exec -T open-webui sh -c 'env | grep -q "AIza"' && leak="AI Studio key in env"
docker compose exec -T open-webui sh -c '[ -e /app/gcp-credentials.json ]' && leak="${leak:+$leak; }GCP credentials mounted"
[ -z "$leak" ] && ok "provider credentials confined to the gateway" \
                || no "provider credentials confined to the gateway" "$leak"

if docker compose exec -T postgres sh -c 'timeout 5 wget -q -O- https://generativelanguage.googleapis.com >/dev/null 2>&1'; then
  no "database tier is network-isolated" "postgres reached the internet"
else
  ok "database tier is network-isolated (no egress)"
fi

echo "-- function --"

body=$(curl -s -m 90 -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$a_chat\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: PONG\"}]}" \
  "$GW/v1/chat/completions")
echo "$body" | grep -q 'PONG' && ok "chat completion via $a_chat" \
                              || no "chat completion" "$(echo "$body"|head -c 300)"

n=$(curl -s -m 60 -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$an_embed\",\"input\":\"hello\"}" "$GW/v1/embeddings" \
  | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"][0]["embedding"]))' 2>/dev/null)
[ "${n:-0}" -gt 100 ] 2>/dev/null && ok "embeddings return a ${n}-dim vector" || no "embeddings" "got ${n:-error}"

code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$UI/health")
[ "$code" = 200 ] && ok "OpenWebUI is serving" || no "OpenWebUI is serving" "HTTP $code"

picker=$(curl -s -m 20 -H "Authorization: Bearer $TOKEN" "$UI/api/models" \
  | python3 -c 'import sys,json;print(",".join(sorted(m["id"] for m in json.load(sys.stdin)["data"])))' 2>/dev/null)
[ "$picker" = "$want_chat" ] \
  && ok "chat picker offers exactly: $want_chat" \
  || no "chat picker" "expected [$want_chat], got [${picker:-error}]"

# Every model the frontend can see must also be callable with the frontend
# key — otherwise the picker offers something that 403s when selected.
unreachable=""
for m in ${picker//,/ }; do
  r=$(curl -s -m 90 -H "Authorization: Bearer $OPENWEBUI_CHAT_KEY" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}" \
      "$GW/v1/chat/completions")
  echo "$r" | grep -q 'key_model_access_denied' && unreachable="${unreachable:+$unreachable }$m"
done
[ -z "$unreachable" ] && ok "every model in the picker is callable by the frontend key" \
                      || no "picker/key scope mismatch" "not callable: $unreachable"

# Display names declared in the config must be what the UI actually shows.
dn_bad=$(python3 - "$CFG" "$UI" "$TOKEN" <<'PY'
import json, sys, urllib.request, yaml
cfg, ui, token = sys.argv[1], sys.argv[2], sys.argv[3]
cfgd = yaml.safe_load(open(cfg))
want = {m["model_name"]: m["model_info"]["display_name"]
        for m in cfgd["model_list"] if m["model_info"].get("display_name")}
for a in cfgd.get("agents") or []:
    want["a2a/" + a["agent_name"]] = (a.get("agent_card_params") or {}).get("name") or a["agent_name"]
req = urllib.request.Request(ui + "/api/models", headers={"Authorization": "Bearer " + token})
got = {m["id"]: m.get("name") for m in json.load(urllib.request.urlopen(req, timeout=20))["data"]}
bad = [f"{k}: want {v!r} got {got.get(k)!r}" for k, v in want.items() if got.get(k) != v]
print("; ".join(bad))
PY
)
if [ -z "$dn_bad" ]; then
  ok "display names match the config ($(python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
names = [m["model_info"]["display_name"] for m in d["model_list"] if m["model_info"].get("display_name")]
names += [(a.get("agent_card_params") or {}).get("name") or a["agent_name"] for a in (d.get("agents") or [])]
print(", ".join(names))' "$CFG"))"
else
  no "display names" "$dn_bad"
fi

# Image model, if the allow-list has one.
img=$(python3 -c '
import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
print(next((m["model_name"] for m in d["model_list"] if "image" in m["model_name"]), ""))' "$CFG")
if [ -n "$img" ]; then
  n=$(curl -s -m 300 -X POST "$UI/api/chat/completions" -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$img\",\"messages\":[{\"role\":\"user\",\"content\":\"A plain green square.\"}]}" \
      | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(len(d["choices"][0]["message"].get("images") or []))
except Exception: print(0)')
  [ "${n:-0}" -ge 1 ] 2>/dev/null && ok "image generation via $img returns an image" \
                                  || no "image generation via $img" "no image in response"
fi

reply=$(curl -s -m 120 -X POST "$UI/api/chat/completions" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$a_chat\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ROUNDTRIP\"}]}")
echo "$reply" | grep -q 'ROUNDTRIP' && ok "full round trip: OpenWebUI -> LiteLLM -> Gemini" \
                                    || no "full round trip" "$(echo "$reply"|head -c 300)"

# --- A2A agent ------------------------------------------------------------
agent_model=$(pick agent)

if [ -n "$agent_model" ]; then
  card=$(docker compose exec -T adk-agent python -c "
import urllib.request, json
d = json.load(urllib.request.urlopen('http://localhost:8080/.well-known/agent-card.json', timeout=10))
skills = {s['name'] for s in d.get('skills', [])}
print('ok' if {'get_weather', 'get_current_time'} <= skills else 'missing:' + ','.join(sorted(skills)))" 2>/dev/null | tr -d '\r')
  [ "$card" = ok ] && ok "A2A agent card advertises get_weather and get_current_time" \
                   || no "A2A agent card" "${card:-unreachable}"

  # OpenAI-style request in, A2A JSON-RPC to the agent, OpenAI-style out.
  rep=$(curl -s -m 240 -H "Authorization: Bearer $OPENWEBUI_CHAT_KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$agent_model\",\"messages\":[{\"role\":\"user\",\"content\":\"Weather and time in Paris?\"}]}" \
    "$GW/v1/chat/completions" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["choices"][0]["message"]["content"])
except Exception: print("")')
  echo "$rep" | grep -qi 'paris' && echo "$rep" | grep -qiE 'cloudy|°C' \
    && ok "A2A round trip: OpenAI in -> JSON-RPC -> agent tools -> OpenAI out" \
    || no "A2A round trip" "reply: $(echo "$rep" | head -c 200)"

  # Registered under the top-level `agents:` key, so LiteLLM also serves the
  # native A2A surface, not just the chat-completions bridge.
  cardname=$(curl -s -m 20 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    "$GW/a2a/${agent_model#a2a/}/.well-known/agent-card.json" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("name",""))
except Exception: print("")')
  [ -n "$cardname" ] && ok "LiteLLM serves the agent card (\"$cardname\")" \
                     || no "LiteLLM agent card" "no card at /a2a/${agent_model#a2a/}/.well-known/agent-card.json"

  # The agent-bound key (agent_id) is the one meant for direct A2A clients.
  akey_var="A2A_KEY_$(printf '%s' "${agent_model#a2a/}" | tr 'a-z-' 'A-Z_')"
  akey="${!akey_var:-}"
  rpc=$(curl -s -m 240 -X POST "$GW/a2a/${agent_model#a2a/}" \
    -H "x-litellm-api-key: Bearer $akey" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","messageId":"m1","parts":[{"kind":"text","text":"Weather in Tokyo?"}]}}}')
  echo "$rpc" | grep -qi 'tokyo' \
    && ok "native A2A JSON-RPC passthrough works (agent-bound key)" \
    || no "native A2A passthrough" "$(echo "$rpc" | head -c 200)"

  # The native endpoint authenticates a key but does not apply its model
  # allow-list, so every key that has no business there is route-pinned away.
  reachable=""
  for kv in OPENWEBUI_CHAT_KEY OPENWEBUI_EMBED_KEY ADK_AGENT_LITELLM_KEY; do
    kval="${!kv:-}"; [ -n "$kval" ] || continue
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 40 -X POST "$GW/a2a/${agent_model#a2a/}" \
      -H "x-litellm-api-key: Bearer $kval" -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","messageId":"m1","parts":[{"kind":"text","text":"hi"}]}}}')
    [ "$code" = 403 ] || [ "$code" = 401 ] || reachable="${reachable:+$reachable }$kv($code)"
  done
  [ -z "$reachable" ] \
    && ok "only the agent-bound key may use the native A2A endpoint" \
    || no "native A2A access control" "also reachable by: $reachable"

  # A bound key is what the LiteLLM Agents page counts; with none it shows
  # the agent as "Needs Setup".
  bound=$(curl -s -m 20 -H "Authorization: Bearer $LITELLM_MASTER_KEY" "$GW/v1/agents" \
    | python3 -c 'import sys, json
try:
    a = json.load(sys.stdin)[0]
    print(len(a.get("keys") or []))
except Exception:
    print(0)')
  [ "${bound:-0}" -ge 1 ] 2>/dev/null \
    && ok "agent has $bound bound key(s) — shows as Active, not Needs Setup" \
    || no "agent binding" "no key bound via agent_id; UI will show Needs Setup"

  # The agent reasons through the gateway, so its key must not be able to
  # reach an A2A model — otherwise it could call itself and recurse.
  body=$(curl -s -m 30 -H "Authorization: Bearer $ADK_AGENT_LITELLM_KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$agent_model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
    "$GW/v1/chat/completions")
  echo "$body" | grep -q 'key_model_access_denied' \
    && ok "agent key cannot invoke an A2A agent (no recursion)" \
    || no "agent recursion guard" "$(echo "$body" | head -c 200)"

  if docker compose exec -T adk-agent sh -c 'env | grep -q "AIza"' 2>/dev/null; then
    no "agent holds no provider credentials" "AI Studio key present in the agent container"
  elif docker compose exec -T adk-agent sh -c '[ -e /app/gcp-credentials.json ]' 2>/dev/null; then
    no "agent holds no provider credentials" "GCP credentials mounted into the agent"
  else
    ok "agent holds no provider credentials (only a scoped virtual key)"
  fi
fi

tmp=$(mktemp /tmp/sgpt-rag-XXXX.txt)
echo "The rollback window for project BLUE HERON is fifteen minutes and needs two approvers." > "$tmp"
FID=$(curl -s -m 180 -X POST "$UI/api/v1/files/" -H "Authorization: Bearer $TOKEN" -F "file=@$tmp" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])' 2>/dev/null)
rag=$(curl -s -m 180 -X POST "$UI/api/chat/completions" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$a_chat\",\"messages\":[{\"role\":\"user\",\"content\":\"How long is the rollback window?\"}],\"files\":[{\"type\":\"file\",\"id\":\"$FID\"}]}")
echo "$rag" | grep -qi 'fifteen\|15' && ok "RAG: upload, embed and retrieve" \
                                    || no "RAG" "$(echo "$rag"|head -c 300)"
rm -f "$tmp"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
