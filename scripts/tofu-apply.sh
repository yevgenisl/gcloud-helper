#!/usr/bin/env bash
# Hardened apply. The backend (GCS) is the source of truth for state; we only
# touch the local working dir to capture a backup of whatever apply produced.
#
# Behavior:
#   1. Reconfigure backend so GCS is the source of truth for state.
#   2. Run `tofu apply -auto-approve` with a sane lock timeout.
#   3. ALWAYS capture a timestamped backup of the post-apply state (whether
#      apply succeeded or failed) so a later destroy / re-apply can recover.
#   4. On any apply error, print the resource list so you can see what got
#      created/modified before the failure.
#
# Idempotent: safe to re-run.
#
# Why we do NOT do `tofu state push` after apply:
#   - `tofu apply` already wrote the canonical state to the GCS backend.
#   - The on-disk `terraform.tfstate` is the SAME serial tofu applied with; if
#     we pulled at startup and then applied, the local file may even be older
#     than the backend serial and `tofu state push` will reject it.
#   - Pushing state we didn't author is also a foot-gun: it can clobber parallel
#     updates and masks real conflicts. The dedicated snapshot step (called on
#     `if: always()` in CI) handles recovery without that risk.

set -uo pipefail   # NOTE: no -e — we must reach the backup step on apply failure.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs
write_backend_config
cd "$TF_DIR"

STATE_LOCAL="$TF_DIR/terraform.tfstate"
STATE_BACKUP_DIR="${TF_STATE_BACKUP_DIR:-/tmp/hermes-tofu-state-backups}"
mkdir -p "$STATE_BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SAFE_PREFIX="$(printf '%s' "$TF_STATE_PREFIX" | tr '/' '_')"
BACKUP="$STATE_BACKUP_DIR/${SAFE_PREFIX}__$STAMP.tfstate.json"

backup_state() {
  # Pull the canonical state from the backend (apply wrote it there). If for
  # some reason the local file is fresher than the backend serial, prefer the
  # local file — that's the only case where the local file might be newer.
  local pulled=""
  if pulled="$(tofu state pull -no-color 2>/dev/null)"; then
    if [ -n "$pulled" ]; then
      printf '%s' "$pulled" > "$BACKUP"
      echo "[tofu-apply] saved backend state snapshot to $BACKUP"
      return 0
    fi
  fi
  if [ -f "$STATE_LOCAL" ] && [ -s "$STATE_LOCAL" ]; then
    cp "$STATE_LOCAL" "$BACKUP"
    echo "[tofu-apply] saved local state backup to $BACKUP (backend pull empty)"
    return 0
  fi
  echo "[tofu-apply] WARN: could not capture state snapshot (both backend pull and local file empty)"
  return 0
}

# Extract the GCS lock ID from a tofu state-lock error block.
extract_lock_id() {
  awk '
    /^[[:space:]]*ID:[[:space:]]*/ { print $2; exit }
    /^Lock Info:/ { in_block=1; next }
    in_block && /^[[:space:]]+ID:[[:space:]]*/ { print $2; exit }
  '
}

# If a previous run left a stale GCS state lock, parse the error, unlock, retry.
with_lock_recovery() {
  local log
  log="$(mktemp)"
  set +e
  "$@" 2> >(tee "$log.stderr" >&2) > >(tee "$log")
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    rm -f "$log" "$log.stderr"
    return 0
  fi
  local lock_id
  lock_id="$(cat "$log.stderr" 2>/dev/null | extract_lock_id || true)"
  if [ -z "$lock_id" ]; then
    lock_id="$(cat "$log" 2>/dev/null | extract_lock_id || true)"
  fi
  if [ -n "$lock_id" ]; then
    echo "[tofu-apply] stale state lock detected (id=$lock_id); unlocking and retrying"
    if tofu force-unlock -force "$lock_id" -no-color 2>&1 | tail -5; then
      set +e
      "$@"
      rc=$?
      set -e
    else
      echo "[tofu-apply] WARN: force-unlock failed; lock may need manual cleanup"
    fi
  fi
  rm -f "$log" "$log.stderr"
  return "$rc"
}

# Proactively clear any stale state lock left by an aborted previous run.
clear_stale_lock() {
  local lock_path="gs://${TF_STATE_BUCKET}/${TF_STATE_PREFIX}/default.tflock"
  local max_age_minutes="${STALE_LOCK_MAX_AGE_MINUTES:-30}"
  if ! gcloud storage ls "$lock_path" >/dev/null 2>&1; then
    return 0
  fi
  local updated
  updated="$(gcloud storage ls -L "$lock_path" 2>/dev/null \
    | awk '/^[[:space:]]+Update Time:[[:space:]]*/ { sub(/^[[:space:]]+Update Time:[[:space:]]*/, ""); print; exit }')"
  if [ -z "$updated" ]; then
    return 0
  fi
  local age_minutes
  local updated_epoch
  if ! updated_epoch="$(rfc3339_to_epoch "$updated")"; then
    echo "[tofu-apply] WARN: could not parse lock update time '$updated'; leaving lock untouched"
    return 0
  fi
  age_minutes=$(( ( $(date -u +%s) - updated_epoch ) / 60 ))
  if [ "$age_minutes" -lt "$max_age_minutes" ]; then
    echo "[tofu-apply] state lock is $age_minutes min old (< $max_age_minutes); leaving it alone"
    return 0
  fi
  echo "[tofu-apply] clearing stale state lock at $lock_path ($age_minutes min old)"
  if gcloud storage rm "$lock_path" 2>&1 | tail -3; then
    echo "[tofu-apply] stale lock removed"
  else
    echo "[tofu-apply] WARN: failed to clear stale lock; tofu will surface the error"
  fi
}

# Reconfigure backend (idempotent if bucket/prefix already configured).
tofu init -input=false -reconfigure -backend-config=backend.hcl -no-color

clear_stale_lock

# Run apply with -lock-timeout so a stuck lock fails loudly instead of hanging.
set +e
with_lock_recovery tofu apply -auto-approve -lock-timeout=5m -no-color $(tofu_vars)
APPLY_RC=$?
set -e

# Always capture a backup, regardless of apply outcome.
backup_state

if [ "$APPLY_RC" -ne 0 ]; then
  echo "[tofu-apply] apply failed with rc=$APPLY_RC; backup is at $BACKUP"
  echo "[tofu-apply] resources currently tracked:"
  tofu state list -no-color 2>/dev/null | sed 's/^/  - /' || true
  exit "$APPLY_RC"
fi

# Only run `tofu output` after a successful apply.
tofu output -no-color