"""The classic ADK demo agent: weather and current time for a city.

Its own LLM calls go back out through the LiteLLM gateway rather than
straight to Google, so the gateway stays the single egress point and the
agent never holds provider credentials — only a scoped virtual key.
"""

import datetime
import os
from zoneinfo import ZoneInfo

from google.adk.agents import Agent
from google.adk.models.lite_llm import LiteLlm

# city -> (IANA timezone, canned weather)
CITIES: dict[str, tuple[str, str]] = {
    "new york": ("America/New_York", "sunny, 25 °C (77 °F)"),
    "london": ("Europe/London", "overcast with light rain, 14 °C (57 °F)"),
    "paris": ("Europe/Paris", "partly cloudy, 19 °C (66 °F)"),
    "berlin": ("Europe/Berlin", "clear, 17 °C (63 °F)"),
    "madrid": ("Europe/Madrid", "hot and dry, 31 °C (88 °F)"),
    "tokyo": ("Asia/Tokyo", "humid with scattered showers, 27 °C (81 °F)"),
}


def get_weather(city: str) -> dict:
    """Retrieves the current weather report for a specified city.

    Args:
        city: The name of the city, for example "Paris".

    Returns:
        A dict with status "success" and a "report", or status "error" and an
        "error_message".
    """
    entry = CITIES.get(city.strip().lower())
    if entry is None:
        return {
            "status": "error",
            "error_message": (
                f"No weather information available for '{city}'. "
                f"Known cities: {', '.join(c.title() for c in sorted(CITIES))}."
            ),
        }
    return {"status": "success", "report": f"The weather in {city.title()} is {entry[1]}."}


def get_current_time(city: str) -> dict:
    """Returns the current local time in a specified city.

    Args:
        city: The name of the city, for example "Paris".

    Returns:
        A dict with status "success" and a "report", or status "error" and an
        "error_message".
    """
    entry = CITIES.get(city.strip().lower())
    if entry is None:
        return {
            "status": "error",
            "error_message": (
                f"No timezone information available for '{city}'. "
                f"Known cities: {', '.join(c.title() for c in sorted(CITIES))}."
            ),
        }
    now = datetime.datetime.now(ZoneInfo(entry[0]))
    return {
        "status": "success",
        "report": f"The current time in {city.title()} is {now.strftime('%Y-%m-%d %H:%M:%S %Z')}.",
    }


root_agent = Agent(
    name="weather_time_agent",
    model=LiteLlm(
        # Routed back through the gateway; "openai/" just selects LiteLLM's
        # OpenAI-compatible client, the model behind it is Gemini on Vertex.
        model="openai/" + os.environ.get("AGENT_MODEL", "gemini-3.8-flash"),
        api_base=os.environ["LITELLM_BASE_URL"],
        api_key=os.environ["LITELLM_API_KEY"],
    ),
    description="Answers questions about the weather and the current time in a city.",
    instruction=(
        "You are a concise assistant that reports the weather and the current time "
        "for a city. Use the get_weather and get_current_time tools; never guess. "
        "If a tool returns an error, relay its error_message verbatim. "
        "If the user names no city, ask which one."
    ),
    tools=[get_weather, get_current_time],
)
