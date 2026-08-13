#!/usr/bin/env bash
# Test harness for resolve-image-tag.sh.
#
# Run: bash scripts/tests/resolve-image-tag.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../resolve-image-tag.sh"

pass=0
fail=0

if [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET does not exist yet (expected in RED phase)"
  exit 1
fi

# --- A given tag is returned unchanged ---
ACTUAL="$("$TARGET" v1.2.3)"
if [ "$ACTUAL" = "v1.2.3" ]; then
  echo "PASS: a given tag is returned unchanged"
  pass=$((pass + 1))
else
  echo "FAIL: expected 'v1.2.3', got '$ACTUAL'"
  fail=$((fail + 1))
fi

# --- No argument defaults to master ---
ACTUAL="$("$TARGET")"
if [ "$ACTUAL" = "master" ]; then
  echo "PASS: no argument defaults to master"
  pass=$((pass + 1))
else
  echo "FAIL: expected 'master', got '$ACTUAL'"
  fail=$((fail + 1))
fi

# --- An empty-string argument also defaults to master ---
ACTUAL="$("$TARGET" "")"
if [ "$ACTUAL" = "master" ]; then
  echo "PASS: empty string argument defaults to master"
  pass=$((pass + 1))
else
  echo "FAIL: expected 'master', got '$ACTUAL'"
  fail=$((fail + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
