#!/usr/bin/env bash
# Prints the currently deployed image reference for a deployment.
#
# Usage: print-deployed-image.sh <deployment-name> <namespace>
set -euo pipefail

DEPLOYMENT_NAME="${1-}"
NAMESPACE="${2-}"

if [ -z "$DEPLOYMENT_NAME" ] || [ -z "$NAMESPACE" ]; then
  echo "print-deployed-image: expected <deployment-name> <namespace>" >&2
  exit 1
fi

echo "Deployed image:"
kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
