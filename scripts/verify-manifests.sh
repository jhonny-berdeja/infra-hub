#!/usr/bin/env bash
# Static verification for apps/ticket-hub-api manifests (tasks.md Phase 4):
# reproduces the deploy workflow's placeholder substitution against a
# throwaway /tmp copy, asserts no placeholder token survives, then runs
# `kubectl apply --dry-run=client` against the substituted copy.
#
# Requires: kubectl on PATH (client-only, no cluster access needed for
# --dry-run=client). Run: bash scripts/verify-manifests.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/apps/ticket-hub-api"
WORK_DIR="$(mktemp -d /tmp/ticket-hub-api-manifests-verify.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

if ! command -v kubectl >/dev/null 2>&1; then
  echo "verify-manifests: kubectl not found on PATH — cannot run dry-run check" >&2
  exit 2
fi

# Mirror the deploy workflow: only the three manifests that are actually
# applied by CI (secret.example.yaml is a manual template, never applied).
cp "$SRC_DIR/namespace.yaml" "$SRC_DIR/deployment.yaml" "$SRC_DIR/service.yaml" "$WORK_DIR/"

FAKE_USER="exampleuser"
FAKE_TAG="master"

"$REPO_ROOT/.github/scripts/substitute-manifest-placeholders.sh" \
  "$FAKE_USER" "$FAKE_TAG" "$WORK_DIR/deployment.yaml"

echo "== Checking for leftover placeholder tokens =="
if grep -RE 'DOCKERHUB_USER|IMAGE_TAG' "$WORK_DIR" >/dev/null 2>&1; then
  echo "FAIL: leftover placeholder token found in substituted manifests" >&2
  grep -RnE 'DOCKERHUB_USER|IMAGE_TAG' "$WORK_DIR" >&2
  exit 1
fi
echo "PASS: no leftover placeholder tokens"

echo "== Checking substituted image reference =="
IMAGE_LINE="$(grep -E '^\s*image:' "$WORK_DIR/deployment.yaml")"
echo "$IMAGE_LINE"
if [[ "$IMAGE_LINE" != *"docker.io/$FAKE_USER/ticket-hub-api:$FAKE_TAG"* ]]; then
  echo "FAIL: substituted image reference does not match expected shape" >&2
  exit 1
fi
echo "PASS: image reference substituted correctly"

echo "== kubectl apply --dry-run=client =="
kubectl apply --dry-run=client -f "$WORK_DIR/"

echo ""
echo "All manifest checks passed."
