"""Serves the weather/time agent over the A2A protocol.

LiteLLM's a2a provider POSTs JSON-RPC (`message/send` / `message/stream`) to
this service's root URL and translates the result back into OpenAI-style
chat completions for Open WebUI.
"""

import os

from google.adk.a2a.utils.agent_to_a2a import to_a2a

from weather_time_agent.agent import root_agent

PORT = int(os.environ.get("PORT", "8080"))

# to_a2a() returns an ASGI app exposing the agent card at
# /.well-known/agent-card.json and the JSON-RPC endpoint at /.
app = to_a2a(root_agent, port=PORT)
