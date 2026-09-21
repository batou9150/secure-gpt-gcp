#!/usr/bin/env bash
# Switches (or reports) the deployment target recorded in .env.
set -euo pipefail
cd "$(dirname "$0")/.."

current() { sed -n 's/^TARGET=//p' .env 2>/dev/null | head -1; }

show() {
  local t; t=$(current); t="${t:-local}"
  case "$t" in
    local) echo "  target: local  — docker compose on this machine" ;;
    gcp)   echo "  target: gcp    — Cloud SQL + Cloud Run + Agent Runtime"
           sed -n 's/^GCP_PROJECT=/         project: /p;s/^GCP_REGION=/         region:  /p' .env ;;
    *)     echo "  target: $t (unknown)" ;;
  esac
}

if [ "${1:-}" = "--show" ]; then show; exit 0; fi

want="${1:?usage: set-target.sh local|gcp|--show}"
case "$want" in local|gcp) ;; *) echo "unknown target: $want (expected local or gcp)"; exit 1 ;; esac

[ -f .env ] || { echo ".env not found — run 'make bootstrap' first."; exit 1; }
if grep -q '^TARGET=' .env; then
  python3 - "$want" <<'PY'
import re, sys
s = open(".env").read()
open(".env", "w").write(re.sub(r'^TARGET=.*$', f'TARGET={sys.argv[1]}', s, flags=re.M))
PY
else
  printf '\n# --- Deployment target: local | gcp ---------------------------------------\nTARGET=%s\n' "$want" >> .env
fi
show
