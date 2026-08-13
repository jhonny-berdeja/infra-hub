#!/usr/bin/env bash
# Prints the most recent 50 cluster events for a namespace, sorted by
# timestamp. Never fails the caller -- this runs only as a diagnostic
# after an already-failed deploy (via `if: failure()`), and a
# diagnostics step failing on top of that would hide the real error.
#
# Usage: show-recent-cluster-events.sh <namespace>
set -uo pipefail

NAMESPACE="${1-}"

if [ -z "$NAMESPACE" ]; then
  echo "show-recent-cluster-events: expected the namespace as the first argument" >&2
  exit 1
fi

kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -n 50 || true
