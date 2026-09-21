#!/usr/bin/env bash
# Local target: docker compose on this machine.
set -euo pipefail
cd "$(dirname "$0")/../.."
docker compose up -d
./scripts/provision.sh
echo
./deploy/local/urls.sh
