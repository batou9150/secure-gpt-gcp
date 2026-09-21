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
# A content tag, so a rebuilt shim always produces a new Cloud Run revision.
# With a floating :latest the service spec is unchanged and Cloud Run keeps
# serving (or retrying) the old revision.
SHIM_TAG=$(cat deploy/gcp/auth-proxy/Dockerfile deploy/gcp/auth-proxy/main.py | shasum -a 256 | cut -c1-12)
SHIM_IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${REPO}/auth-proxy:${SHIM_TAG}"

if gc artifacts docker images describe "$SHIM_IMAGE" >/dev/null 2>&1; then
  say "shim image $SHIM_TAG already built"
else
  say "building the shim image ($SHIM_TAG)"
  gc builds submit deploy/gcp/auth-proxy --tag "$SHIM_IMAGE" --quiet >/dev/null
fi
say "shim: $SHIM_IMAGE"

export SHIM_IMAGE SA_EMAIL SQL_CONN GCP_REGION
say "mirroring the gateway image into Artifact Registry (Cloud Run cannot pull ghcr.io)"
export LITELLM_IMAGE
LITELLM_IMAGE=$(mirror_image "${LITELLM_SOURCE_IMAGE:-ghcr.io/berriai/litellm-database:main-stable}" "litellm:main-stable")
say "image: $LITELLM_IMAGE"
export AGENT_ENGINE_RESOURCE="${GCP_AGENT_ENGINE_RESOURCE:-}"
export AGENT_APP_NAME AGENT_ENGINE_LOCATION="${GCP_AGENT_LOCATION:-$GCP_REGION}"

# mktemp needs the Xs at the end of the template, so build the name inside a
# temporary directory rather than embedding a suffix.
tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
python3 deploy/gcp/render.py deploy/gcp/litellm.service.yaml.tpl > "$tmpdir/litellm.service.yaml"
gc run services replace "$tmpdir/litellm.service.yaml" --region "$GCP_REGION" --quiet >/dev/null

# Ingress. `internal` is the hardened setting, but then `make provision` and
# `make smoke` cannot reach the gateway from a laptop — they would have to run
# from inside the VPC. The default is `all`, which is still not open: every
# route requires a virtual key (the suite asserts the 401), keys are scoped to
# named models, and the agent routes are pinned per key. Set
# GCP_LITELLM_INGRESS=internal once you no longer need to drive it from outside.
INGRESS="${GCP_LITELLM_INGRESS:-all}"
gc run services update litellm --region "$GCP_REGION" --ingress "$INGRESS" --quiet >/dev/null
put_env GCP_LITELLM_URL "$(run_url litellm)"
say "deployed: $(run_url litellm)  (ingress: $INGRESS)"
