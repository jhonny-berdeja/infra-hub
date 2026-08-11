#!/usr/bin/env bash
# Test harness for validate-image-tag.sh (design ADR-7 / spec: image_tag as
# shell input). Table-driven: each case invokes the script with one
# argument and asserts the expected exit code.
#
# Run: bash scripts/validate-image-tag.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/validate-image-tag.sh"

pass=0
fail=0

# assert_reject <tag> <label>
assert_reject() {
  local tag="$1" label="$2"
  if "$TARGET" "$tag" >/dev/null 2>&1; then
    echo "FAIL (expected reject): $label -> '$tag' was accepted"
    fail=$((fail + 1))
  else
    echo "PASS (rejected): $label"
    pass=$((pass + 1))
  fi
}

# assert_accept <tag> <label>
assert_accept() {
  local tag="$1" label="$2"
  if "$TARGET" "$tag" >/dev/null 2>&1; then
    echo "PASS (accepted): $label"
    pass=$((pass + 1))
  else
    echo "FAIL (expected accept): $label -> '$tag' was rejected"
    fail=$((fail + 1))
  fi
}

if [ ! -x "$TARGET" ] && [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET does not exist yet (expected in RED phase)"
  exit 1
fi

# --- Rejections: shell metacharacters / injection shapes ---
assert_reject 'master; rm -rf /' "semicolon"
assert_reject 'master && rm -rf /' "double ampersand"
assert_reject 'master & rm -rf /' "single ampersand"
assert_reject 'master | rm -rf /' "pipe"
assert_reject 'master`rm -rf /`' "backtick substitution"
assert_reject 'master$(rm -rf /)' "dollar-paren substitution"
assert_reject "$(printf 'master\nrm -rf /')" "embedded newline"
assert_reject '../../etc/passwd' "path traversal"
assert_reject '' "empty string"
assert_reject "$(printf 'a%.0s' $(seq 1 129))" "over 128 chars"
assert_reject '-rf' "leading dash (flag injection)"

# --- Acceptances: legitimate tags ---
assert_accept 'master' "branch name master"
assert_accept 'v1.2.3-rc.1' "semver-ish tag"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
