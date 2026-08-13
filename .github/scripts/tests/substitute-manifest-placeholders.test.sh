#!/usr/bin/env bash
# Test harness for substitute-manifest-placeholders.sh.
#
# Run: bash scripts/tests/substitute-manifest-placeholders.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../substitute-manifest-placeholders.sh"

pass=0
fail=0

if [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET does not exist yet (expected in RED phase)"
  exit 1
fi

MANIFEST_FILE="$(mktemp)"
trap 'rm -f "$MANIFEST_FILE"' EXIT

# --- Replaces both placeholders in place ---
printf 'image: docker.io/DOCKERHUB_USER/testapp:IMAGE_TAG\n' > "$MANIFEST_FILE"
"$TARGET" someuser v1.2.3 "$MANIFEST_FILE"
ACTUAL="$(cat "$MANIFEST_FILE")"
EXPECTED="image: docker.io/someuser/testapp:v1.2.3"
if [ "$ACTUAL" = "$EXPECTED" ]; then
  echo "PASS: replaces both placeholders in place"
  pass=$((pass + 1))
else
  echo "FAIL: expected '$EXPECTED', got '$ACTUAL'"
  fail=$((fail + 1))
fi

# --- Missing manifest file is rejected ---
if "$TARGET" someuser v1.2.3 /tmp/does-not-exist-file.yaml >/dev/null 2>&1; then
  echo "FAIL (expected reject): missing manifest file was accepted"
  fail=$((fail + 1))
else
  echo "PASS (rejected): missing manifest file"
  pass=$((pass + 1))
fi

# --- Missing arguments are rejected ---
if "$TARGET" someuser v1.2.3 >/dev/null 2>&1; then
  echo "FAIL (expected reject): missing manifest-file argument was accepted"
  fail=$((fail + 1))
else
  echo "PASS (rejected): missing manifest-file argument"
  pass=$((pass + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
