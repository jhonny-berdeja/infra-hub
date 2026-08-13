#!/usr/bin/env bash
# Test harness for print-deployed-image.sh. Stubs `kubectl` via PATH
# so no real cluster call happens.
#
# Run: bash scripts/tests/print-deployed-image.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../print-deployed-image.sh"

pass=0
fail=0

if [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET does not exist yet (expected in RED phase)"
  exit 1
fi

FAKE_BIN_DIR="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN_DIR"' EXIT

cat > "$FAKE_BIN_DIR/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "docker.io/someuser/testapp:v1.2.3"
EOF
chmod +x "$FAKE_BIN_DIR/kubectl"

# --- Prints the header line and the image reference from kubectl ---
ACTUAL="$(PATH="$FAKE_BIN_DIR:$PATH" "$TARGET" testapp ticket-hub)"
EXPECTED="$(printf 'Deployed image:\ndocker.io/someuser/testapp:v1.2.3')"
if [ "$ACTUAL" = "$EXPECTED" ]; then
  echo "PASS: prints the header and the deployed image reference"
  pass=$((pass + 1))
else
  echo "FAIL: expected '$EXPECTED', got '$ACTUAL'"
  fail=$((fail + 1))
fi

# --- Missing arguments are rejected ---
if PATH="$FAKE_BIN_DIR:$PATH" "$TARGET" testapp >/dev/null 2>&1; then
  echo "FAIL (expected reject): missing namespace was accepted"
  fail=$((fail + 1))
else
  echo "PASS (rejected): missing namespace"
  pass=$((pass + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
