"""Attaches Google credentials to calls that the caller cannot sign itself.

Two consumers, one image, selected by MODE:

* ``MODE=a2a`` — sidecar in the LiteLLM service. Vertex AI Agent Runtime
  serves the agent's A2A endpoint behind ``aiplatform.googleapis.com`` and
  wants an OAuth *access* token that expires hourly; LiteLLM's A2A registry
  only holds static credentials. Forwards JSON-RPC with a fresh token.

* ``MODE=cloudrun`` — sidecar in the Open WebUI service. This organization
  forbids ``allUsers`` on Cloud Run (domain restricted sharing), so the
  gateway is IAM-protected and every caller must present an *identity* token
  for its audience. Open WebUI cannot mint one. This forwards to the gateway
  with the identity token in ``Authorization`` and moves Open WebUI's own
  virtual key to ``x-litellm-api-key``, which is the header LiteLLM prefers
  when ``Authorization`` is carrying a platform token.

Either way the token is minted from the runtime service account inside the
instance and never leaves it: the proxy listens on the pod's localhost and no
Cloud Run port routes to it.
"""

from __future__ import annotations

import json
import logging
import os

import google.auth
import google.auth.transport.requests
import google.oauth2.id_token
import httpx
from fastapi import FastAPI, Request, Response

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("auth-proxy")

MODE = os.environ.get("MODE", "a2a").strip()
SCOPE = "https://www.googleapis.com/auth/cloud-platform"

# --- a2a mode ---------------------------------------------------------------
AGENT_ENGINE_RESOURCE = os.environ.get("AGENT_ENGINE_RESOURCE", "").strip()
AGENT_APP_NAME = os.environ.get("AGENT_APP_NAME", "weather_time_agent")
AGENT_ENGINE_LOCATION = os.environ.get("AGENT_ENGINE_LOCATION", "europe-west1")

# --- cloudrun mode ----------------------------------------------------------
UPSTREAM_URL = os.environ.get("UPSTREAM_URL", "").rstrip("/")
UPSTREAM_KEY = os.environ.get("UPSTREAM_KEY", "")

_credentials, _ = google.auth.default(scopes=[SCOPE])
_client = httpx.AsyncClient(timeout=httpx.Timeout(600.0, connect=30.0))
_request = google.auth.transport.requests.Request()

app = FastAPI(title=f"auth-proxy ({MODE})")


def _access_token() -> str:
    if not _credentials.valid or _credentials.expired:
        _credentials.refresh(_request)
    return _credentials.token


def _id_token(audience: str) -> str:
    """Identity token for a Cloud Run audience, from the runtime SA."""
    return google.oauth2.id_token.fetch_id_token(_request, audience)


def _a2a_base() -> str:
    return (
        f"https://{AGENT_ENGINE_LOCATION}-aiplatform.googleapis.com/reasoningEngines/v1/"
        f"{AGENT_ENGINE_RESOURCE}/api/a2a/{AGENT_APP_NAME}"
    )


@app.get("/healthz")
async def healthz() -> dict:
    if MODE == "cloudrun":
        return {"ok": bool(UPSTREAM_URL), "mode": MODE, "upstream": UPSTREAM_URL or None}
    return {"ok": bool(AGENT_ENGINE_RESOURCE), "mode": MODE,
            "target": _a2a_base() if AGENT_ENGINE_RESOURCE else None}


_PLACEHOLDER_CARD = {
    "name": AGENT_APP_NAME,
    "description": "Agent Runtime target not linked yet.",
    "url": "http://localhost:8081",
    "version": "0.0.0",
    "protocolVersion": "1.0",
    "capabilities": {"streaming": False},
    "defaultInputModes": ["text/plain"],
    "defaultOutputModes": ["text/plain"],
    "skills": [],
}


@app.get("/.well-known/agent-card.json")
async def card() -> Response:
    """The agent's card, or a placeholder while the agent is not linked yet.

    LiteLLM fetches this when loading its agent registry at startup; during
    phase 1 of a deploy the agent does not exist, and failing here would stop
    the gateway booting at all.
    """
    if MODE != "a2a":
        return Response('{"error":"not in a2a mode"}', 404, media_type="application/json")
    if not AGENT_ENGINE_RESOURCE:
        return Response(json.dumps(_PLACEHOLDER_CARD), 200, media_type="application/json")
    r = await _client.get(_a2a_base() + "/.well-known/agent-card.json",
                          headers={"Authorization": f"Bearer {_access_token()}"})
    # Agent Runtime advertises its own aiplatform.googleapis.com address in
    # the card. A2A clients follow that url, and they have no token for it —
    # LiteLLM's native /a2a/ passthrough gets a 401. Point the card back at
    # this proxy so callers keep coming through here and stay authenticated.
    if r.status_code == 200:
        try:
            card = r.json()
            self_url = f"http://localhost:{os.environ.get('PORT', '8081')}"
            card["url"] = self_url
            # The card advertises the same aiplatform address in three places,
            # camelCase per the A2A spec. Miss one and a client will follow it
            # and get a 401, because only this proxy holds a token.
            for key in ("supportedInterfaces", "additionalInterfaces",
                        "supported_interfaces", "additional_interfaces"):
                for iface in card.get(key) or []:
                    if isinstance(iface, dict) and "url" in iface:
                        iface["url"] = self_url
            return Response(json.dumps(card), 200, media_type="application/json")
        except ValueError:
            pass
    return Response(r.content, r.status_code,
                    media_type=r.headers.get("content-type", "application/json"))


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def forward(path: str, request: Request) -> Response:
    if MODE == "a2a":
        if not AGENT_ENGINE_RESOURCE:
            return Response('{"error":"AGENT_ENGINE_RESOURCE is not set"}', 503,
                            media_type="application/json")
        url = _a2a_base()
        headers = {"Authorization": f"Bearer {_access_token()}"}
    else:
        if not UPSTREAM_URL:
            return Response('{"error":"UPSTREAM_URL is not set"}', 503,
                            media_type="application/json")
        url = f"{UPSTREAM_URL}/{path}" if path else UPSTREAM_URL
        headers = {"Authorization": f"Bearer {_id_token(UPSTREAM_URL)}"}
        # The caller's own key moves to the header LiteLLM checks first, so it
        # is not shadowed by the platform token above.
        inbound = request.headers.get("authorization", "")
        key = inbound[7:] if inbound.lower().startswith("bearer ") else (inbound or UPSTREAM_KEY)
        if key:
            headers["x-litellm-api-key"] = f"Bearer {key}"

    for h in ("content-type", "accept"):
        if v := request.headers.get(h):
            headers[h] = v

    r = await _client.request(request.method, url,
                              content=await request.body(),
                              params=dict(request.query_params),
                              headers=headers)
    if r.status_code >= 400:
        log.warning("%s upstream returned %s: %s", MODE, r.status_code, r.text[:300])
    return Response(r.content, r.status_code,
                    media_type=r.headers.get("content-type", "application/json"))
