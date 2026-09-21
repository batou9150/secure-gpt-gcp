#!/usr/bin/env bash
# Deletes all local data: postgres volume and chat history.
set -euo pipefail
cd "$(dirname "$0")/../.."
docker compose down -v
