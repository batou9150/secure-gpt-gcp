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
pick() { python3 -c 'import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
ms=d["model_list"]
if sys.argv[2]=="all":   print(",".join(sorted(m["model_name"] for m in ms)))
elif sys.argv[2]=="chat":print(",".join(sorted(m["model_name"] for m in ms if m["model_info"]["mode"]=="chat")))
elif sys.argv[2]=="primary":print(next(m["model_name"] for m in ms if m["model_info"]["mode"]=="chat"))
else:                    print(next(m["model_name"] for m in ms if m["model_info"]["mode"]=="embedding"))' "$CFG" "$1"; }
want=$(pick all)
want_chat=$(pick chat)
an_embed=$(pick embed)
# The PRIMARY chat model is the first one listed in the config, not the
# alphabetically first — that is the model users actually get by default.
a_chat=$(pick primary)

models=$(curl -s -m 15 -H "Authorization: Bearer $MK" "$GW/v1/models" \
  | python3 -c 'import sys,json;print(",".join(sorted(m["id"] for m in json.load(sys.stdin)["data"])))' 2>/dev/null)
[ "$models" = "$want" ] && ok "allow-list matches $(basename "$CFG"): $want" \
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
want = {m["model_name"]: m["model_info"]["display_name"]
        for m in yaml.safe_load(open(cfg))["model_list"]
        if m["model_info"].get("display_name")}
req = urllib.request.Request(ui + "/api/models", headers={"Authorization": "Bearer " + token})
got = {m["id"]: m.get("name") for m in json.load(urllib.request.urlopen(req, timeout=20))["data"]}
bad = [f"{k}: want {v!r} got {got.get(k)!r}" for k, v in want.items() if got.get(k) != v]
print("; ".join(bad))
PY
)
if [ -z "$dn_bad" ]; then
  ok "display names match the config ($(python3 -c '
import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
print(", ".join(m["model_info"]["display_name"] for m in d["model_list"] if m["model_info"].get("display_name")))' "$CFG"))"
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
