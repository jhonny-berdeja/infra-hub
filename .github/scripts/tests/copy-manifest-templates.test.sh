#!/usr/bin/env bash
# Test harness for copy-manifest-templates.sh. Runs from a temp
# directory with a fake apps/<app-name>/ layout.
#
# Run: bash scripts/tests/copy-manifest-templates.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../copy-manifest-templates.sh"

pass=0
fail=0

if [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET does not exist yet (expected in RED phase)"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR" "/tmp/testapp-manifests"' EXIT

mkdir -p "$WORK_DIR/apps/testapp"
echo "deployment content" > "$WORK_DIR/apps/testapp/deployment.yaml"
echo "service content" > "$WORK_DIR/apps/testapp/service.yaml"
echo "namespace content" > "$WORK_DIR/apps/testapp/namespace.yaml"

cd "$WORK_DIR"

# --- Copies only the requested manifest files, prints the work dir ---
OUTPUT="$("$TARGET" testapp deployment.yaml service.yaml)"
if [ "$OUTPUT" = "/tmp/testapp-manifests" ] \
  && [ -f "/tmp/testapp-manifests/deployment.yaml" ] \
  && [ -f "/tmp/testapp-manifests/service.yaml" ] \
  && [ ! -f "/tmp/testapp-manifests/namespace.yaml" ]; then
  echo "PASS: copies only the requested manifest files and prints the work dir"
  pass=$((pass + 1))
else
  echo "FAIL: unexpected output or file layout (output='$OUTPUT')"
  ls -la /tmp/testapp-manifests 2>&1
  fail=$((fail + 1))
fi

# --- Missing app name is rejected ---
if "$TARGET" >/dev/null 2>&1; then
  echo "FAIL (expected reject): missing app name was accepted"
  fail=$((fail + 1))
else
  echo "PASS (rejected): missing app name"
  pass=$((pass + 1))
fi

# --- No manifest files given is rejected ---
if "$TARGET" testapp >/dev/null 2>&1; then
  echo "FAIL (expected reject): no manifest files was accepted"
  fail=$((fail + 1))
else
  echo "PASS (rejected): no manifest files given"
  pass=$((pass + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
