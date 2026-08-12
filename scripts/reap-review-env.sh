#!/usr/bin/env bash
# Destroy one review environment: its namespace, and (light tier) the Database
# CR that lives outside it in the staging namespace.
#
# Two callers — the teardown workflow when a PR closes or its label comes off,
# and the nightly sweep for the environments teardown never got to. They must
# share this file: earlier per-repo copies drifted (`payload_pr<N>` vs
# `payload-pr<N>`) and one of them silently reaped nothing.
#
# ORDER IS THE WHOLE POINT OF THIS FILE. The namespace goes first.
#
# The Database CR carries CNPG's `cnpg.io/deleteDatabase` finalizer, which runs
# DROP DATABASE. Postgres refuses to drop a database while a session is
# attached, and the session belongs to the app pod inside the namespace.
# Deleting the CR first blocks on a finalizer that cannot be released until the
# namespace — deleted afterwards — is gone. Observed live: 24 minutes, no
# progress, converging only once the namespace was removed by hand.
#
# Usage:
#   reap-review-env.sh <namespace> <database-cr>|- [--strict]
#
#   <database-cr>  "-" for full-tier environments (their CNPG cluster lives
#                  inside the namespace and dies with it).
#   --strict       exit non-zero if the Database CR does not finish deleting.
#                  Teardown uses it: a caller that reports success while
#                  leaving a database behind is worse than a red job. The
#                  sweep does not: one stuck CR must not stop the rest.
#
# Environment:
#   STAGING_NS      namespace holding the CNPG cluster (required unless CR is -)
#   DRAIN_TIMEOUT   seconds to wait for pods to go away (default: 300)
#   DELETE_TIMEOUT  seconds to wait for the CR to finalize (default: 180)
set -euo pipefail

NS="${1:?usage: reap-review-env.sh <namespace> <database-cr>|- [--strict]}"
DB_CR="${2:?usage: reap-review-env.sh <namespace> <database-cr>|- [--strict]}"
STRICT="${3:-}"

DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-300}"
DELETE_TIMEOUT="${DELETE_TIMEOUT:-180}"

# --wait=false: we do not need the namespace object fully finalized, only its
# pods gone, and that happens much sooner. The drain loop below is the real wait.
kubectl delete namespace "$NS" --ignore-not-found --wait=false

# Wait on pods, not on the namespace. Pods disappearing is the actual
# precondition for the drop, and it is reached well before the namespace
# finishes finalizing.
#
# `|| true` on the kubectl, not on the pipeline: when the namespace is already
# gone — the normal case for a PR that never had an environment — kubectl exits
# non-zero, and under `pipefail` that would take the whole script down.
remaining=""
deadline=$(( SECONDS + DRAIN_TIMEOUT ))
while [ "$SECONDS" -lt "$deadline" ]; do
  remaining=$( { kubectl -n "$NS" get pods --no-headers 2>/dev/null || true; } | wc -l | tr -d ' ')
  [ "$remaining" = "0" ] && break
  sleep 5
done
if [ "${remaining:-0}" != "0" ]; then
  echo "::warning::pods still present in $NS after ${DRAIN_TIMEOUT}s; the drop below may fail"
else
  echo "pods drained from $NS"
fi

if [ "$DB_CR" = "-" ]; then
  echo "destroyed $NS (no external Database CR)"
  exit 0
fi

: "${STAGING_NS:?STAGING_NS must be set when a Database CR is given}"

# With no sessions attached the drop succeeds on CNPG's first reconcile. On
# failure the reconciler backs off about five minutes before retrying, so the
# ordering above is the difference between a teardown measured in seconds and
# one measured in minutes.
if kubectl -n "$STAGING_NS" delete database "$DB_CR" \
     --ignore-not-found --timeout="${DELETE_TIMEOUT}s"; then
  echo "destroyed $NS and $DB_CR"
  exit 0
fi

if [ "$STRICT" = "--strict" ]; then
  echo "::error::$DB_CR did not finish deleting; check for sessions still attached"
  exit 1
fi
echo "::warning::$DB_CR did not finish deleting; the next sweep will retry"
