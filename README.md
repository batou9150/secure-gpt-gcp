# Secure GPT

A self-hosted ChatGPT-style assistant: **OpenWebUI** for the chat interface,
**LiteLLM** as a policy gateway, **Gemini 3.8 Flash** as the model. Everything
runs in Docker on one host.

Two providers are wired and interchangeable:

| | `make use-vertex` (**default**) | `make use-aistudio` |
|---|---|---|
| Endpoint | Vertex AI, `eu` multi-region | Google AI Studio, **global** |
| Auth | IAM (ADC or service account) | static API key |
| EU residency | **yes** | no |
| Setup | `gcloud auth application-default login` | an API key |

The stack ships on **Vertex AI in the EU**: chat on the `eu` multi-region,
embeddings on `europe-west1`. `make provider` shows which is active.

### Why two locations

`gemini-3.8-flash` is served by the `eu` **multi-region**, not by any single
EU region — `europe-west1` and friends currently offer only the Gemini 2.5
family. Chat therefore targets `eu`.

Embeddings cannot use `eu`: LiteLLM's embedding handler derives the hostname
as `aiplatform.<location>.rep.googleapis.com`, which does not exist for a
multi-region, and it ignores an `api_base` override there. (Its chat handler
builds the correct host.) So embeddings target `europe-west1`, which serves
`gemini-embedding-001` fine. Both locations are in the EU, so residency
holds either way. Revisit if LiteLLM fixes the multi-region embedding case.

Note also that `eu-aiplatform.googleapis.com` does not exist — the `eu`
multi-region is served by the plain `aiplatform.googleapis.com` host.

```
  browser                  docker                                    internet
  ───────                  ──────                                    ────────
                  ┌────────────────────────────────────────┐
  :3000 ─────────►│  open-webui      chat UI, users, RAG    │
                  │      │                                  │
                  │      │ scoped virtual keys              │
                  │      ▼                                  │
  :4000 ─────────►│  litellm    allow-list, quotas, spend,  │──────► Vertex AI
   (admin)        │      │      redaction, A2A gateway      │        (EU)
                  │      │ ▲                                │
                  │ A2A  │ │ its own LLM calls come back    │
                  │ JSON │ │ through the gateway            │
                  │ -RPC ▼ │                                │
                  │  adk-agent   weather + time tools       │
                  │                                         │
                  │  postgres  redis   ← no egress          │
                  └────────────────────────────────────────┘
```

Only `litellm` holds the Gemini API key, and only `litellm` and `open-webui`
can reach the internet. `postgres` and `redis` sit on an `internal: true`
Docker network with no route off the host.

## The demo agent

`adk-agent` is a small [ADK](https://adk.dev) agent with two tools,
`get_weather` and `get_current_time`, for a handful of cities. It is served
over the **A2A protocol** and appears in the model picker as
**Weather & Time Agent**.

LiteLLM is the A2A gateway. Open WebUI sends an ordinary OpenAI-style
`/v1/chat/completions` request naming the model `weather-time-agent`; LiteLLM
maps it to A2A JSON-RPC (`message/send`) against the agent, and translates
the reply back:

```
open-webui ──OpenAI /v1/chat/completions──► litellm ──A2A JSON-RPC──► adk-agent
                                                                          │
                            gemini-3.8-flash on Vertex EU ◄── litellm ◄───┘
```

The agent holds **no Google credentials**. Its own reasoning calls go back out
through the gateway on a virtual key that is scoped to the plain chat models
and deliberately excludes A2A models, so an agent cannot invoke itself and
recurse. `make smoke` asserts that.

### The agent is registered twice, on purpose

An A2A agent needs **both** entries, and they do different jobs.

`agents:` (top level) registers the agent with the proxy. That is what gives
the native A2A surface and an agent identity that keys and spend attach to:

```
POST /a2a/weather-time-agent                              JSON-RPC passthrough
GET  /a2a/weather-time-agent/.well-known/agent-card.json  discovery
POST /v1/a2a/discover                                     admin only
```

`model_list` bridges that agent to `/v1/chat/completions` so Open WebUI can
treat it as a model. **This is required** — registering under `agents:` alone
does *not* expose the agent as a model; without the `model_list` entry it
vanishes from `/v1/models` and a chat call returns *400 Invalid model name*.
So seeing `a2a/weather-time-agent` in the models list is expected, not
duplication.

**Keep `api_base` on the model_list entry.** Without it the bridge resolves
the address from the registry's agent card — whose `url` is LiteLLM's own
proxy endpoint — so the call loops back into the proxy instead of reaching
the agent. That failure is quiet: you get a fluent, plausible answer from a
plain LLM with no tool call.

### "Needs Setup" in the Agents page

The LiteLLM UI marks an agent **Active** only when at least one virtual key
is bound to it through the key's `agent_id` column; otherwise it shows
**Needs Setup**. That binding is separate from `object_permission.agents`,
which is about *permission* rather than ownership. `provision.sh` issues one
`agent_id`-bound key per registered agent, which also gives the agent its own
spend line and is the key direct A2A clients should use.

### Agent access control

Authenticate the native endpoints with `x-litellm-api-key: Bearer <key>`,
which LiteLLM prefers over `Authorization` when the inbound header might
carry a token meant for the agent itself.

**The native endpoint does not apply a key's model allow-list.** It
authenticates the key, but the `models` scope that governs
`/v1/chat/completions` is not checked there — so by default *any* valid
virtual key can invoke *any* registered agent over `/a2a/{agent}`, including
keys that were deliberately scoped away from it. `provision.sh` therefore
pins every other key with `allowed_routes`, which *is* enforced on every
route, leaving the agent-bound key as the only one that can use it. Open
WebUI is unaffected: it reaches the agent through the chat bridge, never
through `/a2a/`. `make smoke` asserts the 403s.

**Streaming.** The native passthrough above streams correctly. The
chat-completions *bridge* does not: it calls the agent with `message/stream`
and the agent returns a valid SSE stream, but the bridge emits only a
terminal chunk, so the client sees an empty message. Non-streaming is
correct. The model therefore declares `supports_native_streaming: false` and
`provision.sh` sets `stream_response: false` on its Open WebUI entry, so the
answer arrives in one go rather than token by token. Remove both once
upstream fixes the bridge.

### Adding tools

Edit `adk-agent/weather_time_agent/agent.py` — a plain Python function with a
docstring becomes a tool. Then:

```sh
docker compose up -d --build adk-agent && make smoke
```

## Quick start

```sh
make bootstrap    # generates .env with random secrets, prompts for your API key
make up           # starts the stack and provisions it
make creds        # shows your admin login
make smoke        # 16 end-to-end checks
```

Then open <http://localhost:3000>.

## What "secure" means here

Concretely, the controls that are in place and verified by `make smoke`:

| Control | How |
|---|---|
| Model allow-list | the active config's `model_list` is the only reachable set. `gpt-4o` and friends are refused at the gateway. |
| No key sprawl | `GEMINI_API_KEY` exists only in the `litellm` container. OpenWebUI never sees it. |
| Least privilege | OpenWebUI holds two *scoped virtual keys*, not the master key. The chat key cannot call embeddings; the embedding key cannot call chat. `provision.sh` re-syncs a key whose scope has drifted from the allow-list, so the picker can never offer a model the key cannot call. |
| Workload isolation | Chat and bulk document indexing have separate keys and separate concurrency budgets, so uploading a large PDF cannot starve other people's chat. |
| Network segmentation | Postgres and Redis have no internet route. |
| Local-only binding | Ports bind to `127.0.0.1`, not `0.0.0.0`. |
| No prompt content in gateway logs | `turn_off_message_logging: true`, `store_prompts_in_spend_logs: false`. Token counts and spend are still recorded. |
| No response cache | Redis caching is off, so prompts are not held in Redis. |
| Approval-gated signup | `DEFAULT_USER_ROLE=pending` — the first account is admin, every later signup waits for approval. |
| Admins cannot read chats | `ENABLE_ADMIN_CHAT_ACCESS=False`. |
| No third-party egress from the UI | Web search, image generation, community sharing, external STT and direct user-defined connections are all disabled. |
| Telemetry off | Across OpenWebUI, LiteLLM and Scarf. |
| Agents are credential-free | The ADK agent gets a scoped virtual key, never a Google credential. |
| Agents cannot recurse | The agent's key excludes A2A models *and* is route-pinned to the chat route, closing the native `/a2a/{agent}` path too. |
| Agent endpoints are not open | The native `/a2a/{agent}` route ignores a key's model allow-list, so every key except the agent-bound one is pinned away from it. |

### Limits you should know about

These are real and deliberate; decide whether they matter for your use.

- **Residency covers the model call, not everything.** Chat and embeddings
  stay in the EU. Chat history lives in your local Postgres, which is on your
  host — that is where the rest of the data sits.
- **AI Studio is a fallback, not an equal.** `make use-aistudio` switches to
  a global endpoint with no residency guarantee, and on its *free* tier
  Google may use prompts to improve its products. Use a billed project if you
  switch. Neither caveat applies to the Vertex default.
- **Chat history is stored in plaintext in Postgres.** The gateway does not
  log prompts, but OpenWebUI is a chat app: it keeps conversations so users
  can return to them. Anyone with database access can read them. Encrypt the
  volume if that matters.
- **Rate limits are per-key, not per-user.** All users share the frontend
  keys, so `CHAT_RPM_LIMIT` is a total ceiling, not a fair-share quota. For
  per-user budgets, enable LiteLLM end-user tracking on the `user` field
  OpenWebUI already sends.
- **No TLS.** Fine for `127.0.0.1`. Put it behind a reverse proxy with a
  certificate before exposing it, and set `WEBUI_SESSION_COOKIE_SECURE=True`.

### Switching to Vertex AI for EU residency

This is the default, but if you need to re-run it (credentials expired, or a
new model reached the EU):

```sh
gcloud auth application-default login   # interactive, once
make use-vertex                         # probes EU locations, installs creds
docker compose up -d litellm && make provision && make smoke
```

`scripts/vertex-setup.sh` probes `eu` and the single EU regions for both the
chat and embedding models, writes the working locations into
`VERTEX_LOCATION` / `VERTEX_EMBED_LOCATION`, copies your credentials to
`secrets/gcp-credentials.json` (mode 600) and selects
`litellm/config.vertex.yaml`.

It deliberately **never selects the `global` endpoint**. Gemini releases
often reach `global` first, and silently using it would give you the
appearance of EU residency without the substance. If no EU location serves
the model, the script says so and stops.

To use a service account instead of your own credentials:

```sh
make use-vertex ARGS=path/to/sa-key.json   # or: ./scripts/vertex-setup.sh path/to/sa-key.json
```

Go back with `make use-aistudio`.

## Operations

```sh
make ps         # service status
make logs       # tail logs
make provision  # re-apply keys and OpenWebUI settings (idempotent)
make smoke      # run the checks
make down       # stop, keep data
make nuke       # stop and delete all data
```

The LiteLLM admin UI (spend, keys, budgets) is at <http://localhost:4000/ui>,
username `admin`, password from `make creds`.

## Configuration

Everything lives in `.env` (gitignored, mode 600). `.env.example` documents
every field. The files that matter:

| Path | Purpose |
|---|---|
| `docker-compose.yml` | services, networks, all OpenWebUI settings |
| `adk-agent/` | the demo ADK agent served over A2A |
| `litellm/config.vertex.yaml` | allow-list and policy, Vertex AI EU (default) |
| `litellm/config.aistudio.yaml` | allow-list and policy, AI Studio |
| `scripts/provision.sh` | issues scoped keys, creates admin, applies UI settings |
| `scripts/vertex-setup.sh` | region probe and credential install for Vertex |
| `scripts/smoke-test.sh` | end-to-end verification |

### The persistent-config gotcha

OpenWebUI copies most environment variables into its database on **first
boot** and ignores the environment from then on. Changing
`OPENAI_API_CONFIGS` or the RAG settings in `docker-compose.yml` after the
first start has no effect. That is why `scripts/provision.sh` applies those
over the API instead, and why it is safe to re-run.

## Adding a model

Add it to `model_list` in the config file for your provider
(`litellm/config.vertex.yaml` or `litellm/config.aistudio.yaml`), with a
`model_info.mode` of `chat` or `embedding`. That file is the single source of
truth: `provision.sh` derives the virtual-key scopes from it and
`smoke-test.sh` derives its expectations from it, so nothing else needs
editing. The first `chat` entry is treated as the primary model.

### Display names

`model_info.display_name` controls what users see in the model picker. The
model keeps its real id everywhere else, so the allow-list, the key scopes
and the logs all stay auditable:

```yaml
  - model_name: gemini-3.1-flash-image
    litellm_params:
      model: vertex_ai/gemini-3.1-flash-image
      ...
    model_info:
      mode: chat
      display_name: "nano banana 2"
```

Currently configured:

| Model | Shown as |
|---|---|
| `gemini-3.8-flash` | `gemini-3.8-flash` (primary, unrenamed) |
| `gemini-3.5-flash` | `gemini-flash` |
| `gemini-3.5-flash-lite` | `gemini-flash-lite` |
| `gemini-3.1-flash-image` | `nano banana 2` |

`provision.sh` applies these through OpenWebUI's model API. An entry whose id
equals the base model's id **renames it in place** rather than adding a
second row to the picker. Run `make provision` after changing one.

```sh
docker compose up -d litellm && make provision && make smoke
```

### A Compose gotcha

`docker compose` gives an exported shell variable precedence over the same
name in `.env`. If you have sourced `.env` into your shell and then edit it,
Compose will keep using the stale exported value. Use a fresh shell, or
`env -u VERTEX_LOCATION docker compose up -d --force-recreate litellm`.
