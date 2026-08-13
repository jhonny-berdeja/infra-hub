#!/usr/bin/env bash
# Writes the kubeconfig content to ~/.kube/config with 0600
# permissions, so kubectl can authenticate against the cluster.
# Handles mkdir + write + chmod as one atomic unit -- unlike the
# GITHUB_ENV/GITHUB_STEP_SUMMARY scripts elsewhere in this ecosystem,
# this one owns writing its target file directly, because the
# permission requirement (0600) has to apply from the instant the file
# has content, not after a caller's separate step gets around to it.
#
# Requires KUBECONFIG_CONTENT as an environment variable.
#
# Usage: save-kubeconfig.sh
set -euo pipefail

if [ -z "${KUBECONFIG_CONTENT-}" ]; then
  echo "save-kubeconfig: KUBECONFIG_CONTENT must be set" >&2
  exit 1
fi

mkdir -p ~/.kube
echo "$KUBECONFIG_CONTENT" > ~/.kube/config
chmod 600 ~/.kube/config
