#!/usr/bin/env bash
# Regression test: remote Compose deployments must tear down the existing
# project before force-recreating services. This prevents Podman from trying to
# replace a container while its dependent containers still exist.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/app"
SCRIPT_UNDER_TEST="$TMP/deploy-compose-remote.sh"
# The production script writes the host registry config as root. Run the same
# script body in an unprivileged fixture with only that machine-wide path
# redirected; all deployment behavior is still exercised through mocks.
python3 - "$ROOT/scripts/deploy-compose-remote.sh" "$SCRIPT_UNDER_TEST" "$TMP/registries.conf.d" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
source = source.replace('/etc/containers/registries.conf.d', sys.argv[3])
Path(sys.argv[2]).write_text(source)
PY

mkdir -p "$TMP/bin" "$TMP/app" "$TMP/registries.conf.d"

cat >"$TMP/bin/dnf" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$TMP/bin/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$TMP/bin/tar" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '200'
EOF
cat >"$TMP/bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$PODMAN_CALL_LOG"
if [[ "$*" == 'compose version' ]]; then
  printf 'podman-compose mock\n'
fi
EOF
chmod +x "$TMP/bin/dnf" "$TMP/bin/systemctl" "$TMP/bin/ss" "$TMP/bin/tar" "$TMP/bin/curl" "$TMP/bin/podman"

PODMAN_CALL_LOG="$TMP/podman.calls" \
PATH="$TMP/bin:$PATH" \
APP_NAME=superapp \
APP_PORT=8080 \
REMOTE_APP_DIR="$TMP/app" \
REMOTE_ARCHIVE="$TMP/app.tar.gz" \
REMOTE_ENV='' \
REMOTE_GAR_TOKEN='' \
REMOTE_POST_DEPLOY='' \
APP_COMPOSE_SUBDIR='' \
APP_HEALTH_PROBES='http://127.0.0.1:8080/' \
APP_GAR_REGISTRY_HOST='' \
bash "$SCRIPT_UNDER_TEST"

mapfile -t calls <"$TMP/podman.calls"
expected=(
  'compose version'
  'compose pull'
  'compose down --remove-orphans'
  'compose up -d --force-recreate --remove-orphans'
  'compose ps'
)

[[ "${#calls[@]}" -eq "${#expected[@]}" ]] || {
  printf 'expected %s podman calls, got %s:\n%s\n' "${#expected[@]}" "${#calls[@]}" "$(printf '  %s\n' "${calls[@]}")" >&2
  exit 1
}

for i in "${!expected[@]}"; do
  [[ "${calls[$i]}" == "${expected[$i]}" ]] || {
    printf 'call %s: expected %q, got %q\n' "$i" "${expected[$i]}" "${calls[$i]}" >&2
    exit 1
  }
done

printf 'PASS: remote deploy tears down Compose dependents before force-recreate.\n'
