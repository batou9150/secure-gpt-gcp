#!/usr/bin/env bash
# Phase 3: tell the gateway's A2A sidecar which agent to forward to.
# Only the sidecar's environment changes; the LiteLLM config is untouched.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
step "Linking the gateway to the agent"
: "${GCP_AGENT_ENGINE_RESOURCE:?the agent must be deployed first}"
./deploy/gcp/steps/40-litellm.sh    # re-render with AGENT_ENGINE_RESOURCE set
say "sidecar now targets ${GCP_AGENT_ENGINE_RESOURCE}"
