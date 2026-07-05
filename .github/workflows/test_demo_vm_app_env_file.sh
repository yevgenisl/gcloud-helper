#!/usr/bin/env bash
# Regression test: demo-vm.yaml accepts app_env_file input and the prepare
# step honours it (with secrets.app_env fallback). Tests are static-only —
# they don't make API calls.
set -euo pipefail

WF=.github/workflows/demo-vm.yaml
PYTHON=${PYTHON:-python3}

echo "[1/5] $WF exists and parses"
$PYTHON - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d[True]['workflow_call']
assert 'inputs' in on, "workflow_call.inputs missing"
assert 'secrets' in on, "workflow_call.secrets missing"
assert 'app_env_file' in on['inputs'], "input app_env_file missing"
assert 'app_env' in on['secrets'], "secret app_env missing (backward-compat)"
print("  inputs:", sorted(on['inputs'].keys())[-1])
print("  secrets:", sorted(on['secrets'].keys()))
PY

echo "[2/5] app_env_file declared with correct type and required:false"
$PYTHON - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
inp = d[True]['workflow_call']['inputs']['app_env_file']
assert inp['type'] == 'string', f"expected string, got {inp.get('type')}"
assert inp['required'] is False, "must default to optional"
assert inp['default'] == '', "must default to empty string"
PY

echo "[3/5] secrets.app_env still declared (backward compat)"
$PYTHON - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sec = d[True]['workflow_call']['secrets']['app_env']
assert sec['required'] is False
PY

echo "[4/5] prepare step references APP_ENV_INPUT_FILE"
grep -nF 'APP_ENV_INPUT_FILE' "$WF" >/dev/null \
  || { echo "APP_ENV_INPUT_FILE not referenced in workflow"; exit 1; }
grep -nF 'inputs.app_env_file' "$WF" >/dev/null \
  || { echo "inputs.app_env_file not bound to env"; exit 1; }

echo "[5/5] prepare step still references APP_ENV_CONTENT (fallback path)"
grep -nF 'APP_ENV_CONTENT' "$WF" >/dev/null \
  || { echo "APP_ENV_CONTENT not referenced in workflow"; exit 1; }

echo "OK — demo-vm.yaml app_env_file contract intact"
