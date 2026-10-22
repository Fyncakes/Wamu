#!/usr/bin/env bash
# Poll until billing is enabled, then run cost-light deploy (external Redis, staging mocks).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source "$(dirname "$0")/lib.sh"
load_env
gcloud_cfg

echo "==> Waiting for billingEnabled=true on $GCP_PROJECT_ID (reopen billing account in Console if needed)"
for i in $(seq 1 120); do
  en=$(gcloud billing projects describe "$GCP_PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || echo false)
  echo "  [$i] billingEnabled=$en"
  if [[ "${en,,}" == "true" ]]; then
    break
  fi
  sleep 15
done
en=$(gcloud billing projects describe "$GCP_PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || echo false)
if [[ "${en,,}" != "true" ]]; then
  echo "ERROR: billing still not enabled. In Console: Billing → My Billing Account → Account management → Reopen" >&2
  exit 1
fi

# Cost controls: budget alert $50 if billingbudgets API works
gcloud services enable billingbudgets.googleapis.com --quiet 2>/dev/null || true
BA=$(gcloud billing projects describe "$GCP_PROJECT_ID" --format='value(billingAccountName)')
if [[ -n "$BA" ]]; then
  echo "==> Creating \$50 monthly budget alert (best-effort)"
  gcloud billing budgets create \
    --billing-account="${BA#billingAccounts/}" \
    --display-name="wamu-soft-launch-50" \
    --budget-amount=50 \
    --threshold-rule=percent=50 \
    --threshold-rule=percent=90 \
    --threshold-rule=percent=100 \
    --filter-projects="projects/$(gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)')" \
    2>&1 || echo "(budget create skipped — set alerts in Console → Budgets & alerts)"
fi

exec "$(dirname "$0")/deploy_after_auth.sh"
