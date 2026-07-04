#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs
cd "$TF_DIR"
if ! tofu output -json >/tmp/hermes-demo-output.json; then
  echo "No OpenTofu outputs found. Has demo-up run?" >&2
  exit 1
fi
python3 - <<'PY'
import json
out=json.load(open('/tmp/hermes-demo-output.json'))
for key in ['instance_name','zone','external_ip','demo_url','ssh_command']:
    print(f"{key}: {out[key]['value']}")
PY
NAME=$(python3 - <<'PY'
import json; print(json.load(open('/tmp/hermes-demo-output.json'))['instance_name']['value'])
PY
)
ZONE_OUT=$(python3 - <<'PY'
import json; print(json.load(open('/tmp/hermes-demo-output.json'))['zone']['value'].split('/')[-1])
PY
)
gcloud compute instances describe "$NAME" --zone "$ZONE_OUT" --project "$PROJECT_ID" --format='table(name,status,machineType.basename(),networkInterfaces[0].accessConfigs[0].natIP)'
