#!/usr/bin/env bash
# The UI on Cloud Run, with an auth-proxy sidecar that signs calls to the
# gateway. Cloud Run IAM protects both services (this org forbids allUsers),
# so reaching the UI needs an identity token — see README for IAP.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
step "Cloud Run: open-webui (+ auth-proxy sidecar)"
: "${GCP_LITELLM_URL:?litellm must be deployed first}"

say "mirroring the Open WebUI image into Artifact Registry"
export OPENWEBUI_IMAGE
OPENWEBUI_IMAGE=$(mirror_image "${OPENWEBUI_SOURCE_IMAGE:-ghcr.io/open-webui/open-webui:main}" "open-webui:main")
say "image: $OPENWEBUI_IMAGE"

REPO="${GCP_AR_REPO:-secure-gpt}"
SHIM_TAG=$(cat deploy/gcp/auth-proxy/Dockerfile deploy/gcp/auth-proxy/main.py | shasum -a 256 | cut -c1-12)
export SHIM_IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${REPO}/auth-proxy:${SHIM_TAG}"
gc artifacts docker images describe "$SHIM_IMAGE" >/dev/null 2>&1 \
  || gc builds submit deploy/gcp/auth-proxy --tag "$SHIM_IMAGE" --quiet >/dev/null

export SA_EMAIL SQL_CONN GCP_LITELLM_URL
export OPENWEBUI_CHAT_KEY="${OPENWEBUI_CHAT_KEY:-$LITELLM_MASTER_KEY}"
export OPENWEBUI_EMBED_KEY="${OPENWEBUI_EMBED_KEY:-$LITELLM_MASTER_KEY}"

tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
python3 deploy/gcp/render.py deploy/gcp/openwebui.service.yaml.tpl > "$tmpdir/open-webui.service.yaml"
gc run services replace "$tmpdir/open-webui.service.yaml" --region "$GCP_REGION" --quiet >/dev/null

# The runtime SA must be able to invoke the gateway on the UI's behalf.
gc run services add-iam-policy-binding litellm --region "$GCP_REGION" \
  --member "serviceAccount:${SA_EMAIL}" --role roles/run.invoker --quiet >/dev/null 2>&1 || true

put_env GCP_OPENWEBUI_URL "$(run_url open-webui)"
say "deployed: $(run_url open-webui)"
say "IAM-protected: reach it with 'gcloud run services proxy open-webui --region $GCP_REGION'"
