#!/usr/bin/env bash
# Push the on-disk tofu state to the GCS backend and emit a local backup.
#
# Designed to be called from CI on `if: always()` so a partial apply leaves
# recoverable state behind even if the workflow is later aborted, the runner
# is reused, or the runner's checkout is wiped. Idempotent.

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

# If the local working dir has no state file (e.g. fresh checkout or backend
# was empty), pull from GCS first so the snapshot has something concrete.
if [ ! -f "$STATE_LOCAL" ]; then
  if tofu state pull -no-color > "$STATE_LOCAL" 2>/dev/null; then
    echo "[tofu-state-snapshot] pulled remote state into local $STATE_LOCAL"
  else
    echo "[tofu-state-snapshot] no local or remote state to push (gs://${TF_STATE_BUCKET}/${TF_STATE_PREFIX})"
    exit 0
  fi
fi

cp "$STATE_LOCAL" "$BACKUP"
echo "[tofu-state-snapshot] saved local backup: $BACKUP"

# Clear any stale lock from a crashed previous run, then push.
tofu force-unlock -force 2>/dev/null || true

if tofu state push "$STATE_LOCAL" -no-color 2>&1 | tail -10; then
  echo "[tofu-state-snapshot] pushed to gs://${TF_STATE_BUCKET}/${TF_STATE_PREFIX}/default.tfstate"
else
  echo "[tofu-state-snapshot] WARN: state push failed; local backup at $BACKUP is still safe"
fi

# Print the resource list for log visibility.
echo "[tofu-state-snapshot] resources currently tracked:"
tofu state list -no-color 2>/dev/null | sed 's/^/  - /' || true