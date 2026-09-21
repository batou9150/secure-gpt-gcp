#!/usr/bin/env bash
# The UI on Cloud Run: public (it has its own auth), with direct VPC egress so
# it can reach the internal-ingress gateway.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
step "Cloud Run: open-webui"
GW="${GCP_LITELLM_URL:?litellm must be deployed first}"

gc run deploy open-webui \
  --image "${OPENWEBUI_IMAGE:-ghcr.io/open-webui/open-webui:main}" \
  --region "$GCP_REGION" --service-account "$SA_EMAIL" \
  --port 8080 --cpu 2 --memory 4Gi --min-instances 0 --max-instances 5 \
  --add-cloudsql-instances "$SQL_CONN" \
  --network default --subnet default --vpc-egress private-ranges-only \
  --allow-unauthenticated --ingress all \
  --set-secrets "WEBUI_SECRET_KEY=secure-gpt-openwebui-secret-key:latest,DB_PASSWORD=secure-gpt-postgres-password:latest" \
  --set-env-vars "^@^DATABASE_URL=postgresql://securegpt:${POSTGRES_PASSWORD}@/openwebui?host=/cloudsql/${SQL_CONN}@OPENAI_API_BASE_URL=${GW}/v1@OPENAI_API_KEY=${OPENWEBUI_CHAT_KEY:-$LITELLM_MASTER_KEY}@ENABLE_OPENAI_API=True@ENABLE_OLLAMA_API=False@ENABLE_DIRECT_CONNECTIONS=False@ENABLE_EVALUATION_ARENA_MODELS=False@ENABLE_WEB_SEARCH=False@ENABLE_IMAGE_GENERATION=False@ENABLE_COMMUNITY_SHARING=False@ENABLE_AUTOCOMPLETE_GENERATION=False@ENABLE_ADMIN_CHAT_ACCESS=False@ENABLE_ADMIN_EXPORT=False@DEFAULT_USER_ROLE=pending@WEBUI_AUTH=True@WEBUI_NAME=Secure GPT@WEBUI_SESSION_COOKIE_SAME_SITE=strict@WEBUI_SESSION_COOKIE_SECURE=True@ANONYMIZED_TELEMETRY=False@DO_NOT_TRACK=1@SCARF_NO_ANALYTICS=True@ENABLE_VERSION_UPDATE_CHECK=False@RAG_EMBEDDING_ENGINE=openai@RAG_EMBEDDING_MODEL=${EMBEDDING_MODEL:-gemini-embedding-001}@RAG_OPENAI_API_BASE_URL=${GW}/v1@RAG_OPENAI_API_KEY=${OPENWEBUI_EMBED_KEY:-$LITELLM_MASTER_KEY}@AUDIO_STT_ENGINE=" \
  --quiet >/dev/null

put_env GCP_OPENWEBUI_URL "$(run_url open-webui)"
say "deployed: $(run_url open-webui)"
say "note: WEBUI_SESSION_COOKIE_SECURE=True — Cloud Run terminates TLS, so cookies are https-only"
