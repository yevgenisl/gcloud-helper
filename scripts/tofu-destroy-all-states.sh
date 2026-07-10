#!/usr/bin/env bash
# Destroy every gcp-demo-vm OpenTofu state found in the GCS backend bucket.
#
# The single-state destroy implementation lives in scripts/tofu-destroy.sh.  This
# wrapper discovers all remote state prefixes under:
#
#   gs://$TF_STATE_BUCKET/superapp-demo/<environment>/<run_id>/default.tfstate
#
# and runs tofu-destroy.sh once per prefix with ENVIRONMENT/RUN_ID/TF_STATE_PREFIX
# set from the object path.
#
# Useful env vars:
#   PROJECT_ID=canaverse                 GCP project; default comes from common.sh
#   TF_STATE_BUCKET=canaverse-tofu-state GCS backend bucket; default project-tofu-state
#   STATE_ROOT=superapp-demo             Root prefix to scan
#   ENVIRONMENT_FILTER=ci                Optional exact environment filter
#   RUN_ID_FILTER=demo                   Optional exact run_id filter
#   DRY_RUN=true                         Print what would be destroyed, do not destroy
#   CONTINUE_ON_ERROR=false              Stop at first failed destroy; default continues
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
ensure_prereqs

STATE_ROOT="${STATE_ROOT:-superapp-demo}"
ENVIRONMENT_FILTER="${ENVIRONMENT_FILTER:-}"
RUN_ID_FILTER="${RUN_ID_FILTER:-}"
DRY_RUN="${DRY_RUN:-false}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-true}"

list_state_objects() {
  gcloud storage ls -r "gs://${TF_STATE_BUCKET}/${STATE_ROOT}/" 2>/dev/null \
    | grep -E '/default\.tfstate$' \
    | sort -u || true
}

state_has_resources() {
  local object="$1"
  local count
  count="$(gcloud storage cat "$object" 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print(-1)
    sys.exit(0)
print(len(data.get("resources") or []))
')"
  case "$count" in
    ''|-1) echo "unknown" ;;
    *) echo "$count" ;;
  esac
}

printf '[tofu-destroy-all-states] bucket: gs://%s\n' "$TF_STATE_BUCKET"
printf '[tofu-destroy-all-states] root:   %s\n' "$STATE_ROOT"
[ -z "$ENVIRONMENT_FILTER" ] || printf '[tofu-destroy-all-states] environment filter: %s\n' "$ENVIRONMENT_FILTER"
[ -z "$RUN_ID_FILTER" ] || printf '[tofu-destroy-all-states] run_id filter: %s\n' "$RUN_ID_FILTER"
[ "$DRY_RUN" != "true" ] || printf '[tofu-destroy-all-states] DRY RUN ONLY\n'

mapfile -t state_objects < <(list_state_objects)
if [ "${#state_objects[@]}" -eq 0 ]; then
  echo "[tofu-destroy-all-states] no state files found"
  exit 0
fi

selected=()
for object in "${state_objects[@]}"; do
  rel="${object#gs://${TF_STATE_BUCKET}/${STATE_ROOT}/}"
  rel="${rel%/default.tfstate}"
  IFS='/' read -r env run_id extra <<< "$rel"
  if [ -z "${env:-}" ] || [ -z "${run_id:-}" ] || [ -n "${extra:-}" ]; then
    echo "[tofu-destroy-all-states] skipping unexpected state path: $object"
    continue
  fi
  if [ -n "$ENVIRONMENT_FILTER" ] && [ "$env" != "$ENVIRONMENT_FILTER" ]; then
    continue
  fi
  if [ -n "$RUN_ID_FILTER" ] && [ "$run_id" != "$RUN_ID_FILTER" ]; then
    continue
  fi
  selected+=("$env/$run_id|$object")
done

if [ "${#selected[@]}" -eq 0 ]; then
  echo "[tofu-destroy-all-states] no state files matched filters"
  exit 0
fi

printf '[tofu-destroy-all-states] selected %d state(s):\n' "${#selected[@]}"
for item in "${selected[@]}"; do
  env_run="${item%%|*}"
  object="${item#*|}"
  resource_count="$(state_has_resources "$object")"
  printf '  - %-40s resources=%s  %s\n' "$env_run" "$resource_count" "$object"
done

if [ "$DRY_RUN" = "true" ]; then
  exit 0
fi

failed=()
succeeded=()

for item in "${selected[@]}"; do
  env_run="${item%%|*}"
  env="${env_run%%/*}"
  run_id="${env_run#*/}"
  prefix="${STATE_ROOT}/${env}/${run_id}"

  echo
  echo "======================================================================"
  echo "[tofu-destroy-all-states] destroying ENVIRONMENT=$env RUN_ID=$run_id PREFIX=$prefix"
  echo "======================================================================"

  # Run in a subshell so each destroy gets a clean environment without leaking
  # mutated TF_STATE_PREFIX/RUN_ID values into the next iteration.
  (
    export ENVIRONMENT="$env"
    export RUN_ID="$run_id"
    export TF_STATE_PREFIX="$prefix"
    export TF_STATE_BUCKET PROJECT_ID REGION ZONE

    # The same working directory is reused for many backend prefixes. Remove
    # cached backend metadata and any pulled local state before every init so
    # OpenTofu never tries to perform an interactive backend state migration
    # between prefixes.
    rm -rf "$TF_DIR/.terraform" "$TF_DIR/terraform.tfstate" "$TF_DIR/terraform.tfstate.backup"

    "$SCRIPT_DIR/tofu-destroy.sh"
  )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    succeeded+=("$env_run")
  else
    failed+=("$env_run:$rc")
    echo "[tofu-destroy-all-states] ERROR: destroy failed for $env_run with rc=$rc"
    if [ "$CONTINUE_ON_ERROR" != "true" ]; then
      break
    fi
  fi
done

echo
echo "======================================================================"
echo "[tofu-destroy-all-states] summary"
echo "======================================================================"
printf 'succeeded (%d):\n' "${#succeeded[@]}"
printf '  - %s\n' "${succeeded[@]:-none}"
printf 'failed (%d):\n' "${#failed[@]}"
printf '  - %s\n' "${failed[@]:-none}"

if [ "${#failed[@]}" -ne 0 ]; then
  exit 1
fi
