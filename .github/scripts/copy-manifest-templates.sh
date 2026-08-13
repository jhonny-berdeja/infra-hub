#!/usr/bin/env bash
# Copies the given manifest files from apps/<app-name>/ into a fresh
# working directory (/tmp/<app-name>-manifests), for placeholder
# substitution and kubectl apply. Prints the working directory path to
# stdout so the caller can reuse it in later steps.
#
# Shared by every app's deploy workflow -- each app passes its own
# manifest file list (they differ: e.g. ticket-hub-api also has
# namespace.yaml, ticket-hub doesn't), instead of duplicating this
# copy logic per app.
#
# Usage: copy-manifest-templates.sh <app-name> <manifest-file>...
set -euo pipefail

APP_NAME="${1-}"
if [ -n "${1-}" ]; then
  shift
fi

if [ -z "$APP_NAME" ] || [ "$#" -eq 0 ]; then
  echo "copy-manifest-templates: expected <app-name> and at least one manifest file" >&2
  exit 1
fi

WORK_DIR="/tmp/${APP_NAME}-manifests"
mkdir -p "$WORK_DIR"

for MANIFEST in "$@"; do
  cp "apps/$APP_NAME/$MANIFEST" "$WORK_DIR/"
done

echo "$WORK_DIR"
