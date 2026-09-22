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
# Pin concrete secret versions so a rotated secret actually produces a new
# revision instead of being silently served from the old one.
export OPENWEBUI_SECRET_KEY_VERSION="$(secret_version secure-gpt-openwebui-secret-key)"
export GOOGLE_CLIENT_SECRET_VERSION="$(secret_version secure-gpt-google-client-secret)"
say "secret versions: openwebui-key=${OPENWEBUI_SECRET_KEY_VERSION} google-client=${GOOGLE_CLIENT_SECRET_VERSION}"
export OPENWEBUI_CHAT_KEY="${OPENWEBUI_CHAT_KEY:-$LITELLM_MASTER_KEY}"
export OPENWEBUI_EMBED_KEY="${OPENWEBUI_EMBED_KEY:-$LITELLM_MASTER_KEY}"

tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
python3 deploy/gcp/render.py deploy/gcp/openwebui.service.yaml.tpl > "$tmpdir/open-webui.service.yaml"
gc run services replace "$tmpdir/open-webui.service.yaml" --region "$GCP_REGION" --quiet >/dev/null

# The runtime SA must be able to invoke the gateway on the UI's behalf.
gc run services add-iam-policy-binding litellm --region "$GCP_REGION" \
  --member "serviceAccount:${SA_EMAIL}" --role roles/run.invoker --quiet >/dev/null 2>&1 || true

# Reaching the UI. Granting allUsers is refused under domain restricted
# sharing, but --no-invoker-iam-check turns the platform check off without a
# policy binding, which is the DRS-compatible way to expose a service. Open
# WebUI then gates access with its own login (DEFAULT_USER_ROLE=pending), so
# it is the only thing standing in front of the UI — `make smoke` asserts it
# actually rejects anonymous API calls. Set GCP_OPENWEBUI_PUBLIC=false to
# keep the IAM check and reach it through a tunnel instead.
if [ "${GCP_OPENWEBUI_PUBLIC:-true}" = true ]; then
  gc run services update open-webui --region "$GCP_REGION" --no-invoker-iam-check --quiet >/dev/null
  say "invoker IAM check disabled — Open WebUI's own login is the gate"
else
  gc run services update open-webui --region "$GCP_REGION" --invoker-iam-check --quiet >/dev/null
  say "IAM-protected: reach it with 'gcloud run services proxy open-webui --region $GCP_REGION'"
fi

put_env GCP_OPENWEBUI_URL "$(run_url open-webui)"
say "deployed: $(run_url open-webui)"
