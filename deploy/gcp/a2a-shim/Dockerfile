FROM python:3.13-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
RUN pip install --no-cache-dir "fastapi>=0.115" "uvicorn[standard]>=0.34" \
    "httpx>=0.28" "google-auth>=2.38"
COPY main.py .
RUN useradd --create-home --uid 10002 shim && chown -R shim:shim /app
USER shim
ENV PORT=8081
EXPOSE 8081
CMD exec uvicorn main:app --host 127.0.0.1 --port ${PORT}
