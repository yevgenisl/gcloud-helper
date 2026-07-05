#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_prereqs

APP_SOURCE_DIR="${APP_SOURCE_DIR:?APP_SOURCE_DIR is required}"
APP_NAME="${APP_NAME:-app}"
APP_PORT="${APP_PORT:-$DEMO_PORT}"
APP_ENV_FILE="${APP_ENV_FILE:-}"
GAR_TOKEN_FILE="${GAR_TOKEN_FILE:-}"
GAR_REGISTRY="${GAR_REGISTRY:-}"
GAR_REGISTRY_HOST="${GAR_REGISTRY_HOST:-https://${GAR_REGISTRY:-}}"
REMOTE_APP_DIR="${REMOTE_APP_DIR:-/opt/${APP_NAME}}"

cd "$TF_DIR"
NAME=$(tofu output -raw instance_name)
ZONE_OUT=$(tofu output -raw zone | awk -F/ '{print $NF}')
ARCHIVE="$(mktemp -t "${APP_NAME}.XXXXXX.tar.gz")"
REMOTE_ARCHIVE="/tmp/${APP_NAME}.tar.gz"
REMOTE_SCRIPT="/tmp/${APP_NAME}-deploy.sh"
REMOTE_ENV="/tmp/${APP_NAME}.env"
REMOTE_GAR_TOKEN="/tmp/${APP_NAME}.gar-token"

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

# Scp the short-lived GAR OAuth token (1-hr validity) to the VM if the
# caller provided one. The token is later consumed by the remote
# deploy script to run `podman login -u oauth2accesstoken --password-stdin`.
# We never log the contents; only the existence.
if [ -n "$GAR_TOKEN_FILE" ] && [ -f "$GAR_TOKEN_FILE" ]; then
  echo "Uploading GAR auth token (1 h validity, $(wc -c < "$GAR_TOKEN_FILE") bytes)"
  gcloud compute scp "$GAR_TOKEN_FILE" "$NAME:$REMOTE_GAR_TOKEN" --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet
else
  REMOTE_GAR_TOKEN=""
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
REMOTE_GAR_TOKEN="__REMOTE_GAR_TOKEN__"
GAR_REGISTRY="__GAR_REGISTRY__"
GAR_REGISTRY_HOST="__GAR_REGISTRY_HOST__"

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

# Podman 5.x on Fedora 43 has `unqualified-search-registries` enforcement on
# by default: when a Compose service references a short-name image (e.g.
# `postgres:16-alpine` or `redis:7-alpine`), podman prompts the user to
# disambiguate the registry. In a non-TTY CI environment the prompt can't
# be shown, so the pull fails with:
#
#   Error: short-name resolution enforced but cannot prompt without a TTY
#
# which then cascades into:
#
#   Error: "<service>" is not a valid container, cannot be used as a
#   dependency: no container with name or ID "<service>" found
#
# for every depends_on. Fix: pre-register `docker.io` as the unqualified
# search list so any unprefixed short name resolves to
# `docker.io/library/<image>` automatically.
#
# Regression: lolian/superapp#28753529610
mkdir -p /etc/containers/registries.conf.d
cat > /etc/containers/registries.conf.d/zz-unqualified-search.conf <<'EOF'
unqualified-search-registries = ["docker.io"]
EOF

systemctl stop hermes-demo-health.service 2>/dev/null || true
systemctl kill --kill-who=all hermes-demo-health.service 2>/dev/null || true
systemctl disable hermes-demo-health.service 2>/dev/null || true
systemctl mask hermes-demo-health.service 2>/dev/null || true
pkill -f '/opt/hermes-demo/health_server.py' 2>/dev/null || true
for i in $(seq 1 20); do
  if ! ss -ltnp 2>/dev/null | awk -v port=":$APP_PORT" '$4 ~ port"$" {found=1} END {exit found ? 0 : 1}'; then
    break
  fi
  ss -ltnp 2>/dev/null | awk -v port=":$APP_PORT" '$4 ~ port"$" {print $0}'
  for pid in $(ss -ltnp 2>/dev/null | awk -v port=":$APP_PORT" '$4 ~ port"$" {print $0}' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u); do
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  done
  sleep 1
done
mkdir -p "$REMOTE_APP_DIR"
rm -rf "${REMOTE_APP_DIR:?}"/*
tar -xzf "$REMOTE_ARCHIVE" -C "$REMOTE_APP_DIR"
cd "$REMOTE_APP_DIR"

if [ -n "$REMOTE_ENV" ] && [ -f "$REMOTE_ENV" ]; then
  install -m 0600 "$REMOTE_ENV" .env
  echo "Mounted .env from $REMOTE_ENV (0600)"
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

# ── Authenticate podman against the private GAR ─────────────────────────────
# Compose services reference images like:
#   ${REGISTRY:-europe-west2-docker.pkg.dev/canaverse/canabis-superapp}/api:latest
# Those images are in a private Artifact Registry repository. The calling
# workflow has already minted a short-lived OAuth token and scp'd it to
# $REMOTE_GAR_TOKEN; we pipe it into `podman login` here, then delete
# the file.
#
# If $GAR_REGISTRY is empty (compose file uses only docker.io), the
# entire GAR auth block is skipped.
if [ -n "${GAR_REGISTRY:-}" ] && [ -n "${REMOTE_GAR_TOKEN:-}" ] && [ -f "$REMOTE_GAR_TOKEN" ]; then
  echo "Authenticating podman against private GAR $GAR_REGISTRY_HOST"
  # podman stores its auth in /run/containers/0/auth.json (rootful) or
  # $XDG_RUNTIME_DIR/containers/auth.json (rootless). Fedora VMs use
  # rootful podman by default here.
  if ! cat "$REMOTE_GAR_TOKEN" | podman login -u oauth2accesstoken --password-stdin "${GAR_REGISTRY_HOST}"; then
    echo "::error::podman login failed for ${GAR_REGISTRY_HOST}" >&2
    exit 1
  fi
  rm -f "$REMOTE_GAR_TOKEN"
  # Verify auth landed by listing the registry (no-op when used; just
  # surfaces auth errors early).
  podman pull --quiet "${GAR_REGISTRY_HOST}/__nonexistent-image-name" >/dev/null 2>&1 || true
elif [ -n "${GAR_REGISTRY:-}" ]; then
  # Caller passed app_gar_registry but no GAR_TOKEN_FILE → can't pull
  # private images. Fail loudly rather than let podman emit a
  # confusing auth error at first image pull.
  echo "::error::GAR_REGISTRY=${GAR_REGISTRY} but no GAR token file was scp'd; set app_gar_registry='' to skip GAR auth." >&2
  exit 1
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
# Compose is image-only. We explicitly do NOT pass --build: any
# `build:` directive in the compose file is treated as a misconfiguration
# and would cause a network + time hit we don't need. All images come
# from Artifact Registry (authenticated above) or docker.io (already
# public). Regression: lolian/superapp — image-only deploy refactor.
"${COMPOSE[@]}" up -d
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

python3 - "$DEPLOY_SCRIPT_LOCAL" \
  "$APP_NAME" \
  "$APP_PORT" \
  "$REMOTE_APP_DIR" \
  "$REMOTE_ARCHIVE" \
  "$REMOTE_ENV" \
  "$REMOTE_GAR_TOKEN" \
  "${GAR_REGISTRY:-europe-west2-docker.pkg.dev}" \
  "${GAR_REGISTRY_HOST:-https://europe-west2-docker.pkg.dev}" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
repls = {
    '__APP_NAME__': sys.argv[2],
    '__APP_PORT__': sys.argv[3],
    '__REMOTE_APP_DIR__': sys.argv[4],
    '__REMOTE_ARCHIVE__': sys.argv[5],
    '__REMOTE_ENV__': sys.argv[6],
    '__REMOTE_GAR_TOKEN__': sys.argv[7],
    '__GAR_REGISTRY__': sys.argv[8],
    '__GAR_REGISTRY_HOST__': sys.argv[9],
}
for k, v in repls.items():
    s = s.replace(k, v)
p.write_text(s)
PY
chmod +x "$DEPLOY_SCRIPT_LOCAL"

gcloud compute scp "$DEPLOY_SCRIPT_LOCAL" "$NAME:$REMOTE_SCRIPT" --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet
rm -f "$DEPLOY_SCRIPT_LOCAL"

echo "Running remote compose deployment"
gcloud compute ssh "$NAME" --zone "$ZONE_OUT" --project "$PROJECT_ID" --quiet --command "sudo bash '$REMOTE_SCRIPT'"
