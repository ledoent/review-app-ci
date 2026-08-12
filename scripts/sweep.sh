#!/usr/bin/env bash
# Nightly reaper for review environments the teardown workflow never got to.
#
# This is not belt-and-braces. GitHub gives no guarantee that a teardown fires:
# a cancelled run, a repository rename, a workflow edited while a PR is open —
# all skip it silently. Observed on a real cluster: six orphaned review
# namespaces from an earlier attempt, found only because something else went
# looking. An orphaned namespace is not free: it holds an app pod against the
# cluster's request budget and, on the full tier, volumes that bill monthly.
#
# Passes, in order:
#   1. namespaces  ^<ns-prefix><N>$   — reap when the PR is missing/closed/
#      unlabelled, or older than TTL even when open and labelled ("a review
#      environment alive for two days is being used as staging").
#   2. Database CRs in STAGING_NS     — orphans whose namespace already went
#      (the case pass 1 structurally cannot see). Light tier only.
#   3. slot Leases in SLOTS_NS        — leases whose namespace is gone or
#      whose PR is closed. This is what makes slot exhaustion self-healing.
#   4. PersistentVolumes              — report-only; the failure that bills
#      silently, so it warns even when nothing was reaped.
#
# The <ns-prefix> regex is the whole safety boundary between apps sharing a
# cluster (duropc-pr<N> vs duropc-legacy's duropc-review-pr<N>): it is an
# input, never a wildcard.
#
# Runs on Linux runners (GNU date). Usage:
#   sweep.sh <app>
#
# Environment:
#   REPO            owner/repo of the app (required)
#   GH_TOKEN        token for PR lookups (required)
#   NS_PREFIX       namespace prefix     (default: <app>-pr)
#   DB_CR_PREFIX    Database CR prefix, e.g. payload-pr (empty = full tier)
#   STAGING_NS      CNPG staging namespace (required when DB_CR_PREFIX set)
#   SLOTS_NS        lease namespace      (default: review-slots)
#   TTL_HOURS       max age              (default: 48)
#   REVIEW_LABELS   comma list; when set, an open PR must carry one to keep
#                   its env (label-gated apps). Empty = auto-trigger mode.
#   DRY_RUN         "true" = report only (default: true — schedule passes false)
set -euo pipefail

APP="${1:?usage: sweep.sh <app>}"
: "${REPO:?REPO must be set (owner/repo)}"
: "${GH_TOKEN:?GH_TOKEN must be set}"

NS_PREFIX="${NS_PREFIX:-$APP-pr}"
DB_CR_PREFIX="${DB_CR_PREFIX:-}"
SLOTS_NS="${SLOTS_NS:-review-slots}"
TTL_HOURS="${TTL_HOURS:-48}"
REVIEW_LABELS="${REVIEW_LABELS:-}"
DRY_RUN="${DRY_RUN:-true}"
[ -z "$DB_CR_PREFIX" ] || : "${STAGING_NS:?STAGING_NS must be set when DB_CR_PREFIX is set}"

HERE="$(cd "$(dirname "$0")" && pwd)"

# One call per PR, and a real success check: `gh api --jq` writes its error
# body to stdout on a 404, so an `|| echo missing` form produces JSON
# concatenated with "missing" — matching nothing. Test the exit status.
pr_state() { # pr_state <n> -> "open"/"closed"/"missing", sets PR_LABELS
  local json
  if json=$(gh api "repos/$REPO/pulls/$1" 2>/dev/null); then
    PR_LABELS=$(echo "$json" | jq -r '[.labels[].name] | join(",")')
    echo "$json" | jq -r .state
  else
    PR_LABELS=""
    echo "missing"
  fi
}

now=$(date -u +%s)
reaped=0

# ---- pass 1: namespaces -----------------------------------------------------
mapfile -t NS < <(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.creationTimestamp}{"\n"}{end}' \
                  | grep -E "^${NS_PREFIX}[0-9]+ " || true)
# No early exit on an empty list: passes 2-3 exist precisely for objects whose
# namespace already went, so "no namespaces" is when they matter most.
if [ "${#NS[@]}" -eq 0 ]; then echo "no review namespaces"; fi

for entry in "${NS[@]}"; do
  ns="${entry%% *}"; created="${entry##* }"
  pr="${ns#"$NS_PREFIX"}"
  age_h=$(( (now - $(date -u -d "$created" +%s)) / 3600 ))

  state=$(pr_state "$pr")
  reason=""
  if [ "$state" = "missing" ]; then
    reason="PR #$pr does not exist"
  elif [ "$state" != "open" ]; then
    reason="PR #$pr is $state"
  elif [ -n "$REVIEW_LABELS" ] && ! echo ",$PR_LABELS," | grep -qE ",($(echo "$REVIEW_LABELS" | tr ',' '|')),"; then
    reason="PR #$pr carries no review label"
  elif [ "$age_h" -ge "$TTL_HOURS" ]; then
    # Deliberately reaps open, labelled PRs past TTL: a review environment is
    # for reviewing; one alive for two days is being used as staging, and
    # staging is a command (or a relabel) away.
    reason="older than ${TTL_HOURS}h (${age_h}h) — redeploy to rebuild"
  fi

  if [ -z "$reason" ]; then
    echo "keep   $ns (PR #$pr open, ${age_h}h)"
    continue
  fi

  echo "REAP   $ns — $reason"
  reaped=$((reaped+1))
  if [ "$DRY_RUN" != "true" ]; then
    db_cr="-"
    [ -n "$DB_CR_PREFIX" ] && db_cr="${DB_CR_PREFIX}${pr}"
    # No --strict: one environment refusing to die must not stop the sweep
    # reaping the rest. It warns, and the next run retries.
    "$HERE/reap-review-env.sh" "$ns" "$db_cr"
  fi
done

# ---- pass 2: orphan Database CRs (light tier) -------------------------------
if [ -n "$DB_CR_PREFIX" ]; then
  for db in $(kubectl -n "$STAGING_NS" get database \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
              | grep -E "^${DB_CR_PREFIX}[0-9]+$" || true); do
    pr="${db#"$DB_CR_PREFIX"}"
    if kubectl get namespace "${NS_PREFIX}${pr}" >/dev/null 2>&1; then
      continue
    fi
    echo "REAP   $db — no ${NS_PREFIX}${pr} namespace remains"
    reaped=$((reaped+1))
    if [ "$DRY_RUN" != "true" ]; then
      kubectl -n "$STAGING_NS" delete database "$db" --ignore-not-found --timeout=180s \
        || echo "::warning::$db did not finish deleting; sessions may still be attached"
    fi
  done
fi

# ---- pass 3: orphan slot leases ---------------------------------------------
while IFS=$'\t' read -r lease pr ns; do
  [ -n "$lease" ] || continue
  reason=""
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    reason="namespace $ns is gone"
  else
    state=$(pr_state "$pr")
    [ "$state" = "open" ] || reason="PR #$pr is $state"
  fi
  [ -n "$reason" ] || continue
  echo "REAP   lease $lease — $reason"
  reaped=$((reaped+1))
  if [ "$DRY_RUN" != "true" ]; then
    kubectl delete lease -n "$SLOTS_NS" "$lease" --ignore-not-found
  fi
done < <(kubectl get lease -n "$SLOTS_NS" -l "review.ledoent.dev/app=$APP" -o json 2>/dev/null \
  | jq -r '.items[] | [.metadata.name,
                       (.metadata.labels["review.ledoent.dev/pr"] // ""),
                       (.metadata.annotations["review.ledoent.dev/namespace"] // "")] | @tsv')

# ---- pass 4: PV report ------------------------------------------------------
orphans=$(kubectl get pv \
  -o jsonpath='{range .items[*]}{.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null \
  | grep -E "^${NS_PREFIX}[0-9]+$" | sort -u || true)
if [ -n "$orphans" ]; then
  echo "::warning::PersistentVolumes still bound to review namespaces:"
  printf '%s\n' "$orphans"
fi

# "object(s)", not "namespace(s)": passes 2-3 reap objects with no namespace.
echo "swept $reaped object(s); dry_run=$DRY_RUN"
