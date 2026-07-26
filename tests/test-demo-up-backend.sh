#!/usr/bin/env bash
# Regression test for scripts/demo-up.sh backend initialization order.
# It replaces OpenTofu with a recording stub: no cloud API or state operation
# is performed.
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

mkdir -p "$TMP/bin"
cat >"$TMP/bin/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TOFU_CALL_LOG"
EOF
cat >"$TMP/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/tofu" "$TMP/bin/gcloud"

TOFU_CALL_LOG="$TMP/tofu.calls" \
PATH="$TMP/bin:$PATH" \
ENVIRONMENT=ci \
RUN_ID=backend-order-test \
PROJECT_ID=canaverse \
"$ROOT/scripts/demo-up.sh"

mapfile -t calls <"$TMP/tofu.calls"
[[ "${#calls[@]}" -eq 3 ]] || { printf 'expected 3 tofu calls, got %s\n' "${#calls[@]}" >&2; exit 1; }
[[ "${calls[0]}" == "init -input=false -reconfigure -backend-config=backend.hcl -no-color" ]] || { printf 'unexpected init: %s\n' "${calls[0]}" >&2; exit 1; }
[[ "${calls[1]}" == *"apply -auto-approve -lock-timeout=5m -no-color"* ]] || { printf 'unexpected apply: %s\n' "${calls[1]}" >&2; exit 1; }
[[ "${calls[1]}" == *"-var=environment=ci"* && "${calls[1]}" == *"-var=run_id=backend-order-test"* ]] || { printf 'apply lacks requested environment/run id: %s\n' "${calls[1]}" >&2; exit 1; }
[[ "${calls[2]}" == "output -no-color" ]] || { printf 'unexpected output: %s\n' "${calls[2]}" >&2; exit 1; }
grep -qx 'prefix = "superapp-demo/ci/backend-order-test"' "$BACKEND"
printf 'PASS: demo-up reconfigures the requested backend before apply.\n'
