"""Make A2A task replies legible to clients that read only one artifact.

ADK emits one artifact per step, so a task that called two tools comes back as
[tool-call, tool-call, final-text]. Several A2A clients — LiteLLM's
A2A -> OpenAI chat bridge among them — read only ``artifacts[0]`` and so see a
function-call data part with no text, and surface an empty message.

The A2A spec allows a completed task to carry a ``status.message``, and that is
checked before the artifact list by those clients, so this middleware fills it
in with the concatenated text of the reply. Nothing is removed: the artifacts
are left exactly as ADK produced them.
"""

from __future__ import annotations

import json
from collections.abc import Callable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

_MAX_BYTES = 8 * 1024 * 1024


def _text_of(parts: object) -> str:
    if not isinstance(parts, list):
        return ""
    out = []
    for part in parts:
        if isinstance(part, dict) and part.get("kind") == "text" and part.get("text"):
            out.append(str(part["text"]))
    return "\n".join(out)


def _summarise(result: dict) -> None:
    """Fill status.message from the artifacts, in place."""
    status = result.get("status")
    if not isinstance(status, dict) or status.get("message"):
        return  # already carries a message; leave it alone
    texts = [t for a in result.get("artifacts") or []
             if isinstance(a, dict) and (t := _text_of(a.get("parts")))]
    if not texts:
        return
    status["message"] = {
        "role": "agent",
        "kind": "message",
        "messageId": f"{result.get('id', 'task')}-summary",
        "parts": [{"kind": "text", "text": "\n".join(texts)}],
    }


class A2ATaskSummaryMiddleware(BaseHTTPMiddleware):
    """Adds status.message to completed A2A task responses on `path`."""

    def __init__(self, app, path: str) -> None:
        super().__init__(app)
        self._path = path

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        response = await call_next(request)
        if request.url.path != self._path or response.status_code != 200:
            return response
        if not response.headers.get("content-type", "").startswith("application/json"):
            return response  # streaming (text/event-stream) passes through

        body = b"".join([chunk async for chunk in response.body_iterator])
        if len(body) > _MAX_BYTES:
            return Response(body, response.status_code, dict(response.headers),
                            response.media_type)
        try:
            payload = json.loads(body)
            result = payload.get("result")
            if isinstance(result, dict) and result.get("kind") == "task":
                _summarise(result)
                body = json.dumps(payload).encode()
        except (ValueError, TypeError):
            pass  # not JSON-RPC we understand — pass it through untouched

        headers = dict(response.headers)
        headers["content-length"] = str(len(body))
        return Response(body, response.status_code, headers, response.media_type)
