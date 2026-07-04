#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT_DIR/infra/gcp-demo-vm"
PROJECT_ID="${PROJECT_ID:-canaverse}"
REGION="${REGION:-europe-west1}"
ZONE="${ZONE:-europe-west1-b}"
ENVIRONMENT="${ENVIRONMENT:-local}"
RUN_ID="${RUN_ID:-local}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-${PROJECT_ID}-tofu-state}"
TF_STATE_PREFIX="${TF_STATE_PREFIX:-superapp-demo/${ENVIRONMENT}/${RUN_ID}}"
DEMO_PORT="${DEMO_PORT:-8080}"
CREATE_FIREWALL_RULES="${CREATE_FIREWALL_RULES:-false}"
GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/service-accounts/hermess-sa.json}"
export GOOGLE_APPLICATION_CREDENTIALS

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 127; }
}

ensure_prereqs() {
  require_cmd gcloud
  require_cmd tofu
  require_cmd curl
  # Do not run `gcloud config set project` here: when Cloud Resource Manager is
  # disabled for the project, that command emits noisy warnings even though the
  # explicit `--project` flags used by these scripts work correctly.
}

write_backend_config() {
  cat > "$TF_DIR/backend.hcl" <<EOF
bucket = "$TF_STATE_BUCKET"
prefix = "$TF_STATE_PREFIX"
EOF
}

tofu_vars() {
  printf -- '-var=project_id=%q ' "$PROJECT_ID"
  printf -- '-var=region=%q ' "$REGION"
  printf -- '-var=zone=%q ' "$ZONE"
  printf -- '-var=environment=%q ' "$ENVIRONMENT"
  printf -- '-var=run_id=%q ' "$RUN_ID"
  printf -- '-var=demo_port=%q ' "$DEMO_PORT"
  printf -- '-var=create_firewall_rules=%q ' "$CREATE_FIREWALL_RULES"
}
