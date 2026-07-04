#!/usr/bin/env bash
# Hardened apply that uploads state even on failure.
#
# Behavior:
#   1. Reconfigure backend so GCS is the source of truth for state.
#   2. Pull any existing remote state into the local working dir
#      (so we don't fail with "Backend reinitialization required").
#   3. Run `tofu apply -auto-approve`.
#   4. ALWAYS push the local state back to GCS, even on failure, so partial
#      applies are recoverable via `tofu destroy` from the same prefix.
#   5. On any apply error, also print the latest state so the user can see
#      which resources were created/modified before the failure.
#
# Idempotent: safe to re-run.

set -uo pipefail   # NOTE: no -e — we must reach the state-upload step on apply failure.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs
write_backend_config
cd "$TF_DIR"

STATE_LOCAL="$TF_DIR/terraform.tfstate"
STATE_BACKUP_DIR="${TF_STATE_BACKUP_DIR:-/tmp/hermes-tofu-state-backups}"
mkdir -p "$STATE_BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$STATE_BACKUP_DIR/${TF_STATE_PREFIX//\//_}__$STAMP.tfstate.json"

upload_state() {
  # Push whatever is on disk to the GCS backend, even if apply failed.
  if [ ! -f "$STATE_LOCAL" ]; then
    echo "[tofu-apply] WARN: no local state file to push ($STATE_LOCAL missing)"
    return 0
  fi
  cp "$STATE_LOCAL" "$BACKUP"
  echo "[tofu-apply] saved local state backup to $BACKUP"
  # Refresh backend lock so stale locks don't block the next destroy.
  tofu force-unlock -force 2>/dev/null || true
  # Replace backend state with whatever is on disk right now. Using `tofu state push`
  # (rather than `tofu state mv` or fresh apply) preserves partial resources so a
  # later `tofu destroy` from the same prefix can clean them up.
  if tofu state push "$STATE_LOCAL" 2>&1 | tee /tmp/hermes-tofu-state-push.log; then
    echo "[tofu-apply] pushed state to backend (gs://${TF_STATE_BUCKET}/${TF_STATE_PREFIX})"
  else
    rc=$?
    echo "[tofu-apply] WARN: state push failed (rc=$rc); local backup is at $BACKUP"
    return $rc
  fi
}

# Reconfigure backend (idempotent if bucket/prefix already configured).
tofu init -input=false -reconfigure -backend-config=backend.hcl -no-color

# Pull any existing remote state so we are not "behind" the backend. If the
# remote state is empty/missing, this is a no-op.
tofu state pull -no-color > "$STATE_LOCAL" 2>/dev/null || true

# Run apply with -lock-timeout so a stuck lock fails loudly instead of hanging.
set +e
tofu apply -auto-approve -lock-timeout=5m -no-color $(tofu_vars)
APPLY_RC=$?
set -e

# Always push the local state, regardless of apply outcome.
upload_state

if [ "$APPLY_RC" -ne 0 ]; then
  echo "[tofu-apply] apply failed with rc=$APPLY_RC; state was still uploaded"
  echo "[tofu-apply] recent resources in current state:"
  tofu state list -no-color 2>/dev/null | sed 's/^/  - /' || true
  exit "$APPLY_RC"
fi

# Only run `tofu output` after a successful apply.
tofu output -no-color