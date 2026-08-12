# review-app-ci

GitLab-Auto-DevOps-style **review environments** for ledoent/measinst apps on
GitHub Actions + kustomize: per-PR namespaces, claimed hostname slots, per-PR
databases, e2e + Lighthouse against the live URL, teardown on close, nightly
orphan sweep, staging → production promotion.

One repo, two layers, one version stream:

1. **Reusable workflows** (`.github/workflows/*.yml`, called with `@v1`) +
   composite actions (`actions/`) + shared scripts (`scripts/`) — the logic,
   in exactly one place.
2. **Copier template** (`copier.yml` + `template/`) — stamps ~30-line caller
   workflows, a kustomize review overlay, and docs into each app repo.

## Adopt in a repo

```sh
copier copy --trust gh:ledoent/review-app-ci .
# answer the questions; then set the secrets listed in docs/review-envs.md
```

Existing `deploy/base`, staging/production overlays and `seed.sql` are never
overwritten (`_skip_if_exists`). Later:

```sh
copier update   # 3-way merges template changes; your edits survive
```

## Design commitments

- **Namespaces key off the PR number** (`<app>-pr<N>`), never the branch —
  `closed` often arrives after the branch is deleted.
- **Hostnames come from a claimed slot pool** (`<app>-review<1..N>.<domain>`,
  atomic Lease create-as-lock in the `review-slots` namespace, lowest free
  wins, released on teardown, reconciled by the sweep). Slots exist because
  OAuth redirect URIs must be pre-registered exactly; claiming — not deriving
  from the PR number — is what makes out-of-order PR closes a non-issue.
- **Overlays build as committed**: parameterization is `params.env` +
  kustomize `replacements` + `kustomize edit` — no sed, no sentinels.
- **Teardown ordering is law**: namespace → pod drain → Database CR →
  ingress-gone → lease. Encoded once in `scripts/reap-review-env.sh` +
  `release-slot.sh`, shared by teardown and sweep.
- **Migrations hard-fail.** No `|| echo "skipped"`.
- **Mail is sunk** (Mailpit) structurally; SMTP secrets are never copied into
  review namespaces.
- **Auth-bypass ⇒ basic auth** on the review ingress, enforced by template CI.
- **TLS rides a shared wildcard secret** copied into each review namespace;
  review ingresses must never carry `cert-manager.io/cluster-issuer`.

## Versioning

- Consumers pin `@v1`; `.copier-answers.yml` pins the exact template version.
- Logic fixes: tag `v1.x.y` via the Release workflow (moves `v1`) — reaches
  every repo on its next run, no copier update.
- Stamped-surface changes (caller inputs, triggers, secret names): ship, then
  run `tools/update-repos.sh` across consumers (opens PRs; never direct-push).
- Never add a required input within a major.

## Cluster prerequisites (per cluster)

- `review-slots` namespace + Lease RBAC for each app's deploy identity.
- `shared-certs` namespace with the wildcard TLS secret (`wildcard-tls` on
  hz, `mi-wildcard-tls` on meas-apps).
- Mailpit at `mailpit.email.svc.cluster.local:1025`.
- Slot hostnames registered in any OAuth clients the app uses (see each
  repo's `deploy/overlays/review/SLOTS.md`).
