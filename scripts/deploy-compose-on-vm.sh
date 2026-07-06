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
# Subdirectory inside REMOTE_APP_DIR that contains docker-compose.yml.
# Many repos (e.g. lolian/superapp) keep the compose file under
# deployment/ rather than at the repo root. Empty means compose lives at
# the tarball root (legacy single-purpose compose repos).
COMPOSE_SUBDIR="${COMPOSE_SUBDIR:-}"
# Image tag baked into .env as API_TAG/WEB_TAG/ASSISTANT_TAG. Defaults to
# `latest` because GAR images are tagged `:latest` for the demo. Override
# to pin a specific build (e.g. `sha-abc1234`).
APP_IMAGE_TAG="${APP_IMAGE_TAG:-latest}"
# Comma-separated list of (optional) container readiness probes beyond
# the nginx frontend check. The script will curl each `URL` and accept
# any HTTP response in the 2xx-4xx range as proof the upstream is up.
# 5xx and connection failures mean "not ready yet". Default probes cover
# the superapp nginx + assistant-api public path; override to fit other
# stacks. Format: "url1 url2 url3".
APP_HEALTH_PROBES="${APP_HEALTH_PROBES:-http://127.0.0.1:${APP_PORT}/ http://127.0.0.1:${APP_PORT}/api/categories}"

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
COMPOSE_SUBDIR="__COMPOSE_SUBDIR__"
APP_IMAGE_TAG="__APP_IMAGE_TAG__"
APP_HEALTH_PROBES="__APP_HEALTH_PROBES__"

if command -v dnf >/dev/null 2>&1; then
  # Avoid racing the GCE metadata startup script's own dnf transaction.
  for i in $(seq 1 60); do
    if [ -f /opt/hermes-demo/ready ]; then
      break
    fi
    echo "waiting for VM startup bootstrap to finish before package install ($i/60)"
    sleep 5
  done
  # openssl is needed by the safe-default .env heredoc below
  # (`openssl rand -hex 24` for DB passwords, `openssl rand -base64 48`
  # for JWT_SECRET). Without it the heredoc emits literal `<hash>` /
  # `latest` / `compose` tokens into the .env file and podman-compose
  # then errors with `SUPERAPP_DB_PASSWORD must be set` (the value is
  # the literal command name, not a hex string).
  # Regression: lolian/superapp run 28768411928.
  dnf -y install podman git curl jq python3 openssl
  dnf -y install podman-compose || true
elif command -v yum >/dev/null 2>&1; then
  yum -y install podman git curl jq python3 openssl
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
# Move into the compose subdir if requested. Many repos (e.g.
# lolian/superapp) keep the compose file under deployment/ rather than
# at the repo root, so the tarball we extracted above is the whole repo
# and we need to descend into the right subdir before invoking
# `podman compose`. Empty COMPOSE_SUBDIR means compose lives at the
# tarball root.
if [ -n "$COMPOSE_SUBDIR" ]; then
  COMPOSE_DIR="${REMOTE_APP_DIR}/${COMPOSE_SUBDIR}"
  if [ ! -d "$COMPOSE_DIR" ]; then
    echo "::error::COMPOSE_SUBDIR=$COMPOSE_SUBDIR does not exist under $REMOTE_APP_DIR" >&2
    exit 2
  fi
  cd "$COMPOSE_DIR"
else
  cd "$REMOTE_APP_DIR"
fi

# Always start with a safe-default .env so any compose-required vars
# not supplied by the caller's APP_ENV_FILE are filled in. The heredoc
# uses `>>` semantics (well, it writes a full file, then we re-source
# the caller's APP_ENV_FILE on top so caller's values win). We also
# auto-generate DB passwords and JWT_SECRET if they're missing.
#
# Auto-generated safe defaults satisfy the lolian/superapp compose
# file's `${VAR:?...}` mandatory substitutions so the stack comes up
# without an externally-rendered .env. The caller should always pass
# a real .env (via app_env_file / app_env_artifact_name / secrets.app_env
# / secrets.app_openrouter_api_key) for any non-demo deployment —
# the secrets below are ephemeral, demo-only, and printed into the
# VM's startup log so anyone who can read the log can read the secrets.
cat > .env <<ENV
# Auto-generated by deploy-compose-on-vm.sh. Caller values (from
# APP_ENV_FILE if any) are merged on top below.
SUPERAPP_DB_USER=cannabis
SUPERAPP_DB_NAME=cannabis
SUPERAPP_DB_PASSWORD=$(openssl rand -hex 24)
ASSISTANT_DB_USER=rag
ASSISTANT_DB_NAME=cannabis_rag
ASSISTANT_DB_PASSWORD=$(openssl rand -hex 24)
JWT_SECRET=$(openssl rand -base64 48)
JWT_EXPIRES_IN=7d
MIN_AGE=21
# Mock-LLM by default so the assistant works without an OpenRouter
# key. Pass a real OPENROUTER_API_KEY via APP_ENV_FILE or
# secrets.app_openrouter_api_key to enable live LLM calls.
MOCK_LLM=true
TOP_K=5
GOOGLE_PLACES_ENABLED=false
OPENROUTER_API_KEY=OPENROUTER_PLACEHOLDER_REPLACE_VIA_APP_ENV_FILE
OPENROUTER_CHAT_MODEL=mistralai/mistral-small-3.2-24b-instruct
OPENROUTER_FALLBACK_MODEL=mistralai/mistral-small-2603
OPENROUTER_INGEST_MODEL=mistralai/mistral-small-3.2-24b-instruct
# Image tags + registry. The compose file's
#   image: ${REGISTRY:-europe-west2-docker.pkg.dev/canaverse/canabis-superapp}/api:${API_TAG:-latest}
# already provides the GAR project path as its default. Setting
# REGISTRY= just the hostname would break the substitution and
# produce `europe-west2-docker.pkg.dev/api:latest` (no project) which
# GAR rejects with 400 Bad Request. We therefore leave REGISTRY
# UNSET in the default .env so compose's `:-` default kicks in.
# Override REGISTRY here only if you deploy to a different GAR
# project. (The podman login on the VM still uses the hostname
# GAR_REGISTRY_HOST regardless.)
API_TAG=${APP_IMAGE_TAG}
WEB_TAG=${APP_IMAGE_TAG}
ASSISTANT_TAG=${APP_IMAGE_TAG}
# Host port the nginx container publishes. We bind to all interfaces so
# the smoke check from outside the VM works.
NGINX_HOST_PORT=${APP_PORT}
BACKEND_HOST_PORT=4000
FRONTEND_HOST_PORT=3000
POSTGRES_HOST_PORT=5432
ASSISTANT_POSTGRES_HOST_PORT=5433
# Seed/migrate run as part of every `compose up`. Disable here if you
# want a fresh DB. (See deployment/docker-compose.yml for details.)

# Next.js /api/chat route handler calls process.env.CHAT_API_URL on every
# request. The compose default is "http://nginx/api/chat" — but nginx
# routes /api/chat back to the frontend itself, creating a self-loop
# that times out and surfaces as "Chat service is unavailable" (502).
# Point Next.js directly at the assistant-api service on the compose
# network. Override via APP_ENV_FILE if you front the assistant with a
# different hostname / port.
CHAT_API_URL=http://assistant-api:8080/chat
ENV
chmod 0600 .env
if [ -n "$REMOTE_ENV" ] && [ -f "$REMOTE_ENV" ]; then
  # Caller-provided partial .env. Merge on top of the safe defaults so
  # the caller's values win for any key they specified, while missing
  # compose-required vars (DB passwords, JWT_SECRET, ...) still get
  # auto-generated defaults. We use `env -S` to parse the caller's
  # KEY=VALUE lines then re-emit, skipping comments and blank lines.
  echo "Merging caller's APP_ENV_FILE on top of safe defaults (caller values win)"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;            # skip blanks + comments
      *=*)
        key="${line%%=*}"
        val="${line#*=}"
        # Strip surrounding quotes if any
        case "$val" in
          \"*\") val="${val#\"}"; val="${val%\"}" ;;
          \'*\") val="${val#\'}"; val="${val%\'}" ;;
        esac
        # Replace existing key (last occurrence wins, matching compose
        # semantics where later assignments override earlier ones)
        if grep -q -E "^${key}=" .env; then
          sed -i "s|^${key}=.*$|${key}=${val}|" .env
        else
          printf '%s=%s\n' "$key" "$val" >> .env
        fi
        ;;
      *)
        echo "::warning::APP_ENV_FILE line ignored (not KEY=VALUE): $line" >&2
        ;;
    esac
  done < "$REMOTE_ENV"
  echo "Merged .env written (0600)"
else
  echo "Auto-generated demo .env (rotate before non-demo use)"
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

# Ensure any host-side volume mount paths referenced by the compose file
# exist on disk before `compose up`. Podman refuses to start a service
# whose bind-mount source is missing, and the lolian/superapp compose
# file mounts `${ASSISTANT_SQL_DIR:-./sql}` for the assistant-db init
# SQL. Without ASSISTANT_SQL_DIR set in .env, podman would try to mount
# a non-existent `./sql` and fail with "stat: no such file or directory".
# Pre-creating an empty dir satisfies the bind without seeding data —
# the seed SQL is optional per the compose file's own comment.
ASSISTANT_SQL_DIR_VALUE="$(grep -E '^ASSISTANT_SQL_DIR=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
ASSISTANT_SQL_DIR_VALUE="${ASSISTANT_SQL_DIR_VALUE:-./sql}"
case "$ASSISTANT_SQL_DIR_VALUE" in
  /*) ;;
  *)  ASSISTANT_SQL_DIR_VALUE="$(pwd)/$ASSISTANT_SQL_DIR_VALUE" ;;
esac
mkdir -p "$ASSISTANT_SQL_DIR_VALUE"
echo "Ensured assistant-db init SQL dir exists: $ASSISTANT_SQL_DIR_VALUE"

"${COMPOSE[@]}" up -d
"${COMPOSE[@]}" ps

# Initialize the assistant-db schema. The compose file's
# assistant-db mounts ${ASSISTANT_SQL_DIR:-./sql} into
# /docker-entrypoint-initdb.d but doesn't ship the SQL itself — the
# schema lives in the canabis-assistant-api repo (a separate
# multi-repo dependency, see compose file comment). When the bind-
# mount is empty (our default), postgres sees an empty init dir, runs
# no DDL, and the assistant-api's `retrieve()` query later fails with
# `psycopg.errors.UndefinedTable: relation "cannabis_chunks" does
# not exist`.
#
# Fix: fetch the schema from the canabis-assistant-api repo on the
# public GitHub mirror and pipe it into the running assistant-db via
# `podman exec psql`. The DDL is `CREATE TABLE IF NOT EXISTS`, so
# this is idempotent and safe to re-run on subsequent deploys.
ASSISTANT_SCHEMA_URL="${ASSISTANT_SCHEMA_URL:-https://raw.githubusercontent.com/yevgenisl/canabis-assistant-api/main/sql/init.sql}"
if [ "${SKIP_ASSISTANT_SCHEMA:-0}" != "1" ]; then
  echo "Bootstrapping assistant-db schema from $ASSISTANT_SCHEMA_URL"
  if command -v curl >/dev/null 2>&1; then
    ASSISTANT_SCHEMA_SQL="$(curl -fsSL --max-time 30 "$ASSISTANT_SCHEMA_URL" || true)"
  elif command -v wget >/dev/null 2>&1; then
    ASSISTANT_SCHEMA_SQL="$(wget -qO- --timeout=30 "$ASSISTANT_SCHEMA_URL" || true)"
  else
    echo "::warning::curl/wget not found; skipping assistant-db schema bootstrap"
    ASSISTANT_SCHEMA_SQL=""
  fi
  if [ -n "${ASSISTANT_SCHEMA_SQL:-}" ]; then
    # Apply schema. Retry briefly: assistant-db may still be healthy-
    # checking on the first poll cycle after compose up.
    applied=0
    for attempt in $(seq 1 30); do
      if printf '%s\n' "$ASSISTANT_SCHEMA_SQL" | podman exec -i cannabis_assistant_db psql -U rag -d cannabis_rag -v ON_ERROR_STOP=1 >/dev/null 2>&1; then
        echo "assistant-db schema applied (attempt $attempt)"
        applied=1
        break
      fi
      sleep 2
    done
    if [ "$applied" != "1" ]; then
      echo "::warning::assistant-db schema bootstrap failed after 60s; chat will return 500 until schema is applied manually" >&2
    fi
  else
    echo "::warning::could not fetch assistant-db schema from $ASSISTANT_SCHEMA_URL; chat may return 500" >&2
  fi
else
  echo "Skipping assistant-db schema bootstrap (SKIP_ASSISTANT_SCHEMA=1)"
fi

# Multi-target readiness probe. A real-world compose stack (e.g.
# lolian/superapp) has many internal services; nginx serving the
# frontend at / is the user-facing entrypoint, but we also want
# proof the backend API is alive so a half-up stack (frontend up,
# backend crashing) is caught before the smoke check runs.
#
# For each URL in $APP_HEALTH_PROBES we curl with a short timeout.
# Any HTTP response in the 2xx-4xx range means the upstream is
# listening and responding. 5xx, connection refused, and DNS
# failures mean "not ready yet" — we keep retrying until either
# everything passes or the timeout expires.
probe_ready() {
  local url="$1"
  local code
  # curl writes the HTTP code on stdout, body to /dev/null. -k is not
  # needed (we hit 127.0.0.1). --max-time 5 caps each attempt.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || echo 000)"
  case "$code" in
    2*|3*|4*) return 0 ;;
    *) return 1 ;;
  esac
}

PROBE_TIMEOUT=300  # 5 minutes at 5s sleep = 60 attempts
for i in $(seq 1 $PROBE_TIMEOUT); do
  all_ok=1
  for url in $APP_HEALTH_PROBES; do
    if probe_ready "$url"; then
      :
    else
      all_ok=0
      echo "[$i/$PROBE_TIMEOUT] $url not ready"
      break
    fi
  done
  if [ "$all_ok" = "1" ]; then
    echo
    echo "${APP_NAME} compose deployment OK on port ${APP_PORT}"
    for url in $APP_HEALTH_PROBES; do
      printf '  %s -> HTTP %s\n' "$url" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url")"
    done
    exit 0
  fi
  sleep 1
done

echo "${APP_NAME} compose deployment failed health check after ${PROBE_TIMEOUT}s" >&2
"${COMPOSE[@]}" logs --tail=200 || true
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
  "${GAR_REGISTRY_HOST:-https://europe-west2-docker.pkg.dev}" \
  "$COMPOSE_SUBDIR" \
  "$APP_IMAGE_TAG" \
  "$APP_HEALTH_PROBES" <<'PY'
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
    '__COMPOSE_SUBDIR__': sys.argv[10],
    '__APP_IMAGE_TAG__': sys.argv[11],
    '__APP_HEALTH_PROBES__': sys.argv[12],
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
