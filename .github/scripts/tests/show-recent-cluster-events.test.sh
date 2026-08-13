#!/usr/bin/env bash
# Test harness for show-recent-cluster-events.sh. Stubs `kubectl` via
# PATH so no real cluster call happens.
#
# Run: bash scripts/tests/show-recent-cluster-events.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../show-recent-cluster-events.sh"

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
printf 'event-1\nevent-2\n'
EOF
chmod +x "$FAKE_BIN_DIR/kubectl"

# --- Prints the events from kubectl ---
ACTUAL="$(PATH="$FAKE_BIN_DIR:$PATH" "$TARGET" ticket-hub)"
EXPECTED="$(printf 'event-1\nevent-2')"
if [ "$ACTUAL" = "$EXPECTED" ]; then
  echo "PASS: prints the events from kubectl"
  pass=$((pass + 1))
else
  echo "FAIL: expected '$EXPECTED', got '$ACTUAL'"
  fail=$((fail + 1))
fi

# --- A failing kubectl never fails the script (never blocks the caller) ---
cat > "$FAKE_BIN_DIR/kubectl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_BIN_DIR/kubectl"
if PATH="$FAKE_BIN_DIR:$PATH" "$TARGET" ticket-hub; then
  echo "PASS: a failing kubectl doesn't fail the script"
  pass=$((pass + 1))
else
  echo "FAIL: script failed even though it should swallow kubectl errors"
  fail=$((fail + 1))
fi

# --- Missing namespace argument is rejected ---
if PATH="$FAKE_BIN_DIR:$PATH" "$TARGET" >/dev/null 2>&1; then
  echo "FAIL (expected reject): missing namespace was accepted"
  fail=$((fail + 1))
else
  echo "PASS (rejected): missing namespace"
  pass=$((pass + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
