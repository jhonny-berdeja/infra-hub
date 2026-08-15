#!/usr/bin/env bash
# Replaces the PCBOX_SSH_HOST_VALUE and PCBOX_SSH_USER_VALUE placeholders
# in a manifest file in place. Separate from substitute-manifest-placeholders.sh
# on purpose: that script is shared by every deploy workflow
# (deploy-ticket-hub-api.yml, deploy-ticket-hub.yml too), and neither of
# those needs an SSH host/user — keeping this pcbox-api-only substitution
# in its own script means it can never affect the other two.
#
# Usage: substitute-pcbox-ssh-placeholders.sh <ssh-host> <ssh-user> <manifest-file>
set -euo pipefail

SSH_HOST="${1-}"
SSH_USER="${2-}"
MANIFEST_FILE="${3-}"

if [ -z "$SSH_HOST" ] || [ -z "$SSH_USER" ] || [ -z "$MANIFEST_FILE" ]; then
  echo "substitute-pcbox-ssh-placeholders: expected <ssh-host> <ssh-user> <manifest-file>" >&2
  exit 1
fi

if [ ! -f "$MANIFEST_FILE" ]; then
  echo "substitute-pcbox-ssh-placeholders: manifest file not found: '$MANIFEST_FILE'" >&2
  exit 1
fi

sed -i \
  -e "s|PCBOX_SSH_HOST_VALUE|$SSH_HOST|g" \
  -e "s|PCBOX_SSH_USER_VALUE|$SSH_USER|g" \
  "$MANIFEST_FILE"
