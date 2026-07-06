#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs
cd "$TF_DIR"
URL=$(tofu output -raw demo_url)
NAME=$(tofu output -raw instance_name)
ZONE_OUT=$(tofu output -raw zone | awk -F/ '{print $NF}')

# Default health probes. These URLs are curled through `gcloud compute
# ssh` into the VM (loopback), so 127.0.0.1 is correct. We accept
# any 2xx-4xx HTTP response as proof the upstream is up. 5xx and
# connection failures mean "not ready yet".
#
# The single `/health` probe we used historically doesn't match the
# lolian/superapp stack: nginx serves the SPA at `/`, and there's no
# `/health` exposed on the public path. Multi-target probes catch
# both nginx (frontend) and the backend API.
#
# Callers can override via APP_HEALTH_PROBES — the same env var the
# deploy-compose script reads — so the deploy probe and the smoke
# probe stay in sync. See examples/caller-workflow.yaml.
APP_HEALTH_PROBES="${APP_HEALTH_PROBES:-http://127.0.0.1:${DEMO_PORT}/ http://127.0.0.1:${DEMO_PORT}/api/categories}"

probe_remote() {
  local url="$1"
  local code
  code="$(gcloud compute ssh "$NAME" --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet \
    --command "curl -ks -o /dev/null -w '%{http_code}' --max-time 5 '$url' || echo 000" 2>/dev/null \
    | tr -d '[:space:]')"
  case "$code" in
    2*|3*|4*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Smoke test via gcloud compute ssh: $NAME / $ZONE_OUT"
echo "Probes: $APP_HEALTH_PROBES"
for i in $(seq 1 60); do
  all_ok=1
  for url in $APP_HEALTH_PROBES; do
    if probe_remote "$url"; then
      :
    else
      all_ok=0
      printf '  [%d/60] %s not ready\n' "$i" "$url"
      break
    fi
  done
  if [ "$all_ok" = "1" ]; then
    echo
    echo "Smoke test OK via SSH. Public URL (firewall permitting): $URL"
    for url in $APP_HEALTH_PROBES; do
      code="$(gcloud compute ssh "$NAME" --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet \
        --command "curl -ks -o /dev/null -w '%{http_code}' --max-time 5 '$url' || echo 000" 2>/dev/null \
        | tr -d '[:space:]')"
      printf '  %s -> HTTP %s\n' "$url" "$code"
    done
    exit 0
  fi
  sleep 10
done

echo "Smoke test failed: $URL (no probe returned 2xx-4xx within 10 minutes)" >&2
exit 1
