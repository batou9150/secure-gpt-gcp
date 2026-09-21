#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
step "Enabling APIs"
gc services enable \
  run.googleapis.com sqladmin.googleapis.com secretmanager.googleapis.com \
  aiplatform.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  compute.googleapis.com --quiet
say "enabled"
