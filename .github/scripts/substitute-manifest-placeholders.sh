#!/usr/bin/env bash
# Replaces the DOCKERHUB_USER and IMAGE_TAG placeholders in a manifest
# file in place.
#
# Usage: substitute-manifest-placeholders.sh <dockerhub-username> <image-tag> <manifest-file>
set -euo pipefail

DOCKERHUB_USERNAME="${1-}"
IMAGE_TAG="${2-}"
MANIFEST_FILE="${3-}"

if [ -z "$DOCKERHUB_USERNAME" ] || [ -z "$IMAGE_TAG" ] || [ -z "$MANIFEST_FILE" ]; then
  echo "substitute-manifest-placeholders: expected <dockerhub-username> <image-tag> <manifest-file>" >&2
  exit 1
fi

if [ ! -f "$MANIFEST_FILE" ]; then
  echo "substitute-manifest-placeholders: manifest file not found: '$MANIFEST_FILE'" >&2
  exit 1
fi

sed -i \
  -e "s|DOCKERHUB_USER|$DOCKERHUB_USERNAME|g" \
  -e "s|IMAGE_TAG|$IMAGE_TAG|g" \
  "$MANIFEST_FILE"
