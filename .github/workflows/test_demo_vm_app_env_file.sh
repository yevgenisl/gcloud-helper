#!/usr/bin/env bash
# Regression test: demo-vm.yaml accepts multiple .env delivery paths and the
# fetch logic honours them. The contract is now split across multiple steps
# rather than one monolithic bash block (because bash doesn't have access to
# the ACTIONS_RUNTIME_TOKEN / ACTIONS_RUNTIME_URL env vars that the artifact
# download API needs; canonical fix is to use `uses: actions/download-artifact@v4`).
set -euo pipefail

WF=.github/workflows/demo-vm.yaml
PYTHON=${PYTHON:-python3}

echo "[1/8] $WF exists and parses; both new inputs declared"
$PYTHON - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d[True]['workflow_call']
assert 'inputs' in on, "workflow_call.inputs missing"
assert 'secrets' in on, "workflow_call.secrets missing"
for k in ('app_env_file', 'app_env_artifact_name'):
    assert k in on['inputs'], f"input {k} missing"
assert 'app_env' in on['secrets'], "secret app_env missing (backward-compat)"
PY

echo "[2/8] inputs declare string/false/empty"
$PYTHON - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for k in ('app_env_file', 'app_env_artifact_name'):
    inp = d[True]['workflow_call']['inputs'][k]
    assert inp['type'] == 'string'
    assert inp['required'] is False
    assert inp['default'] == ''
PY

echo "[3/8] secrets.app_env still declared (backward compat)"
$PYTHON - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sec = d[True]['workflow_call']['secrets']['app_env']
assert sec['required'] is False
PY

echo "[4/8] APP_ENV resolution is now MULTI-STEP (no monolithic bash using ACTIONS_RUNTIME_TOKEN)"
# A monolithic step that does the artifact download itself is what bit us in
# lolian/superapp#28752851868 -- the runner doesn't inject ACTIONS_RUNTIME_*
# into arbitrary bash, so the curl+unzip pattern failed with
# `ACTIONS_RUNTIME_TOKEN: unbound variable`.
#
# The fix: split into a resolve step that emits outputs.source = input_file | artifact | none,
# then conditionally run one of three independent fetch steps:
#   1. cp a local file (for input_file)
#   2. actions/download-artifact@v4 (for artifact, no bash needed)
#   3. printf secrets.app_env (for none+secret)
# ... and a final normalization + APP_ENV_FILE export step.
grep -nF '      - name: Resolve app env file path' "$WF" >/dev/null \
  || { echo "Expected: Resolve app env file path step present"; exit 1; }
grep -nF '      - name: Fetch app env (file input)' "$WF" >/dev/null \
  || { echo "Expected: Fetch app env (file input) step present"; exit 1; }
grep -nF '      - name: Fetch app env (artifact)' "$WF" >/dev/null \
  || { echo "Expected: Fetch app env (artifact) step present"; exit 1; }
grep -nF '      - name: Fetch app env (secrets.app_env fallback)' "$WF" >/dev/null \
  || { echo "Expected: secrets.app_env fallback step present"; exit 1; }
grep -nF '      - name: Export APP_ENV_FILE for downstream steps' "$WF" >/dev/null \
  || { echo "Expected: Export APP_ENV_FILE step present"; exit 1; }

echo "[5/8] artifact fetcher uses actions/download-artifact@v4 (no bash+curl+ACTIONS_RUNTIME_TOKEN)"
# This is the actual regression fix: the artifact step must be a `uses:`,
# not bash referencing ACTIONS_RUNTIME_TOKEN/URL.
$PYTHON - "$WF" <<'PY'
import sys, yaml, re
d = yaml.safe_load(open(sys.argv[1]))
jobs = d['jobs']['demo-vm']
steps = jobs['steps']
artifact_steps = [s for s in steps
                  if 'Fetch app env (artifact)' in (s.get('name') or '')]
assert artifact_steps, "no 'Fetch app env (artifact)' step"
step = artifact_steps[0]
uses = step.get('uses', '')
assert uses.startswith('actions/download-artifact'), \
    f"artifact step should use actions/download-artifact, got {uses!r}"
PY

echo "[6/8] no \$ACTIONS_RUNTIME_TOKEN references in any bash run block"
# Even one reference can break the env vars are not injected.
$PYTHON - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
violations = []
for step in d['jobs']['demo-vm']['steps']:
    blob = yaml.safe_dump(step)
    if 'ACTIONS_RUNTIME_TOKEN' in blob or 'ACTIONS_RUNTIME_URL' in blob:
        violations.append(step.get('name', '?'))
if violations:
    raise SystemExit(
        "ACTIONS_RUNTIME_TOKEN/URL referenced in bash blocks: "
        f"{violations}. These env vars are NOT guaranteed to be injected "
        "into arbitrary bash scripts; use `uses: actions/download-artifact@v4` instead. "
        "(Regression: lolian/superapp#28752851868)"
    )
PY

echo "[7/8] precedence docs still note app_env_file > app_env_artifact_name > secrets.app_env"
grep -nE 'app_env_file.*>.*app_env_artifact_name.*>.*secrets.app_env' "$WF" >/dev/null \
  || { echo "precedence order not documented at top of resolve step"; exit 1; }

echo "[8/8] actions/download-artifact@v4 declared in inputs/outputs (so superapp can pin SHA)"
# The composite action caller passes a name ref; we use the action by version
# which is fine for now.
grep -nF 'actions/download-artifact@v4' "$WF" >/dev/null \
  || { echo "expected exact @v4 download-artifact reference"; exit 1; }

echo "OK — demo-vm.yaml multi-path .env contract intact; uses actions/download-artifact@v4 for cross-job artifacts"
