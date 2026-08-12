#!/usr/bin/env bash
# Propagate template changes to consumer repos — the oca-copier-update
# analogue. A repo opts in by having a .copier-answers.yml pointing at this
# template; repos without one are skipped.
#
# Happy path: `copier update` applies cleanly -> push a branch and open a PR
# (NEVER a direct push to main — ledo convention: a human merges).
# Conflict path: commit whatever rendered, including .rej files, and open a PR
# titled "needs manual intervention".
#
# Usage:
#   tools/update-repos.sh <owner/repo> [<owner/repo>...]
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: tools/update-repos.sh <owner/repo> [...]"; exit 1; }

BRANCH="chore/review-app-ci-update"

failed=()
for repo in "$@"; do
  echo "=== $repo ==="
  tmp=$(mktemp -d)
  # One repo's failure must not stop the fleet: the per-repo block runs in a
  # subshell whose non-zero exit is caught, recorded, and reported at the end.
  if ! (
    set -euo pipefail
    gh repo clone "$repo" "$tmp" -- --depth 50 -q
    if [ ! -f "$tmp/.copier-answers.yml" ]; then
      echo "skip: no .copier-answers.yml"
      exit 0
    fi
    cd "$tmp"
    git switch -c "$BRANCH"
    if copier update --trust --defaults --skip-answered; then
      title="chore(ci): update review-app-ci scaffolding"
      body="Automated \`copier update\` from ledoent/review-app-ci."
    else
      title="chore(ci): review-app-ci update needs manual intervention"
      body="\`copier update\` reported conflicts — look for \`.rej\` files."
    fi
    if git diff --quiet && [ -z "$(git status --porcelain)" ]; then
      echo "up to date"
      exit 0
    fi
    git add -A
    git commit -qm "$title"
    # force-with-lease: the branch is machine-owned; a leftover from a prior
    # rollout must not reject the push and abort this repo.
    git push -q --force-with-lease -u origin "$BRANCH"
    gh pr create --repo "$repo" --title "$title" --body "$body" \
      --head "$BRANCH" || echo "PR already open"
  ); then
    echo "::warning::$repo failed"
    failed+=("$repo")
  fi
  rm -rf "$tmp"
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "failed repos: ${failed[*]}"
  exit 1
fi
