#!/usr/bin/env bash
# Claim a review hostname slot for a PR.
#
# Slots exist because app-level OAuth (Google, notably) requires exact,
# pre-registered redirect URIs — no wildcards — so review hostnames come from a
# fixed pool <app>-review<1..N>.<domain> registered once in the OAuth client.
# The pool is a set of coordination.k8s.io/v1 Lease objects in the
# `review-slots` namespace; `kubectl create` on a Lease is atomic at the API
# server, which makes create-the-lease the lock. Lowest free slot wins.
#
# NOT derived from the PR number (no modulus): derivation collides
# deterministically (PR 45 and PR 49 fight over slot 1 forever) and a lease
# frees whenever its PR closes, in any order.
#
# Usage:
#   claim-slot.sh <app> <pr-number> <pool-size> <domain>
#
# Environment:
#   SLOTS_NS            lease namespace          (default: review-slots)
#   GITHUB_REPOSITORY   owner/repo, recorded on the lease
#   GH_TOKEN            optional; enables the on-exhaustion orphan check
#   GITHUB_OUTPUT       written with slot/host/url/namespace when set
#
# Exit 0 with outputs on success; exit 1 with an ::error:: listing holders on
# exhaustion.
set -euo pipefail

APP="${1:?usage: claim-slot.sh <app> <pr-number> <pool-size> <domain>}"
PR="${2:?usage: claim-slot.sh <app> <pr-number> <pool-size> <domain>}"
POOL="${3:?usage: claim-slot.sh <app> <pr-number> <pool-size> <domain>}"
DOMAIN="${4:?usage: claim-slot.sh <app> <pr-number> <pool-size> <domain>}"

SLOTS_NS="${SLOTS_NS:-review-slots}"
SEL="review.ledoent.dev/app=$APP"

# Without this, a missing namespace makes every lease create fail and the
# script reports "all slots taken" — observed on the first pilot run.
if ! kubectl get namespace "$SLOTS_NS" >/dev/null 2>&1; then
  echo "::error::the $SLOTS_NS namespace does not exist on this cluster — apply the review-platform infra (review-slots namespace + RBAC) before deploying review environments"
  exit 1
fi

emit() { # emit <slot>
  local slot="$1" host
  host="$APP-review$1.$DOMAIN"
  echo "claimed slot $slot -> https://$host"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "slot=$slot"
      echo "host=$host"
      echo "url=https://$host"
      echo "namespace=$APP-pr$PR"
    } >> "$GITHUB_OUTPUT"
  fi
}

lease_manifest() { # lease_manifest <slot>
  cat <<EOF
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: $APP-slot-$1
  namespace: $SLOTS_NS
  labels:
    review.ledoent.dev/app: "$APP"
    review.ledoent.dev/pr: "$PR"
  annotations:
    review.ledoent.dev/host: "$APP-review$1.$DOMAIN"
    review.ledoent.dev/namespace: "$APP-pr$PR"
    review.ledoent.dev/repo: "${GITHUB_REPOSITORY:-unknown}"
spec:
  holderIdentity: "pr-$PR"
  acquireTime: "$(date -u +%FT%T.000000Z)"
EOF
}

try_claim() {
  local i
  # Fast path: redeploys reuse the slot this PR already holds. Looked up by
  # label, never recomputed, so a slot-count change cannot strand a live env.
  local held
  held=$(kubectl get lease -n "$SLOTS_NS" -l "$SEL,review.ledoent.dev/pr=$PR" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$held" ]; then
    emit "${held##"$APP-slot-"}"
    return 0
  fi
  for i in $(seq 1 "$POOL"); do
    if lease_manifest "$i" | kubectl create -f - 2>/dev/null; then
      emit "$i"
      return 0
    fi
  done
  return 1
}

try_claim && exit 0

# Pool exhausted. Before failing, reap leases whose holder PR is no longer
# open — the out-of-order-close case the nightly sweep would otherwise pick up
# hours later — then retry once.
if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  while IFS=$'\t' read -r name holder_pr repo; do
    [ -n "$name" ] || continue
    # Test gh's EXIT STATUS, not its output: a 404 with --jq prints nothing.
    state=$(gh api "repos/${repo}/pulls/${holder_pr}" --jq .state 2>/dev/null) || state="missing"
    if [ "$state" != "open" ]; then
      echo "slot lease $name held by ${repo}#${holder_pr} ($state); reaping"
      ns=$(kubectl get lease -n "$SLOTS_NS" "$name" \
        -o jsonpath='{.metadata.annotations.review\.ledoent\.dev/namespace}')
      # DB_CR_PREFIX (e.g. "payload-pr") names the orphan's Database CR; unset
      # means full tier — the CR lives inside the namespace and needs no step.
      orphan_cr="-"
      [ -n "${DB_CR_PREFIX:-}" ] && orphan_cr="${DB_CR_PREFIX}${holder_pr}"
      "$(dirname "$0")/reap-review-env.sh" "$ns" "$orphan_cr" || true
      kubectl delete lease -n "$SLOTS_NS" "$name" --ignore-not-found
    fi
  done < <(kubectl get lease -n "$SLOTS_NS" -l "$SEL" -o json \
    | jq -r '.items[] | [.metadata.name,
                         .metadata.labels["review.ledoent.dev/pr"],
                         .metadata.annotations["review.ledoent.dev/repo"]] | @tsv')
  try_claim && exit 0
fi

holders=$(kubectl get lease -n "$SLOTS_NS" -l "$SEL" -o json \
  | jq -r '.items[] | "  " + .metadata.name + " -> PR #" +
           (.metadata.labels["review.ledoent.dev/pr"] // "?") +
           " since " + (.spec.acquireTime // "?")')
echo "::error::all $POOL review slots for $APP are taken — close a PR or remove its review label"
printf '%s\n' "$holders"
exit 1
