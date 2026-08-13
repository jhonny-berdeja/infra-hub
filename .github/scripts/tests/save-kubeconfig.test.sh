#!/usr/bin/env bash
# Test harness for save-kubeconfig.sh. Runs with a fake $HOME so it
# never touches the real ~/.kube/config.
#
# Run: bash scripts/tests/save-kubeconfig.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../save-kubeconfig.sh"

pass=0
fail=0

if [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET does not exist yet (expected in RED phase)"
  exit 1
fi

FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT

# --- Writes the content with 0600 permissions ---
if HOME="$FAKE_HOME" KUBECONFIG_CONTENT="fake-kubeconfig-yaml" "$TARGET"; then
  CONTENT="$(cat "$FAKE_HOME/.kube/config")"
  PERMS="$(stat -c '%a' "$FAKE_HOME/.kube/config" 2>/dev/null || stat -f '%Lp' "$FAKE_HOME/.kube/config")"
  if [ "$CONTENT" = "fake-kubeconfig-yaml" ] && [ "$PERMS" = "600" ]; then
    echo "PASS: writes the kubeconfig content with 0600 permissions"
    pass=$((pass + 1))
  else
    echo "FAIL: content or permissions mismatch (content='$CONTENT', perms='$PERMS')"
    fail=$((fail + 1))
  fi
else
  echo "FAIL: expected success, script exited non-zero"
  fail=$((fail + 1))
fi

# --- Missing KUBECONFIG_CONTENT is rejected ---
if HOME="$FAKE_HOME" "$TARGET" >/dev/null 2>&1; then
  echo "FAIL (expected reject): missing KUBECONFIG_CONTENT was accepted"
  fail=$((fail + 1))
else
  echo "PASS (rejected): missing KUBECONFIG_CONTENT"
  pass=$((pass + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
