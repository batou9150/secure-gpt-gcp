"""A2A auth shim: LiteLLM -> Vertex AI Agent Runtime.

Agent Runtime exposes the agent's A2A endpoint behind
``aiplatform.googleapis.com``, which requires a Google OAuth bearer token that
expires roughly hourly. LiteLLM's A2A registry only holds *static* credentials
(``api_key`` / ``static_headers``), so it cannot talk to Agent Runtime directly.

This process sits beside LiteLLM as a Cloud Run sidecar, listening on
localhost. It takes the JSON-RPC body unchanged, attaches a freshly minted
token from the runtime service account, and forwards it to the agent's
passthrough URL. Because it is a sidecar it is not reachable from outside the
instance, and the token never leaves it.

Remove this once LiteLLM can mint Google credentials for an A2A agent itself.
"""

from __future__ import annotations

import logging
import os

import google.auth
import google.auth.transport.requests
import httpx
from fastapi import FastAPI, Request, Response

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("a2a-shim")

# projects/<p>/locations/<l>/reasoningEngines/<id>
AGENT_ENGINE_RESOURCE = os.environ.get("AGENT_ENGINE_RESOURCE", "").strip()
AGENT_APP_NAME = os.environ.get("AGENT_APP_NAME", "weather_time_agent")
LOCATION = os.environ.get("AGENT_ENGINE_LOCATION", "europe-west1")
SCOPE = "https://www.googleapis.com/auth/cloud-platform"

_credentials, _ = google.auth.default(scopes=[SCOPE])
_client = httpx.AsyncClient(timeout=httpx.Timeout(600.0, connect=30.0))

app = FastAPI(title="A2A auth shim")


def _token() -> str:
    """A valid access token, refreshed by google-auth when near expiry."""
    if not _credentials.valid or _credentials.expired:
        _credentials.refresh(google.auth.transport.requests.Request())
    return _credentials.token


def _base() -> str:
    return (
        f"https://{LOCATION}-aiplatform.googleapis.com/reasoningEngines/v1/"
        f"{AGENT_ENGINE_RESOURCE}/api/a2a/{AGENT_APP_NAME}"
    )


@app.get("/healthz")
async def healthz() -> dict:
    return {"ok": bool(AGENT_ENGINE_RESOURCE), "target": _base() if AGENT_ENGINE_RESOURCE else None}


@app.get("/.well-known/agent-card.json")
async def card() -> Response:
    return await _forward_get("/.well-known/agent-card.json")


async def _forward_get(suffix: str) -> Response:
    if not AGENT_ENGINE_RESOURCE:
        return Response('{"error":"AGENT_ENGINE_RESOURCE is not set"}', 503,
                        media_type="application/json")
    r = await _client.get(_base() + suffix, headers={"Authorization": f"Bearer {_token()}"})
    return Response(r.content, r.status_code,
                    media_type=r.headers.get("content-type", "application/json"))


@app.post("/")
async def rpc(request: Request) -> Response:
    """JSON-RPC passthrough with a fresh bearer token attached."""
    if not AGENT_ENGINE_RESOURCE:
        return Response('{"error":"AGENT_ENGINE_RESOURCE is not set"}', 503,
                        media_type="application/json")
    body = await request.body()
    headers = {
        "Authorization": f"Bearer {_token()}",
        "Content-Type": request.headers.get("content-type", "application/json"),
    }
    # Preserve the client's streaming intent.
    if accept := request.headers.get("accept"):
        headers["Accept"] = accept
    r = await _client.post(_base(), content=body, headers=headers)
    if r.status_code >= 400:
        log.warning("agent runtime returned %s: %s", r.status_code, r.text[:400])
    return Response(r.content, r.status_code,
                    media_type=r.headers.get("content-type", "application/json"))
