#!/usr/bin/env bash
# The gateway on Cloud Run, with the A2A auth shim as a sidecar.
#
# Sidecars need the YAML surface, so the service is rendered from a template
# and applied with `gcloud run services replace`.
#
# Ingress is internal: only Open WebUI (which gets direct VPC egress) may
# reach it. It is never on the public internet.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
step "Cloud Run: litellm (+ A2A auth shim sidecar)"

REPO="${GCP_AR_REPO:-secure-gpt}"
gc artifacts repositories describe "$REPO" --location "$GCP_REGION" >/dev/null 2>&1 \
  || gc artifacts repositories create "$REPO" --repository-format=docker \
       --location "$GCP_REGION" --quiet >/dev/null
SHIM_IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${REPO}/a2a-shim:latest"

say "building the shim image"
gc builds submit deploy/gcp/a2a-shim --tag "$SHIM_IMAGE" --quiet >/dev/null
say "built $SHIM_IMAGE"

export SHIM_IMAGE SA_EMAIL SQL_CONN GCP_REGION
export LITELLM_IMAGE="${LITELLM_IMAGE:-ghcr.io/berriai/litellm-database:main-stable}"
export AGENT_ENGINE_RESOURCE="${GCP_AGENT_ENGINE_RESOURCE:-}"
export AGENT_APP_NAME AGENT_ENGINE_LOCATION="${GCP_AGENT_LOCATION:-$GCP_REGION}"

tmp=$(mktemp /tmp/litellm-svc-XXXX.yaml)
python3 deploy/gcp/render.py deploy/gcp/litellm.service.yaml.tpl > "$tmp"
gc run services replace "$tmp" --region "$GCP_REGION" --quiet >/dev/null
rm -f "$tmp"

# Internal ingress: reachable from the VPC, not from the internet.
gc run services update litellm --region "$GCP_REGION" --ingress internal --quiet >/dev/null
put_env GCP_LITELLM_URL "$(run_url litellm)"
say "deployed: $(run_url litellm)  (ingress: internal)"
