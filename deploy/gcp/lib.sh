#!/usr/bin/env bash
# Shared configuration and helpers for the Google Cloud target.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
set -a; . ./.env; set +a

: "${GCP_PROJECT:?set GCP_PROJECT in .env}"
GCP_REGION="${GCP_REGION:-europe-west1}"
GCP_SQL_INSTANCE="${GCP_SQL_INSTANCE:-secure-gpt-db}"
GCP_SQL_TIER="${GCP_SQL_TIER:-db-g1-small}"
GCP_SA="${GCP_SA:-secure-gpt-run}"
SA_EMAIL="${GCP_SA}@${GCP_PROJECT}.iam.gserviceaccount.com"
AGENT_APP_NAME="${AGENT_APP_NAME:-weather_time_agent}"
AGENT_RUNTIME_NAME="${AGENT_RUNTIME_NAME:-secure-gpt-weather-time-agent}"
SQL_CONN="${GCP_PROJECT}:${GCP_REGION}:${GCP_SQL_INSTANCE}"

say()  { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
gc()   { gcloud --project "$GCP_PROJECT" "$@"; }

# Writes KEY=VALUE back into .env so later commands and `make creds` see it.
put_env() {
  python3 - "$1" "$2" <<'PY'
import re, sys
name, value = sys.argv[1], sys.argv[2]
s = open(".env").read()
if re.search(rf'^{name}=', s, flags=re.M):
    s = re.sub(rf'^{name}=.*$', f'{name}={value}', s, flags=re.M)
else:
    s = s.rstrip("\n") + f"\n{name}={value}\n"
open(".env", "w").write(s)
PY
}

# Create or update a Secret Manager secret from stdin.
put_secret() {
  local name="$1"
  if gc secrets describe "$name" >/dev/null 2>&1; then
    gc secrets versions add "$name" --data-file=- >/dev/null
  else
    gc secrets create "$name" --replication-policy=automatic --data-file=- >/dev/null
  fi
}

run_url() { gc run services describe "$1" --region "$GCP_REGION" --format='value(status.url)' 2>/dev/null; }
