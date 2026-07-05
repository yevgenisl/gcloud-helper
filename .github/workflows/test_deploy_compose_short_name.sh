#!/usr/bin/env bash
# Regression test for: scripts/deploy-compose-on-vm.sh
#
# Asserts that the script:
#   1. Configures podman's `unqualified-search-registries` to `docker.io`
#      before the first compose invocation. Podman 5.x on Fedora 43 has
#      short-name resolution TTY-prompting on by default; in CI there's
#      no TTY, so unprefixed image refs like `postgres:16-alpine` fail
#      to pull. The fix: pre-write /etc/containers/registries.conf.d/zz-
#      unqualified-search.conf registering docker.io.
#
#      Regression: lolian/superapp#28753529610

set -euo pipefail
SCRIPT=scripts/deploy-compose-on-vm.sh

echo "[1/3] $SCRIPT contains the unqualified-search-registries fix"
grep -nF 'unqualified-search-registries = ["docker.io"]' "$SCRIPT" \
  >/dev/null \
  || { echo "FAIL: missing unqualified-search-registries config"; exit 1; }

echo "[2/3] the fix is written BEFORE the first compose invocation"
# Podman's first appearance in the script must be after the heredoc that
# creates zz-unqualified-search.conf.
python3 - <<PY
import re
text = open("$SCRIPT").read()
conf_pos   = text.find('unqualified-search-registries = ["docker.io"]')
compose_pos = next(
    (m.start() for m in re.finditer(r'\\\$\\{COMPOSE\\[@\\]\\}', text)),
    text.find('"${COMPOSE[@]} config"'),
)
# The "${COMPOSE[@]}" reference is the first compose invocation. If
# unqualified-search-registries appears AFTER it, the fix is in the wrong
# place and pods will get short-name errors at pull time.
assert conf_pos < compose_pos, (
    "fix at offset %d must come before first compose use at offset %d" %
    (conf_pos, compose_pos)
)
PY

echo "[3/3] $SCRIPT syntax checks (bash -n)"
bash -n "$SCRIPT" \
  || { echo "FAIL: bash syntax error in $SCRIPT"; exit 1; }

echo "OK -- $SCRIPT disables podman short-name TTY-prompt before compose"
