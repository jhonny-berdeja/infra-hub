#!/usr/bin/env bash
# Test harness for assert-secret-is-set.sh. Table-driven: each case invokes
# the script with a name/value pair and asserts the expected exit code.
# Mirrors the style of validate-image-tag.test.sh.
#
# Run: bash scripts/tests/assert-secret-is-set.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../assert-secret-is-set.sh"

pass=0
fail=0

# assert_reject <name> <value> <label>
assert_reject() {
  local name="$1" value="$2" label="$3"
  if "$TARGET" "$name" "$value" >/dev/null 2>&1; then
    echo "FAIL (expected reject): $label -> accepted"
    fail=$((fail + 1))
  else
    echo "PASS (rejected): $label"
    pass=$((pass + 1))
  fi
}

# assert_accept <name> <value> <label>
assert_accept() {
  local name="$1" value="$2" label="$3"
  if "$TARGET" "$name" "$value" >/dev/null 2>&1; then
    echo "PASS (accepted): $label"
    pass=$((pass + 1))
  else
    echo "FAIL (expected accept): $label -> rejected"
    fail=$((fail + 1))
  fi
}

if [ ! -x "$TARGET" ] && [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET does not exist yet (expected in RED phase)"
  exit 1
fi

# --- Rejections ---
assert_reject 'DOCKERHUB_TOKEN' '' "empty value"

# --- Missing-argument rejections ---
if "$TARGET" 'ONLY_ONE_ARG' >/dev/null 2>&1; then
  echo "FAIL (expected reject): missing value argument -> accepted"
  fail=$((fail + 1))
else
  echo "PASS (rejected): missing value argument"
  pass=$((pass + 1))
fi

# --- Acceptances ---
assert_accept 'DOCKERHUB_TOKEN' 'dckr_pat_abc123' "non-empty value"
assert_accept 'KUBECONFIG_PCBOX' "$(printf 'multi\nline\nvalue')" "multiline value"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
