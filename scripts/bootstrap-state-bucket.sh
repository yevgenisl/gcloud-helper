#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs

if gcloud storage buckets describe "gs://${TF_STATE_BUCKET}" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "State bucket exists: gs://${TF_STATE_BUCKET}"
else
  echo "Creating state bucket: gs://${TF_STATE_BUCKET} in ${REGION}"
  gcloud storage buckets create "gs://${TF_STATE_BUCKET}"     --project "$PROJECT_ID"     --location "$REGION"     --uniform-bucket-level-access
fi

gcloud storage buckets update "gs://${TF_STATE_BUCKET}" --versioning --project "$PROJECT_ID" || true
cat >/tmp/hermes-tofu-state-lifecycle.json <<'JSON'
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 90, "isLive": false}
    }
  ]
}
JSON
gcloud storage buckets update "gs://${TF_STATE_BUCKET}" --lifecycle-file=/tmp/hermes-tofu-state-lifecycle.json --project "$PROJECT_ID" || true
