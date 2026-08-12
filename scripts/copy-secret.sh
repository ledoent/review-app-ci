#!/usr/bin/env bash
# Copy a Secret from one namespace to another, metadata reduced to
# name+namespace on purpose: carrying resourceVersion across namespaces
# asserts a history the target does not have, and `kubectl apply` rejects it
# on the SECOND run — so it survives first testing and fails later.
#
# Usage:
#   copy-secret.sh <secret-name> <source-namespace> <target-namespace> [<target-name>]
#
# The optional target-name renames on copy — the overlays reference one
# canonical name (e.g. wildcard-tls) while clusters may store the source
# under another (mi-wildcard-tls on meas-apps).
set -euo pipefail

NAME="${1:?usage: copy-secret.sh <secret-name> <source-ns> <target-ns> [<target-name>]}"
SRC="${2:?usage: copy-secret.sh <secret-name> <source-ns> <target-ns> [<target-name>]}"
DST="${3:?usage: copy-secret.sh <secret-name> <source-ns> <target-ns> [<target-name>]}"
DST_NAME="${4:-$NAME}"

kubectl -n "$SRC" get secret "$NAME" -o json \
  | jq --arg ns "$DST" --arg name "$DST_NAME" \
       '{apiVersion, kind, type, data, metadata: {name: $name, namespace: $ns}}' \
  | kubectl apply -f - >/dev/null
echo "copied secret $NAME: $SRC -> $DST/$DST_NAME"
