#!/usr/bin/env bash
# Regression test: demo-vm.yaml accepts multiple .env delivery paths and the
# fetch step honours all three (in precedence order). Tests are static-only —
# they don't make API calls or trigger runs.
set -euo pipefail

WF=.github/workflows/demo-vm.yaml
PYTHON=${PYTHON:-python3}

echo "[1/6] $WF exists and parses"
$PYTHON - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d[True]['workflow_call']
assert 'inputs' in on, "workflow_call.inputs missing"
assert 'secrets' in on, "workflow_call.secrets missing"
for k in ('app_env_file', 'app_env_artifact_name'):
    assert k in on['inputs'], f"input {k} missing"
assert 'app_env' in on['secrets'], "secret app_env missing (backward-compat)"
print("  inputs(.env paths):", sorted(k for k in on['inputs'] if 'env' in k))
print("  secrets(.env paths):", sorted(on['secrets'].keys()))
PY

echo "[2/6] both new inputs declare string/false/empty"
$PYTHON - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for k in ('app_env_file', 'app_env_artifact_name'):
    inp = d[True]['workflow_call']['inputs'][k]
    assert inp['type'] == 'string', f"{k}: expected string, got {inp.get('type')}"
    assert inp['required'] is False, f"{k}: must be optional"
    assert inp['default'] == '', f"{k}: must default to empty string"
PY

echo "[3/6] secrets.app_env still declared (backward compat)"
$PYTHON - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sec = d[True]['workflow_call']['secrets']['app_env']
assert sec['required'] is False
PY

echo "[4/6] fetch step has id (so consumers can read source)"
grep -nF "      - name: Download or read optional app env file" "$WF" >/dev/null \
  || { echo "fetch step label changed"; exit 1; }
grep -nF "        id: fetch_env" "$WF" >/dev/null \
  || { echo "fetch step missing id"; exit 1; }

echo "[5/6] fetch step references all three precedence paths"
grep -nF 'APP_ENV_INPUT_FILE' "$WF" >/dev/null \
  || { echo "APP_ENV_INPUT_FILE not referenced"; exit 1; }
grep -nF 'APP_ENV_ARTIFACT_NAME' "$WF" >/dev/null \
  || { echo "APP_ENV_ARTIFACT_NAME not referenced"; exit 1; }
grep -nF 'APP_ENV_CONTENT' "$WF" >/dev/null \
  || { echo "APP_ENV_CONTENT not referenced (fallback gone)"; exit 1; }

echo "[6/6] precedence comments read app_env_file > app_env_artifact_name > secrets.app_env"
grep -nE 'app_env_file > app_env_artifact_name > secrets.app_env' "$WF" >/dev/null \
  || { echo "precedence order not documented"; exit 1; }

echo "OK — demo-vm.yaml multi-path .env contract intact"
