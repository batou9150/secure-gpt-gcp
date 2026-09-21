"""Convenience entrypoint.

The served application lives in ``weather_time_agent.fast_api_app`` so that the
local container and Agent Runtime expose exactly the same routes: the ADK API,
A2A at ``/a2a/weather_time_agent`` and the reasoning-engine passthrough.
"""

from weather_time_agent.fast_api_app import app  # noqa: F401
