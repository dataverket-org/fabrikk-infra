# Plan: zot is the cluster's only source

Written 2026-11-08, pruned the same evening to what is left. Each remaining step is one branch, unsigned, ending in a
stop for the operator's signed merge. What was done is in git's history and in decision 028's audit; the one incident
of the day, Forgejo's namespace pruned during its handover, is step 0 of `artifacts/cert-manager/README.md`
"Handing over from helm-controller", the rule every handover since has followed.

## Status, 2026-11-08

**Goal 1 done, goal 2 done but for the root, goal 3 not started.** Pruned to what is left on the evening of
2026-11-08; the sections below are the whole of it.

## Where we are

| Source | Fetched from | Carries |
|---|---|---|
| 17 `OCIRepository`s | zot, `zot.zot.svc.cluster.local:5000/platform/*-config` | every component but Envoy, one config artifact each (decisions 013, 028), Zitadel's HelmRelease among them |
| 1 `GitRepository` | `git.dataverket.org`, a Forgejo this cluster runs | `clusters/production`: the root, the `infrastructure` and `apps` Kustomizations, and under them the pointers to the seventeen, plus Envoy's HelmRelease |
| 2 chart sources | zot, `mirror/…`, by the Service name | Envoy's and Zitadel's charts, the two releases whose hook Jobs keep them on helm-controller |
| images | upstream registries, until the Talos mirror entries of `docs/plans/2026-10-registry-mirror.md` | everything not under `dataverket/` |

Git stays the source of truth for people; the cluster reads only zot, except the root. Helm runs on the laptop or in CI,
not on the cluster, except for the two releases above. `bin/artifact <name> [--check|--push]` renders, checks, pushes,
signs and tags every artifact; every push today is an operator's, one YubiKey touch each.

## Left of goal 2: the root, then CI

### The root

`clusters/production` becomes `platform/cluster-production`: one artifact holding every pointer pair and Envoy's
release, with the dependency graph between them; `gotk-sync.yaml`'s `Kustomization flux-system` sources it from an
`OCIRepository`; no `GitRepository` remains. Design it before touching it; it is the step that changes how a rebuild
works. To settle first:

- **Flatten.** The `infrastructure` and `apps` Kustomizations exist to order and to decrypt. Every component's
  Kustomization names its own `dependsOn` and carries its own decryption block already, so the two layers have no job
  left; dissolve them, and the pointers move from `infrastructure/*/source.yaml` and `apps/*/source.yaml` into the
  root artifact.
- **The foundation and zot before zot exists.** Today `bootstrap/*-from-git.yaml` carry occm, Cinder CSI and zot from
  the `GitRepository` until zot serves them. Without one: a bootstrap-only `GitRepository` the script deletes at the
  end, keeping 021's "a rebuild starts from the GitHub mirror" literal; or the three directories applied from the
  checkout with the operator's key decrypting locally. The first is smaller and keeps the script's shape.
  `flux bootstrap gitea` goes either way; Flux comes from the committed `gotk-components.yaml`, as the GitHub path does.
- **The rebuild recipe.** `docs/storage.md` "Rebuild from git" and decision 021 say the one pre-rebuild commit points
  `gotk-sync.yaml` at the mirror; with an OCI root that commit disappears and the mirror becomes the checkout the
  pushes are made from. Both need rewriting, 021 an audit line.
- **Who pushes the root.** Every pointer or `dependsOn` change is a push of the root artifact; until CI, a YubiKey
  touch each. Doing CI first, so the root is automated from its first day, is the better order.

Done when: `kubectl get gitrepository -A` is empty, every component `Ready` from its artifact, health green.
Rollback: point `flux-system` back at the `GitRepository`; the directory is still there until the last commit.

### CI

A Forgejo Actions workflow beside `.forgejo/workflows/check.yaml`: on a push to `main`, the `artifacts/<name>/`
directories changed between the push's before and after commits, `bin/artifact <name> --push` for each, one job at a
time so two pushes cannot race on `current`, the root last once it exists. The org runner `dataverket-runner`
answers `ubuntu-latest` in the cluster with a dind sidecar. Three changes the tool needs:

- **The credential from the environment.** `read_credential` decrypts the ci credential with a YubiKey; in CI it reads
  a username and password from environment variables set from repository secrets, sops otherwise. A person puts the
  value into Forgejo's secret store by hand (operator rules 3 and 4); the agent prints the settings path and never
  sees it.
- **Hermetic renders.** The charts kustomize inflates sit under the gitignored `recipe/charts/`; on the runner they are
  absent and a render fetches from code.forgejo.org and GitHub's release CDN, the dependency this plan removes. The
  three vendored charts are 668 KB together: drop the gitignore line and commit them. The theme render still reaches
  codeberg for the locale file and the forge for the theme; acceptable.
- **A tools image.** kubectl, helm, flux, sops, jq, yq, git, python3, later cosign, built once into zot and pulled by
  digest. `check.yaml` downloads yq from GitHub by sha256 today, the build-time dependency 035 closed; the same image
  fixes that.

The runner lives in the cluster, so a broken cluster has no CI; `bin/artifact --push` from a laptop stays the
recovery path. Done when: a merge to `main` reaches the cluster within one interval without a touch.

## Goal 3: signed artifacts, verified

| Change | Where |
|---|---|
| The key: `vaults/operator/osl1/cosign.enc.json` as `vaults/operator/README.md` "Signing keys" describes; the public half committed as `clusters/production/cosign-osl1.yaml`, or in the root artifact | the operator makes it, one YubiKey touch per use |
| `bin/artifact --push` signs what it pushes, which `sign_digest` already does when the key exists; CI holds the private key as a repository secret, as it holds the push credential | `bin/artifact`, `.forgejo/workflows/` |
| Every `OCIRepository` gets the `verify` block that is commented out today | the pointers |

Order matters: push every artifact signed once, then switch verification on, so no source is ever told to verify an
unsigned tag. A private key in Forgejo's repository secrets means anyone who administers that repository signs for
the site; decide that, in writing, before the key goes there.

Done when: every `OCIRepository` is `Ready` with verification on, and a deliberately unsigned push of a test tag is
refused. Rollback: remove the `verify` block from the one source that fails; signatures do no harm unverified.

## How the work is done here, the parts that are not in any README

- The operator merges and pushes `main`, signed; the agent commits on a branch from a clean `main` and types the push
  and the merge into the operator's zmx session (`fabrikk-infra-cmd`) one line at a time, without pressing enter, on
  an empty prompt, from the repository root. The session shares the agent's working directory, so the branch the
  agent checks out is what the operator's shell pushes from.
- Handover order, every time: push the artifact from the branch; merge the pointer with the old path in place;
  reconcile; read `kustomize.toolkit.fluxcd.io/name` on every moved object; only then a second commit removes the old
  path. `prune: disabled` on anything whose loss is a database, for the duration.
- The agent's auto mode refuses cluster writes and pushes to `main`; reads with `kubectl --context
  dataverket-prod-admin` work; the readers context cannot read cluster-scoped objects.
- `swamp behavior run dataverket-prod-kustomizations reconcile --arg name=<k> --arg withSource=true` is the
  reconcile; it blocks until the Kustomization is ready and holds the behavior's lock meanwhile, so not in a loop.
- Flux's `HelmRepository`, `HelmChart` and `OCIRepository` have no swamp type yet; `kubectl get` them.
- Two `sops` reads at once garble the YubiKey's answer; read sequentially. `crane auth login` and `helm registry
  login` must get a throwaway `DOCKER_CONFIG`/`HELM_REGISTRY_CONFIG`, or macOS's credential helper eats the login.
- A chart index's digest can be stale: GitHub's release asset for local-static-provisioner 2.8.0 was replaced after
  the index was written. Check the tarball against the git tag, and record what was found in the recipe.

## Not in this plan

- The mirror plan's intake and quarantine for images and charts; Zitadel's chart is mirrored by hand, pinned.
- The Talos mirror entries for images, which are the operator's through Omni.
- A second site's zot as an edge mirror of this one, and the overlay repository that would carry a site's values.
