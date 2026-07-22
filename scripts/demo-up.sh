#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs
# The backend is selected dynamically from ENVIRONMENT/RUN_ID.  Merely
# rewriting backend.hcl is insufficient when this checkout was previously
# initialized for another demo: OpenTofu keeps its active backend in
# .terraform/terraform.tfstate.  Reconfigure before apply so the requested
# state prefix, not stale local metadata, is used.
write_backend_config
cd "$TF_DIR"
tofu init -input=false -reconfigure -backend-config=backend.hcl -no-color
tofu apply -auto-approve -lock-timeout=5m -no-color $(tofu_vars)
tofu output -no-color
