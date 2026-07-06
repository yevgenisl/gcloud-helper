#!/usr/bin/env bash
# Runs on the demo VM after `podman compose up -d`.
# Reaches the same state regardless of the deployed application — package
# install, registries.conf, port cleanup, compose up/down, post-deploy
# hook, multi-target readiness probe.
#
# Caller-supplied values are passed as env vars:
#   APP_NAME, APP_PORT, REMOTE_APP_DIR, REMOTE_ARCHIVE, REMOTE_ENV,
#   REMOTE_GAR_TOKEN, REMOTE_POST_DEPLOY, APP_COMPOSE_SUBDIR,
#   APP_HEALTH_PROBES, APP_GAR_REGISTRY_HOST

set -euo pipefail

if command -v dnf >/dev/null 2>&1; then
  dnf -y install podman git curl jq python3 openssl || true
  dnf -y install podman-compose || true
elif command -v yum >/dev/null 2>&1; then
  yum -y install podman git curl jq python3 openssl || true
  yum -y install podman-compose || true
fi
systemctl enable --now podman.socket || true

# Podman 5.x needs docker.io in unqualified-search-registries so short
# names (postgres:16, redis:7) resolve in non-TTY CI environments.
mkdir -p /etc/containers/registries.conf.d
cat > /etc/containers/registries.conf.d/zz-unqualified-search.conf <<'EOF'
unqualified-search-registries = ["docker.io"]
EOF

# Free APP_PORT if anything is bound (e.g. leftover health service)
for i in $(seq 1 20); do
  if ! ss -ltnp 2>/dev/null | awk -v port=":$APP_PORT" '$4 ~ port"$" {found=1} END {exit found ? 0 : 1}'; then
    break
  fi
  for pid in $(ss -ltnp 2>/dev/null | awk -v port=":$APP_PORT" '$4 ~ port"$" {print $0}' \
              | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u); do
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  done
  sleep 1
done

# Extract source, descend into compose subdir if requested
mkdir -p "$REMOTE_APP_DIR"
rm -rf "${REMOTE_APP_DIR:?}"/*
tar -xzf "$REMOTE_ARCHIVE" -C "$REMOTE_APP_DIR"
if [ -n "${APP_COMPOSE_SUBDIR:-}" ]; then
  cd "$REMOTE_APP_DIR/$APP_COMPOSE_SUBDIR"
else
  cd "$REMOTE_APP_DIR"
fi

# Caller-prepared .env goes alongside compose (no merging, no generation)
if [ -n "${REMOTE_ENV:-}" ] && [ -f "$REMOTE_ENV" ]; then
  install -m 0600 "$REMOTE_ENV" .env
fi

# Private GAR auth (if token was scp'd)
if [ -n "${APP_GAR_REGISTRY_HOST:-}" ] && [ -n "${REMOTE_GAR_TOKEN:-}" ] && [ -f "$REMOTE_GAR_TOKEN" ]; then
  cat "$REMOTE_GAR_TOKEN" | podman login -u oauth2accesstoken --password-stdin "$APP_GAR_REGISTRY_HOST"
  rm -f "$REMOTE_GAR_TOKEN"
fi

# Pick the first available compose implementation
if podman compose version >/dev/null 2>&1; then
  COMPOSE=(podman compose)
elif command -v podman-compose >/dev/null 2>&1; then
  COMPOSE=(podman-compose)
elif docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
else
  echo "No compose implementation available" >&2
  exit 127
fi

# Refresh remote images before recreating containers. This is especially
# important for `:latest` demo deploys on a reused deterministic VM.
"${COMPOSE[@]}" pull || true
"${COMPOSE[@]}" up -d
"${COMPOSE[@]}" ps

# Caller-supplied post-deploy hook (e.g. apply DB schema, warm caches)
if [ -n "${REMOTE_POST_DEPLOY:-}" ] && [ -f "$REMOTE_POST_DEPLOY" ]; then
  echo "Running post-deploy script: $REMOTE_POST_DEPLOY"
  bash "$REMOTE_POST_DEPLOY"
fi

# Multi-target readiness probe: any 2xx-4xx response = ready
probe_ready() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null | grep -qE '^[234][0-9][0-9]$'
}
for i in $(seq 1 300); do
  all_ok=1
  for url in $APP_HEALTH_PROBES; do
    probe_ready "$url" || { all_ok=0; echo "[$i/300] $url not ready"; break; }
  done
  if [ "$all_ok" = "1" ]; then
    echo "${APP_NAME} compose deployment OK on port ${APP_PORT}"
    for url in $APP_HEALTH_PROBES; do
      printf '  %s -> HTTP %s\n' "$url" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url")"
    done
    exit 0
  fi
  sleep 1
done

echo "${APP_NAME} compose deployment failed health check after 300s" >&2
"${COMPOSE[@]}" logs --tail=200 || true
exit 1
