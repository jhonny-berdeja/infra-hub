#!/usr/bin/env bash
# Fails a workflow fast when a required secrets.* value is missing, instead
# of letting the job that actually needs it fail deep into the pipeline
# (a Docker Hub login, a Tailscale join, a kubectl apply, ...) with a less
# obvious error. Called once per required secret, always as the first
# steps of the first job in a workflow, per
# jtagram/.claude/infra/ci-cd-conventions.md.
#
# Usage: assert-secret-is-set.sh <SECRET_NAME> <SECRET_VALUE>
# Exit 0: the secret is set. Exit 1: missing argument, or the secret is empty.
set -u

if [ "$#" -ne 2 ]; then
  echo "assert-secret-is-set: expected exactly two arguments (the secret name and its value)" >&2
  exit 1
fi

SECRET_NAME="$1"
SECRET_VALUE="$2"

if [ -z "$SECRET_VALUE" ]; then
  echo "assert-secret-is-set: required secret $SECRET_NAME is not set" >&2
  exit 1
fi

exit 0
