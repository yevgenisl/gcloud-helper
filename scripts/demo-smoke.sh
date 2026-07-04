#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs
cd "$TF_DIR"
URL=$(tofu output -raw demo_url)
HEALTH="$URL/health"
NAME=$(tofu output -raw instance_name)
ZONE_OUT=$(tofu output -raw zone | awk -F/ '{print $NF}')
echo "Waiting for in-VM health endpoint via gcloud compute ssh: $NAME / $ZONE_OUT"
for i in $(seq 1 60); do
  if gcloud compute ssh "$NAME" --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet --command "curl -fsS --max-time 5 http://127.0.0.1:${DEMO_PORT}/health" | tee /tmp/hermes-demo-health.json; then
    echo
    echo "Smoke test OK via SSH. Public URL, if firewall allows it: $HEALTH"
    exit 0
  fi
  echo "not ready yet ($i/60)"
  sleep 10
done
echo "Smoke test failed: $HEALTH" >&2
exit 1
