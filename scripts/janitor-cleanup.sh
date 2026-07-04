#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs
TTL_HOURS="${TTL_HOURS:-24}"
echo "Listing stale hermes ci-demo instances older than ${TTL_HOURS}h in project ${PROJECT_ID}"
python3 - <<'PY' > /tmp/hermes-stale-cutoff
from datetime import datetime, timezone, timedelta
import os
print((datetime.now(timezone.utc)-timedelta(hours=int(os.environ.get('TTL_HOURS','24')))).isoformat())
PY
CUTOFF=$(cat /tmp/hermes-stale-cutoff)
gcloud compute instances list --project "$PROJECT_ID"   --filter="labels.owner=hermes AND labels.purpose=ci-demo AND creationTimestamp<${CUTOFF}"   --format='value(name,zone)' | while read -r NAME ZONE_URL; do
    [ -n "$NAME" ] || continue
    ZONE_NAME="${ZONE_URL##*/}"
    echo "Deleting stale instance $NAME in $ZONE_NAME"
    gcloud compute instances delete "$NAME" --zone "$ZONE_NAME" --project "$PROJECT_ID" --quiet
  done
