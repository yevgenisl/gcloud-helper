#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs
write_backend_config
cd "$TF_DIR"
tofu destroy -auto-approve $(tofu_vars)
