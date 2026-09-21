#!/usr/bin/env bash
# Read-only checks before anything is created on Google Cloud.
# Creates nothing and costs nothing.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
set +e

pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; echo "        $2"; fail=$((fail+1)); }

echo "== Google Cloud preflight =="
echo "   project: $GCP_PROJECT   region: $GCP_REGION   agent: ${GCP_AGENT_LOCATION:-$GCP_REGION}"

command -v gcloud >/dev/null && ok "gcloud installed" || no "gcloud installed" "not on PATH"
command -v agents-cli >/dev/null && ok "agents-cli installed (needed for Agent Runtime)" \
  || no "agents-cli installed" "uv tool install google-agents-cli"

acct=$(gcloud config get-value account 2>/dev/null)
[ -n "$acct" ] && [ "$acct" != "(unset)" ] && ok "authenticated as $acct" \
  || no "gcloud authentication" "run: gcloud auth login"

if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  ok "application-default credentials are valid"
else
  no "application-default credentials" "run: gcloud auth application-default login"
fi

# gcloud's own user credential is separate from the application-default one
# above: ADC can be valid while the CLI credential needs a fresh login.
probe=$(gc projects describe "$GCP_PROJECT" 2>&1)
if [ $? -eq 0 ]; then
  ok "project $GCP_PROJECT is reachable"
elif grep -qi 'reauthentication\|refreshing your current auth' <<<"$probe"; then
  no "gcloud CLI credential" "expired — run: gcloud auth login  (this is NOT the same as the application-default credential, which is fine)"
else
  no "project $GCP_PROJECT" "$(head -1 <<<"$probe")"
fi

echo "-- APIs --"
enabled=$(gc services list --enabled --format='value(config.name)' 2>/dev/null)
for api in run sqladmin secretmanager aiplatform cloudbuild artifactregistry; do
  if grep -q "^${api}.googleapis.com$" <<<"$enabled"; then ok "$api API enabled"
  else echo "  TODO  $api API not enabled — 'make up' will enable it"; fi
done

echo "-- existing resources --"
for svc in litellm open-webui; do
  u=$(run_url "$svc")
  [ -n "$u" ] && echo "  have  run/$svc  $u" || echo "  none  run/$svc"
done
gc sql instances describe "$GCP_SQL_INSTANCE" --format='value(state)' 2>/dev/null \
  | sed 's/^/  have  sql\/'"$GCP_SQL_INSTANCE"'  /' || echo "  none  sql/$GCP_SQL_INSTANCE"
[ -n "${GCP_AGENT_ENGINE_RESOURCE:-}" ] && echo "  have  agent  $GCP_AGENT_ENGINE_RESOURCE" || echo "  none  agent"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
