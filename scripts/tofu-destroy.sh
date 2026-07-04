#!/usr/bin/env bash
# Hardened destroy.
#
# Behavior:
#   1. Reconfigure backend.
#   2. Pull the latest remote state into local working dir so we never see
#      "Backend initialization required" even after a previous failed apply.
#   3. Run `tofu destroy -auto-approve`.
#   4. After destroy, capture a backup of the post-destroy state (which may
#      be empty after the last resource is removed).
#   5. Defense-in-depth: delete any orphan VM matching the run_id prefix, so a
#      previous apply that crashed before writing state still gets cleaned.
#
# Note: we deliberately do NOT call `tofu state push` after destroy. The apply
# step already wrote the canonical state; destroy wrote a post-destroy state
# (possibly empty) back to the same backend. Pushing again is just a foot-gun.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs
write_backend_config
cd "$TF_DIR"

STATE_LOCAL="$TF_DIR/terraform.tfstate"
STATE_BACKUP_DIR="${TF_STATE_BACKUP_DIR:-/tmp/hermes-tofu-state-backups}"
mkdir -p "$STATE_BACKUP_DIR"
SAFE_RUN_ID="$(printf '%s' "$RUN_ID" | tr -c '[:alnum:]-' '-' | cut -c1-24)"
NAME_PREFIX="hermes-demo-${SAFE_RUN_ID}"
ZONE="${ZONE:-europe-west1-b}"
PROJECT_ID="${PROJECT_ID:-canaverse}"

orphan_cleanup() {
  # If a previous apply crashed so badly that state was never written but the
  # VM/firewall was still created, this catches the orphans by name prefix.
  # Best-effort: each resource type is checked independently so one failure
  # (e.g., insufficient IAM for firewalls) does not block the rest.
  if ! command -v gcloud >/dev/null 2>&1; then
    return 0
  fi

  # 1. Orphan instances.
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

  # 2. Orphan firewalls (created with count = create_firewall_rules ? 1 : 0;
  #    the prefix is the same as the VM name so the existing grep works).
  local fw_found
  fw_found="$(gcloud compute firewall-rules list --project="$PROJECT_ID" \
              --format='value(name)' 2>/dev/null | grep -F "$NAME_PREFIX" || true)"
  if [ -n "$fw_found" ]; then
    echo "[tofu-destroy] orphan firewall(s) matching $NAME_PREFIX — deleting via gcloud:"
    printf '%s\n' "$fw_found" | sed 's/^/  - /'
    while IFS= read -r fw; do
      [ -z "$fw" ] && continue
      gcloud compute firewall-rules delete "$fw" --project="$PROJECT_ID" --quiet \
        2>&1 | tail -3 | sed 's/^/    /'
    done <<< "$fw_found"
  fi
}

# Extract the GCS lock ID from a tofu state-lock error block. Tofu prints
# something like:
#   ID:        1783190509272685
#   Path:      gs://.../default.tflock
extract_lock_id() {
  awk '
    /^[[:space:]]*ID:[[:space:]]*/ { print $2; exit }
    /^Lock Info:/ { in_block=1; next }
    in_block && /^[[:space:]]+ID:[[:space:]]*/ { print $2; exit }
  '
}

# If a previous run left a stale GCS state lock, parse the error,
# unlocks the backend, and retries the original command. Designed for the
# case where a CI job was aborted mid-apply.
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
    echo "[tofu-destroy] stale state lock detected (id=$lock_id); unlocking and retrying"
    if tofu force-unlock -force "$lock_id" -no-color 2>&1 | tail -5; then
      set +e
      "$@"
      rc=$?
      set -e
    else
      echo "[tofu-destroy] WARN: force-unlock failed; lock may need manual cleanup"
    fi
  fi
  rm -f "$log" "$log.stderr"
  return "$rc"
}

# Proactively clear a stale GCS state lock file if it exists. Tofu's lock
# contains a timestamp we can age-check; if it's older than STALE_LOCK_MAX_AGE
# (default 30 minutes), this is almost certainly an aborted run and we delete
# the lock directly. If the lock is fresh, leave it alone — a concurrent run
# is using it.
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
  age_minutes=$(( ( $(date -u +%s) - $(date -u -d "$updated" +%s) ) / 60 ))
  if [ "$age_minutes" -lt "$max_age_minutes" ]; then
    echo "[tofu-destroy] state lock is $age_minutes min old (< $max_age_minutes); leaving it alone"
    return 0
  fi
  echo "[tofu-destroy] clearing stale state lock at $lock_path ($age_minutes min old)"
  if gcloud storage rm "$lock_path" 2>&1 | tail -3; then
    echo "[tofu-destroy] stale lock removed"
  else
    echo "[tofu-destroy] WARN: failed to clear stale lock; tofu will surface the error"
  fi
}

backup_state() {
  local pulled=""
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local safe_prefix
  safe_prefix="$(printf '%s' "$TF_STATE_PREFIX" | tr '/' '_')"
  local backup="$STATE_BACKUP_DIR/${safe_prefix}__${stamp}.tfstate.json"
  if pulled="$(tofu state pull -no-color 2>/dev/null)"; then
    printf '%s' "$pulled" > "$backup"
    echo "[tofu-destroy] saved post-destroy backend state to $backup"
    return 0
  fi
  if [ -f "$STATE_LOCAL" ] && [ -s "$STATE_LOCAL" ]; then
    cp "$STATE_LOCAL" "$backup"
    echo "[tofu-destroy] saved post-destroy local state to $backup (backend pull empty)"
    return 0
  fi
  echo "[tofu-destroy] WARN: could not capture post-destroy state snapshot"
  return 0
}

# Reconfigure backend (idempotent).
tofu init -input=false -reconfigure -backend-config=backend.hcl -no-color

# Proactively clear any stale state lock left by an aborted previous run.
clear_stale_lock

# Pull the latest remote state so destroy sees whatever partial resources the
# previous (possibly failed) apply left in the backend. Tofu destroy needs the
# local state to know what to tear down.
if pulled="$(tofu state pull -no-color 2>/dev/null)"; then
  printf '%s' "$pulled" > "$STATE_LOCAL"
fi

set +e
with_lock_recovery tofu destroy -auto-approve -lock-timeout=5m -no-color $(tofu_vars)
DESTROY_RC=$?
set -e

# Defense-in-depth: even if tofu had nothing in state, catch orphan VMs.
orphan_cleanup

backup_state

if [ "$DESTROY_RC" -ne 0 ]; then
  echo "[tofu-destroy] destroy failed with rc=$DESTROY_RC"
  exit "$DESTROY_RC"
fi