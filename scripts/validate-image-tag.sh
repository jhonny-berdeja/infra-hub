#!/usr/bin/env bash
# Validates a deploy image tag before it is interpolated into a `sed -i`
# expression and `kubectl` arguments inside a workflow `run:` block
# (design ADR-7). Fail-closed: any input that does not match the allowed
# character set and length is rejected.
#
# Usage: validate-image-tag.sh <tag>
# Exit 0: tag is safe to use. Exit 1: tag rejected (or missing argument).
set -u

TAG="${1-}"

# Exactly one argument, non-empty, 1-128 chars, only
# [a-zA-Z0-9._-] — matches Docker tag-safe characters and excludes every
# shell metacharacter, path separator, and whitespace.
if [ "$#" -ne 1 ]; then
  echo "validate-image-tag: expected exactly one argument (the image tag)" >&2
  exit 1
fi

if [[ ! "$TAG" =~ ^[a-zA-Z0-9._-]{1,128}$ ]]; then
  echo "validate-image-tag: rejected tag (invalid characters, empty, or over 128 chars)" >&2
  exit 1
fi

# Reject a leading dash even though the character class already allows
# '-': a leading dash could be misread as a flag by a downstream command
# that receives this value unquoted.
if [[ "$TAG" == -* ]]; then
  echo "validate-image-tag: rejected tag (leading dash)" >&2
  exit 1
fi

exit 0
