#!/usr/bin/env bash
# Ensure standalone compose deployment reinitializes OpenTofu before reading
# outputs. This prevents a pruned CI provider cache from failing at `tofu output`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
BACKEND="$ROOT/infra/gcp-demo-vm/backend.hcl"
BACKUP="$TMP/backend.hcl"
HAD_BACKEND=false

cleanup() {
  if "$HAD_BACKEND"; then
    cp "$BACKUP" "$BACKEND"
  else
    rm -f "$BACKEND"
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

if [[ -e "$BACKEND" ]]; then
  HAD_BACKEND=true
  cp "$BACKEND" "$BACKUP"
fi

mkdir -p "$TMP/bin" "$TMP/app/deployment"
printf 'services: {}\n' >"$TMP/app/deployment/docker-compose.yml"
printf 'KEY=value\n' >"$TMP/app/deployment/rendered.env"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/post-deploy.sh"
chmod +x "$TMP/post-deploy.sh"

cat >"$TMP/bin/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TOFU_CALL_LOG"
case "$1 ${2:-} ${3:-}" in
  'output -raw instance_name') printf '%s\n' hermes-demo-compose-init-test ;;
  'output -raw zone') printf '%s\n' https://www.googleapis.com/compute/v1/projects/canaverse/zones/europe-west1-b ;;
esac
EOF
cat >"$TMP/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GCLOUD_CALL_LOG"
exit 0
EOF
chmod +x "$TMP/bin/tofu" "$TMP/bin/gcloud"

TOFU_CALL_LOG="$TMP/tofu.calls" \
GCLOUD_CALL_LOG="$TMP/gcloud.calls" \
PATH="$TMP/bin:$PATH" \
PROJECT_ID=canaverse ENVIRONMENT=ci RUN_ID=compose-init-test \
TF_STATE_BUCKET=canaverse-tofu-state \
APP_SOURCE_DIR="$TMP/app" APP_COMPOSE_SUBDIR=deployment \
APP_ENV_FILE="$TMP/app/deployment/rendered.env" \
APP_POST_DEPLOY_SCRIPT="$TMP/post-deploy.sh" \
"$ROOT/scripts/deploy-compose-on-vm.sh" >/dev/null

mapfile -t calls <"$TMP/tofu.calls"
[[ "${calls[0]}" == 'init -input=false -reconfigure -backend-config=backend.hcl -no-color' ]] || {
  printf 'expected initial provider/backend init, got: %s\n' "${calls[0]:-<none>}" >&2
  exit 1
}
[[ "${calls[1]}" == 'output -raw instance_name' ]] || {
  printf 'instance output must follow init, got: %s\n' "${calls[1]:-<none>}" >&2
  exit 1
}
[[ "${calls[2]}" == 'output -raw zone' ]] || {
  printf 'zone output must follow init, got: %s\n' "${calls[2]:-<none>}" >&2
  exit 1
}
grep -qx 'prefix = "superapp-demo/ci/compose-init-test"' "$BACKEND"
[[ "$(grep -c '^compute scp ' "$TMP/gcloud.calls")" -ge 4 ]] || {
  cat "$TMP/gcloud.calls" >&2
  echo 'expected source/artifact/remote-script uploads' >&2
  exit 1
}
grep -q '^compute ssh ' "$TMP/gcloud.calls" || {
  cat "$TMP/gcloud.calls" >&2
  echo 'expected remote deploy SSH' >&2
  exit 1
}

printf 'PASS: compose deploy initializes providers before tofu output.\n'
