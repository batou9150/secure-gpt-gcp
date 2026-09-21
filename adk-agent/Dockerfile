# Built by docker compose for the local target and by Agent Runtime for the
# GCP target, so both run byte-identical code.
FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/usr/local

COPY --from=ghcr.io/astral-sh/uv:0.9.18 /uv /usr/local/bin/uv

WORKDIR /app

# Dependencies first so edits to the agent do not invalidate the layer.
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-install-project --no-dev

COPY main.py ./
COPY weather_time_agent ./weather_time_agent
RUN uv sync --locked --no-dev

RUN useradd --create-home --uid 10001 agent && chown -R agent:agent /app
USER agent

# Serves the ADK API, the A2A endpoint at /a2a/weather_time_agent, and the
# reasoning-engine routes Agent Runtime proxies under /api.
ENV PORT=8080
EXPOSE 8080
CMD exec uvicorn weather_time_agent.fast_api_app:app --host 0.0.0.0 --port ${PORT}
