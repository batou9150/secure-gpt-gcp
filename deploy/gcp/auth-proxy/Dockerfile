FROM python:3.13-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
# google-auth's requests transport needs `requests` at import time.
RUN pip install --no-cache-dir "fastapi>=0.115" "uvicorn[standard]>=0.34" \
    "httpx>=0.28" "google-auth>=2.38" "requests>=2.32"
COPY main.py .
RUN useradd --create-home --uid 10002 shim && chown -R shim:shim /app
USER shim
ENV PORT=8081
EXPOSE 8081
# Binds all interfaces so Cloud Run can run a startup probe against it.
# Only the gateway container has a `ports` entry, so the service never
# routes external traffic here.
CMD exec uvicorn main:app --host 0.0.0.0 --port ${PORT}
