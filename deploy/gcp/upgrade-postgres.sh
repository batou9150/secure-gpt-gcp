#!/usr/bin/env bash
# One-off: upgrade the Cloud SQL instance in place to $GCP_SQL_VERSION.
# Cloud SQL takes a backup before a major-version upgrade, and the instance is
# unavailable while it runs (usually several minutes).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
step "Cloud SQL major-version upgrade"
current=$(gc sql instances describe "$GCP_SQL_INSTANCE" --format='value(databaseVersion)')
if [ "$current" = "$GCP_SQL_VERSION" ]; then
  say "$GCP_SQL_INSTANCE already runs $GCP_SQL_VERSION"
  exit 0
fi
say "$GCP_SQL_INSTANCE: $current -> $GCP_SQL_VERSION"
say "LiteLLM and Open WebUI lose their database until the upgrade finishes."
read -r -p "  Type the instance name to continue: " answer
[ "$answer" = "$GCP_SQL_INSTANCE" ] || { say "aborted"; exit 1; }
gc sql instances patch "$GCP_SQL_INSTANCE" --database-version="$GCP_SQL_VERSION"
say "now on $(gc sql instances describe "$GCP_SQL_INSTANCE" --format='value(databaseVersion)')"
