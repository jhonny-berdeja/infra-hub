#!/usr/bin/env bash
# Resolves the image tag to deploy: the given value, or "master" if
# empty. Prints the resolved tag to stdout.
#
# Usage: resolve-image-tag.sh [requested-tag]
set -euo pipefail

REQUESTED_TAG="${1-}"

if [ -z "$REQUESTED_TAG" ]; then
  echo "master"
else
  echo "$REQUESTED_TAG"
fi
