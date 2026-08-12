#!/usr/bin/env bash
# Release the review hostname slot(s) held by a PR.
#
# Called AFTER reap-review-env.sh, and deliberately last in the teardown order:
# a freed lease is an invitation for the next claimer, and the invitation must
# not go out while the departing environment's ingress still serves the slot
# hostname. So we wait for the ingress to disappear (it lives in the deleting
# namespace and goes quickly, well before namespace finalization) before
# deleting the lease.
#
# Deletion is BY LABEL, not by slot index: teardown often runs after the branch
# is gone and must not need to reconstruct which slot the PR held.
#
# Usage:
#   release-slot.sh <app> <pr-number>
#
# Environment:
#   SLOTS_NS         lease namespace (default: review-slots)
#   INGRESS_TIMEOUT  seconds to wait for the ingress to vanish (default: 120)
set -euo pipefail

APP="${1:?usage: release-slot.sh <app> <pr-number>}"
PR="${2:?usage: release-slot.sh <app> <pr-number>}"

SLOTS_NS="${SLOTS_NS:-review-slots}"
INGRESS_TIMEOUT="${INGRESS_TIMEOUT:-120}"
NS="$APP-pr$PR"
SEL="review.ledoent.dev/app=$APP,review.ledoent.dev/pr=$PR"

deadline=$(( SECONDS + INGRESS_TIMEOUT ))
while [ "$SECONDS" -lt "$deadline" ]; do
  remaining=$( { kubectl -n "$NS" get ingress --no-headers 2>/dev/null || true; } | wc -l | tr -d ' ')
  [ "$remaining" = "0" ] && break
  sleep 3
done
if [ "${remaining:-0}" != "0" ]; then
  echo "::warning::ingress still present in $NS after ${INGRESS_TIMEOUT}s; releasing the slot anyway — the deploy-side ingress preflight is the second net"
fi

kubectl delete lease -n "$SLOTS_NS" -l "$SEL" --ignore-not-found
echo "released slot lease(s) for $APP PR #$PR"
