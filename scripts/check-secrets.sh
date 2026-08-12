#!/usr/bin/env bash
# Preflight for required secrets, mapped into the environment by the caller.
#
# Two modes, matching where the check runs:
#   warn  — PR-facing jobs. Fork and dependabot PRs legitimately arrive with
#           no secrets; a red job would train people to ignore red. Emits a
#           ::warning:: and `skip=true` so downstream jobs no-op green.
#   fail  — production (and anything else that must not silently degrade).
#
# Usage:
#   check-secrets.sh warn|fail NAME [NAME...]
#
# Each NAME is checked as an environment variable (the workflow maps
# `secrets.X` -> `env: X`). GITHUB_OUTPUT gets `skip=true|false`.
set -euo pipefail

MODE="${1:?usage: check-secrets.sh warn|fail NAME [NAME...]}"
shift
case "$MODE" in warn|fail) ;; *) echo "::error::check-secrets mode must be warn or fail, got '$MODE'"; exit 1;; esac

missing=()
for name in "$@"; do
  [ -n "${!name:-}" ] || missing+=("$name")
done

if [ "${#missing[@]}" -eq 0 ]; then
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "skip=false" >> "$GITHUB_OUTPUT"
  echo "all $# required secret(s) present"
  exit 0
fi

if [ "$MODE" = "fail" ]; then
  echo "::error::missing required secret(s): ${missing[*]}"
  exit 1
fi
echo "::warning::missing secret(s): ${missing[*]} — skipping deploy (expected for fork/dependabot PRs)"
[ -z "${GITHUB_OUTPUT:-}" ] || echo "skip=true" >> "$GITHUB_OUTPUT"
