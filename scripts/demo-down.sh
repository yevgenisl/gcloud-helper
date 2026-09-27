#!/usr/bin/env bash
if [[ "${DEMO_TARGET:-vm}" == gke ]]; then
  exec python3 "$(dirname "${BASH_SOURCE[0]}")/../infra/gcp-demo-gke/lifecycle.py" destroy "$@"
fi
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs
write_backend_config
cd "$TF_DIR"
tofu destroy -auto-approve $(tofu_vars)
