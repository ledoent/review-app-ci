#!/usr/bin/env bash
# Copy a Secret from one namespace to another, metadata reduced to
# name+namespace on purpose: carrying resourceVersion across namespaces
# asserts a history the target does not have, and `kubectl apply` rejects it
# on the SECOND run — so it survives first testing and fails later.
#
# Usage:
#   copy-secret.sh <secret-name> <source-namespace> <target-namespace>
set -euo pipefail

NAME="${1:?usage: copy-secret.sh <secret-name> <source-ns> <target-ns>}"
SRC="${2:?usage: copy-secret.sh <secret-name> <source-ns> <target-ns>}"
DST="${3:?usage: copy-secret.sh <secret-name> <source-ns> <target-ns>}"

kubectl -n "$SRC" get secret "$NAME" -o json \
  | jq --arg ns "$DST" '{apiVersion, kind, type, data,
                         metadata: {name: .metadata.name, namespace: $ns}}' \
  | kubectl apply -f - >/dev/null
echo "copied secret $NAME: $SRC -> $DST"
