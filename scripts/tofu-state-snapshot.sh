#!/usr/bin/env bash
# Capture a snapshot of the current backend state into a timestamped backup
# file. Designed to be called from CI on `if: always()` so a partial apply
# leaves recoverable state behind even if the workflow is later aborted.
# Idempotent.
#
# Why no `tofu state push`:
#   `tofu apply` / `tofu destroy` already wrote the canonical state to the GCS
#   backend. This script's only job is to make sure a local backup exists so a
#   runner cleanup / aborted workflow doesn't strand the state on disk.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs
write_backend_config
cd "$TF_DIR"

STATE_LOCAL="$TF_DIR/terraform.tfstate"
BACKUP_DIR="${TF_STATE_BACKUP_DIR:-/tmp/hermes-tofu-state-backups}"
mkdir -p "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SAFE_PREFIX="$(printf '%s' "$TF_STATE_PREFIX" | tr '/' '_')"
BACKUP="$BACKUP_DIR/${SAFE_PREFIX}__$STAMP.tfstate.json"

tofu init -input=false -reconfigure -backend-config=backend.hcl -no-color >/dev/null 2>&1 || true

# Prefer backend (canonical). Fall back to local if backend pull fails.
pulled="$(tofu state pull -no-color 2>/dev/null || true)"
if [ -n "$pulled" ]; then
  printf '%s' "$pulled" > "$BACKUP"
  echo "[tofu-state-snapshot] saved backend state snapshot: $BACKUP"
elif [ -f "$STATE_LOCAL" ] && [ -s "$STATE_LOCAL" ]; then
  cp "$STATE_LOCAL" "$BACKUP"
  echo "[tofu-state-snapshot] saved local state snapshot (backend pull empty): $BACKUP"
else
  echo "[tofu-state-snapshot] no state to snapshot (gs://${TF_STATE_BUCKET}/${TF_STATE_PREFIX})"
  exit 0
fi

# Print the resource list for log visibility.
echo "[tofu-state-snapshot] resources currently tracked:"
tofu state list -no-color 2>/dev/null | sed 's/^/  - /' || true