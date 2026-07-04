#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs

APP_SOURCE_DIR="${APP_SOURCE_DIR:?APP_SOURCE_DIR is required}"
APP_NAME="${APP_NAME:-app}"
APP_PORT="${APP_PORT:-$DEMO_PORT}"
APP_ENV_FILE="${APP_ENV_FILE:-}"
REMOTE_APP_DIR="${REMOTE_APP_DIR:-/opt/${APP_NAME}}"

cd "$TF_DIR"
NAME=$(tofu output -raw instance_name)
ZONE_OUT=$(tofu output -raw zone | awk -F/ '{print $NF}')
ARCHIVE="$(mktemp -t "${APP_NAME}.XXXXXX.tar.gz")"
REMOTE_ARCHIVE="/tmp/${APP_NAME}.tar.gz"
REMOTE_SCRIPT="/tmp/${APP_NAME}-deploy.sh"
REMOTE_ENV="/tmp/${APP_NAME}.env"

cleanup() {
  rm -f "$ARCHIVE"
}
trap cleanup EXIT

if [ ! -d "$APP_SOURCE_DIR" ]; then
  echo "APP_SOURCE_DIR does not exist: $APP_SOURCE_DIR" >&2
  exit 2
fi

printf 'Packaging app source from %s\n' "$APP_SOURCE_DIR"
tar --exclude='.git' --exclude='__pycache__' --exclude='.pytest_cache' --exclude='.venv' --exclude='venv' -czf "$ARCHIVE" -C "$APP_SOURCE_DIR" .

echo "Uploading app archive to VM: $NAME / $ZONE_OUT"
gcloud compute scp "$ARCHIVE" "$NAME:$REMOTE_ARCHIVE" --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet

if [ -n "$APP_ENV_FILE" ] && [ -f "$APP_ENV_FILE" ]; then
  echo "Uploading provided app env file"
  gcloud compute scp "$APP_ENV_FILE" "$NAME:$REMOTE_ENV" --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet
else
  REMOTE_ENV=""
fi

DEPLOY_SCRIPT_LOCAL="$(mktemp -t "${APP_NAME}.deploy.XXXXXX.sh")"
cat > "$DEPLOY_SCRIPT_LOCAL" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="__APP_NAME__"
APP_PORT="__APP_PORT__"
REMOTE_APP_DIR="__REMOTE_APP_DIR__"
REMOTE_ARCHIVE="__REMOTE_ARCHIVE__"
REMOTE_ENV="__REMOTE_ENV__"

if command -v dnf >/dev/null 2>&1; then
  # Avoid racing the GCE metadata startup script's own dnf transaction.
  for i in $(seq 1 60); do
    if [ -f /opt/hermes-demo/ready ]; then
      break
    fi
    echo "waiting for VM startup bootstrap to finish before package install ($i/60)"
    sleep 5
  done
  dnf -y install podman git curl jq python3
  dnf -y install podman-compose || true
elif command -v yum >/dev/null 2>&1; then
  yum -y install podman git curl jq python3
  yum -y install podman-compose || true
fi

systemctl enable --now podman.socket || true
systemctl stop hermes-demo-health.service 2>/dev/null || true
systemctl disable hermes-demo-health.service 2>/dev/null || true
pkill -f '/opt/hermes-demo/health_server.py' 2>/dev/null || true
if command -v ss >/dev/null 2>&1; then
  for pid in $(ss -ltnp "sport = :$APP_PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u); do
    kill "$pid" 2>/dev/null || true
  done
fi
mkdir -p "$REMOTE_APP_DIR"
rm -rf "${REMOTE_APP_DIR:?}"/*
tar -xzf "$REMOTE_ARCHIVE" -C "$REMOTE_APP_DIR"
cd "$REMOTE_APP_DIR"

if [ -n "$REMOTE_ENV" ] && [ -f "$REMOTE_ENV" ]; then
  install -m 0600 "$REMOTE_ENV" .env
else
  cat > .env <<ENV
HOST_BIND_IP=0.0.0.0
API_PORT=${APP_PORT}
POSTGRES_PORT=5433
POSTGRES_DB=cannabis_rag
POSTGRES_USER=rag
POSTGRES_PASSWORD=rag_dev_password
MOCK_LLM=true
TOP_K=5
GOOGLE_PLACES_ENABLED=false
USE_LLM_INGESTION=false
ENV
  chmod 0600 .env
fi

if podman compose version >/dev/null 2>&1; then
  COMPOSE=(podman compose)
elif command -v podman-compose >/dev/null 2>&1; then
  COMPOSE=(podman-compose)
elif docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
else
  echo "No compose implementation available after package install" >&2
  exit 127
fi

"${COMPOSE[@]}" config >/tmp/${APP_NAME}-compose-config.txt
"${COMPOSE[@]}" up -d --build postgres api
"${COMPOSE[@]}" ps

for i in $(seq 1 60); do
  if curl -fsS --max-time 5 "http://127.0.0.1:${APP_PORT}/health"; then
    echo
    echo "${APP_NAME} compose deployment OK on port ${APP_PORT}"
    exit 0
  fi
  echo "app not ready yet ($i/60)"
  sleep 5
done

echo "${APP_NAME} compose deployment failed health check" >&2
"${COMPOSE[@]}" logs --tail=200 api postgres || true
exit 1
REMOTE

python3 - "$DEPLOY_SCRIPT_LOCAL" "$APP_NAME" "$APP_PORT" "$REMOTE_APP_DIR" "$REMOTE_ARCHIVE" "$REMOTE_ENV" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
repls={
    '__APP_NAME__': sys.argv[2],
    '__APP_PORT__': sys.argv[3],
    '__REMOTE_APP_DIR__': sys.argv[4],
    '__REMOTE_ARCHIVE__': sys.argv[5],
    '__REMOTE_ENV__': sys.argv[6],
}
for k,v in repls.items():
    s=s.replace(k, v)
p.write_text(s)
PY
chmod +x "$DEPLOY_SCRIPT_LOCAL"

gcloud compute scp "$DEPLOY_SCRIPT_LOCAL" "$NAME:$REMOTE_SCRIPT" --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet
rm -f "$DEPLOY_SCRIPT_LOCAL"

echo "Running remote compose deployment"
gcloud compute ssh "$NAME" --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet --command "sudo bash '$REMOTE_SCRIPT'"
