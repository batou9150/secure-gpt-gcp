#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
