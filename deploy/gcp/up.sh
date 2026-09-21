#!/usr/bin/env bash
# Brings the stack up on Google Cloud:
#   Cloud SQL (postgres) + Cloud Run (litellm, open-webui) + Agent Runtime (ADK).
#
# Ordering matters and is circular by nature: the agent needs the gateway URL
# for its own LLM calls, and the gateway needs the agent's resource name. It is
# broken by deploying the gateway first and telling its A2A sidecar about the
# agent afterwards, so the gateway's own config never changes.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

./deploy/gcp/steps/00-apis.sh
./deploy/gcp/steps/10-iam.sh
./deploy/gcp/steps/20-sql.sh
./deploy/gcp/steps/30-secrets.sh
./deploy/gcp/steps/40-litellm.sh      # phase 1: gateway, shim not yet pointed
./deploy/gcp/steps/50-agent.sh        # phase 2: agent, knows the gateway URL
./deploy/gcp/steps/60-link-agent.sh   # phase 3: point the shim at the agent
./deploy/gcp/steps/70-openwebui.sh

step "Provisioning keys, agent binding and Open WebUI settings"
./scripts/provision.sh

step "Done"
./deploy/gcp/urls.sh
