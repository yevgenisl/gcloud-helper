#!/usr/bin/env bash
# Hardened destroy that pulls fresh state and uploads the post-destroy state.
#
# Behavior:
#   1. Reconfigure backend.
#   2. Pull the latest remote state into local working dir, so we never see
#      "Backend initialization required" even after a previous failed apply.
#   3. Run `tofu destroy -auto-approve`.
#   4. ALWAYS push the post-destroy state to GCS so subsequent applies start
#      from a known-clean backend.
#   5. Best-effort cleanup of any orphan resources matching the stack prefix
#      (defense-in-depth for cases where state was empty but a real instance
#      still exists, like the 2026-07-04 canabis-assistant-api-28 incident).

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs
write_backend_config
cd "$TF_DIR"

STATE_LOCAL="$TF_DIR/terraform.tfstate"
SAFE_RUN_ID="$(printf '%s' "$RUN_ID" | tr -c '[:alnum:]-' '-' | cut -c1-24)"
NAME_PREFIX="hermes-demo-${SAFE_RUN_ID}"
ZONE="${ZONE:-europe-west1-b}"
PROJECT_ID="${PROJECT_ID:-canaverse}"

upload_state() {
  if [ ! -f "$STATE_LOCAL" ]; then
    return 0
  fi
  tofu force-unlock -force 2>/dev/null || true
  if tofu state push "$STATE_LOCAL" -no-color 2>&1 | tail -5; then
    echo "[tofu-destroy] pushed state to backend"
  else
    echo "[tofu-destroy] WARN: state push failed; local state retained at $STATE_LOCAL"
  fi
}

orphan_cleanup() {
  # If a previous apply crashed so badly that state was never written but the
  # VM was still created, this catches the orphan by name prefix.
  if command -v gcloud >/dev/null 2>&1; then
    local found
    found="$(gcloud compute instances list --project="$PROJECT_ID" \
              --format='value(name)' 2>/dev/null | grep -F "$NAME_PREFIX" || true)"
    if [ -n "$found" ]; then
      echo "[tofu-destroy] orphan instance(s) matching $NAME_PREFIX — deleting via gcloud:"
      printf '%s\n' "$found" | sed 's/^/  - /'
      while IFS= read -r inst; do
        [ -z "$inst" ] && continue
        gcloud compute instances delete "$inst" --zone="$ZONE" \
          --project="$PROJECT_ID" --quiet 2>&1 | tail -3 | sed 's/^/    /'
      done <<< "$found"
    fi
  fi
}

# Reconfigure backend (idempotent).
tofu init -input=false -reconfigure -backend-config=backend.hcl -no-color

# Pull the latest remote state so destroy sees whatever partial resources the
# previous (possibly failed) apply left in the backend.
tofu state pull -no-color > "$STATE_LOCAL" 2>/dev/null || true

set +e
tofu destroy -auto-approve -lock-timeout=5m -no-color $(tofu_vars)
DESTROY_RC=$?
set -e

# Defense-in-depth: if tofu had nothing to destroy, still catch orphan VMs by
# the name prefix so the workflow never leaves live resources behind.
orphan_cleanup

upload_state

if [ "$DESTROY_RC" -ne 0 ]; then
  echo "[tofu-destroy] destroy failed with rc=$DESTROY_RC; state was still uploaded"
  exit "$DESTROY_RC"
fi