#!/usr/bin/env bash
# Generic docker-compose deployer for a gcloud-helper demo VM.
#
# Responsibilities (kept deliberately small so callers can specialize):
#   - Resolve VM name/zone from OpenTofu output
#   - Tar up the caller's source dir, scp it to the VM
#   - Optionally scp a caller-rendered .env, GAR auth token, post-deploy script
#   - scp the generic remote deploy script and execute it on the VM
#
# Application-specific concerns (default .env, schema bootstrap, post-deploy
# SQL, etc.) belong in the caller workflow, not here.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs

APP_SOURCE_DIR="${APP_SOURCE_DIR:?APP_SOURCE_DIR is required}"
APP_NAME="${APP_NAME:-app}"
APP_PORT="${APP_PORT:-$DEMO_PORT}"
APP_ENV_FILE="${APP_ENV_FILE:-}"
APP_COMPOSE_SUBDIR="${APP_COMPOSE_SUBDIR:-}"
APP_HEALTH_PROBES="${APP_HEALTH_PROBES:-http://127.0.0.1:${APP_PORT}/}"
APP_GAR_REGISTRY="${APP_GAR_REGISTRY:-}"
APP_GAR_TOKEN_FILE="${APP_GAR_TOKEN_FILE:-}"
APP_POST_DEPLOY_SCRIPT="${APP_POST_DEPLOY_SCRIPT:-}"
REMOTE_APP_DIR="${REMOTE_APP_DIR:-/opt/${APP_NAME}}"

cd "$TF_DIR"
NAME=$(tofu output -raw instance_name)
ZONE_OUT=$(tofu output -raw zone | awk -F/ '{print $NF}')

ARCHIVE="$(mktemp -t "${APP_NAME}.XXXXXX.tar.gz")"
REMOTE_ARCHIVE="/tmp/${APP_NAME}.tar.gz"
REMOTE_SCRIPT="/tmp/${APP_NAME}-deploy.sh"
REMOTE_ENV="/tmp/${APP_NAME}.env"
REMOTE_GAR_TOKEN="/tmp/${APP_NAME}.gar-token"
REMOTE_POST_DEPLOY="/tmp/${APP_NAME}-post-deploy.sh"

trap 'rm -f "$ARCHIVE"' EXIT

[ -d "$APP_SOURCE_DIR" ] || { echo "APP_SOURCE_DIR does not exist: $APP_SOURCE_DIR" >&2; exit 2; }

# --- Package and upload source ------------------------------------------------
printf 'Packaging app source from %s\n' "$APP_SOURCE_DIR"
tar --exclude='.git' --exclude='__pycache__' --exclude='.pytest_cache' \
    --exclude='.venv' --exclude='venv' \
    -czf "$ARCHIVE" -C "$APP_SOURCE_DIR" .

scp_to_vm() {
  if [ -z "$1" ] || [ ! -e "$1" ]; then return 1; fi
  gcloud compute scp "$1" "$NAME:$2" --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet
  echo "  + $3 uploaded"
}

echo "Uploading to VM $NAME / $ZONE_OUT:"
gcloud compute scp "$ARCHIVE" "$NAME:$REMOTE_ARCHIVE" --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet
echo "  + app source archive"
scp_to_vm "$APP_ENV_FILE" "$REMOTE_ENV" "app .env" || REMOTE_ENV=""
scp_to_vm "$APP_GAR_TOKEN_FILE" "$REMOTE_GAR_TOKEN" "GAR auth token" || REMOTE_GAR_TOKEN=""
scp_to_vm "$APP_POST_DEPLOY_SCRIPT" "$REMOTE_POST_DEPLOY" "post-deploy script" || REMOTE_POST_DEPLOY=""

# --- Run the generic remote deploy script on the VM -------------------------
REMOTE_SCRIPT_SRC="$(dirname "${BASH_SOURCE[0]}")/deploy-compose-remote.sh"
gcloud compute scp "$REMOTE_SCRIPT_SRC" "$NAME:$REMOTE_SCRIPT" \
    --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet

# Pass caller-specific values to the remote script via env vars
echo "Running remote compose deployment"
gcloud compute ssh "$NAME" --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet \
    --command "sudo env \
        APP_NAME='$APP_NAME' \
        APP_PORT='$APP_PORT' \
        REMOTE_APP_DIR='$REMOTE_APP_DIR' \
        REMOTE_ARCHIVE='$REMOTE_ARCHIVE' \
        REMOTE_ENV='$REMOTE_ENV' \
        REMOTE_GAR_TOKEN='$REMOTE_GAR_TOKEN' \
        REMOTE_POST_DEPLOY='$REMOTE_POST_DEPLOY' \
        APP_COMPOSE_SUBDIR='$APP_COMPOSE_SUBDIR' \
        APP_HEALTH_PROBES='$APP_HEALTH_PROBES' \
        APP_GAR_REGISTRY_HOST='https://${APP_GAR_REGISTRY}' \
        bash '$REMOTE_SCRIPT'"
