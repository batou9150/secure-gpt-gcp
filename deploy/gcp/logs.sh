#!/usr/bin/env bash
# Tails logs for a Cloud Run service (default: litellm) or the agent.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
what="${1:-litellm}"
case "$what" in
  agent)
    gc logging read 'resource.type="aiplatform.googleapis.com/ReasoningEngine"' \
      --limit 100 --format='table(timestamp,severity,textPayload)' ;;
  *)
    gc beta run services logs tail "$what" --region "$GCP_REGION" ;;
esac
