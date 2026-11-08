# Plan: zot is the cluster's only source

Written 2026-11-08. Three goals, in order. Each is one branch, unsigned, ending in a stop for the operator's signed
merge. Audit lines go under the heading at the end.

## Where we are

At reconcile time the cluster fetches from four kinds of place:

| Source | Fetched from | Carries |
|---|---|---|
| 7 `OCIRepository`s | zot, `zot.zot.svc.cluster.local:5000/platform/*-config` | zot, versitygw, www, offentlig-data, Zulip, Forgejo's theme, cert-manager: one config artifact per app (decisions 013, 028) |
| 1 `GitRepository` | `git.dataverket.org`, a Forgejo this cluster runs | `clusters/production`, `infrastructure/`, `apps/`: eleven components still applied from git |
| 5 chart sources | upstream: `charts.zitadel.com`, `code.forgejo.org` (the Forgejo chart as OCI, the runner chart as git), `docker.io/envoyproxy`, `kubernetes-sigs.github.io` | every HelmRelease's chart, re-fetched on its interval and on a version bump |
| images | upstream registries, until the Talos mirror entries of `docs/plans/2026-10-registry-mirror.md` | everything not under `dataverket/` |

Seven components are already gitless. Eleven depend on a Forgejo the cluster hosts, five of them also on an upstream
chart server. 2026-11-08 showed the cost of a build-time dependency: a GitHub outage blocked every change for an
hour. Decision 035 closed that one; this plan closes the rest the same way the seven were done.

## Where we go

Every component is one config artifact in zot, `platform/<name>-config`, the pattern cert-manager set: rendered in
the factory where it is a chart, pushed from a clean checkout, signed with the site's key, applied by Flux from
zot's Service name, which is the same in every cluster built from this repository. Git stays the source of truth for
people; the cluster reads only zot. Helm runs on the laptop or in CI, not on the cluster, with one exception named
below. The only traffic that leaves the site at reconcile time is zot's own pull-through for a digest it has not
seen.

What this does not change: 035 still applies, a file applied with a component is kept in the repository and pinned;
013 still applies, zot is bootstrapped from git before anything can come from zot; 021 still applies, GitHub's mirror
of the repository is where a rebuild starts.

## The one exception: Zitadel stays Helm

Zitadel's chart runs its database `init` and `setup` as Helm hooks: Jobs that run again on every upgrade, in order,
before the Deployments roll. Rendered to plain manifests they would run once and never again. So Zitadel keeps its
HelmRelease, and its chart is the one chart mirrored into zot. Forgejo's chart has no hooks and renders; confirm
that when doing it, since a chart gains hooks between versions.

## Goal 1: Zitadel's chart from zot

| Change | Where |
|---|---|
| `helm pull` the pinned version from `charts.zitadel.com`, `helm push` it to `oci://registry.dataverket.org/mirror/charts.zitadel.com`, with the `fabrikk-ci` credential | by hand, from a laptop; the mirror plan's intake takes bumps over later |
| `HelmRepository zitadel-repo` becomes `type: oci`, `url: oci://zot.zot.svc.cluster.local:5000/mirror/charts.zitadel.com`; the HelmRelease keeps `version: "10.0.4"` | `apps/zitadel/repo.yaml` |

Done when: `dataverket-prod-helm list` shows Zitadel `Ready` on chart 10.0.4 from the new source, and health is green.
Rollback: revert the source; the upstream URL still works.

## Goal 2: every component its own artifact

The eleven components leave `infrastructure/` and `apps/` for `artifacts/<name>/`, each pushed as
`platform/<name>-config` and applied by an `OCIRepository` + `Kustomization` pair the way the seven are.

| Component | Today | In the artifact |
|---|---|---|
| OCCM, Cinder CSI, kata-containers, readers | plain manifests | as they are; OCCM's encrypted cloud config travels beside them, decrypted by the cluster key as every artifact's secrets are |
| CNPG operator, Barman plugin | the vendored manifests of 035 | one artifact `cnpg-config` holding both files; `bin/vendor` keeps pinning them where they now live |
| Envoy Gateway | HelmRelease, `gateway-helm` v1.8.2 | rendered (028): `recipe/` with the chart and values, `rendered/` committed, as cert-manager; the Gateway and listeners beside it |
| local-static-provisioner | HelmRelease | rendered |
| Forgejo, Forgejo runners | HelmRelease, chart as OCI and as git | rendered; the two Postgres `Cluster`s and the runner registration beside them |
| Zitadel | HelmRelease | artifact holding the HelmRelease, its `HelmRepository` pointing at zot (goal 1), the routes and the system-user public key; the HelmRelease itself stays |

Tooling, so eleven artifacts are not eleven scripts:

| Change | Where |
|---|---|
| `bin/artifact <name> [--check\|--push]`: renders when there is a `recipe/`, proves `rendered/` true to it, pushes `artifacts/<name>/` from a clean checkout with the revision annotation, signs when the site key is present. Replaces every per-directory `push.sh` and `render.sh`; `postgres-image.sh` and `site.sh` stay, they build images | `bin/artifact`, `share/artifact.sh` |
| CI: a Forgejo Actions workflow on every push to `main` runs `bin/artifact --push` for each `artifacts/<name>/` the push changed, with the `fabrikk-ci` credential from the repository's secrets, on the in-cluster runner; `check.yaml` already shows the shape | `.forgejo/workflows/` |
| The root: `clusters/production` keeps only the pointers, one `OCIRepository` + `Kustomization` per artifact and their `dependsOn`; it is the last thing Flux reads from git, and becomes `platform/cluster-production` itself at the end of this goal | `clusters/production/` |
| Bootstrap: `bootstrap/zot-from-git.yaml` applies zot from git; then the artifacts are pushed from a laptop in dependency order; then Flux is pointed at the root artifact. README's "Bootstrap and recovery" says so | `bootstrap/`, README |

Order inside the goal: the tooling first; then one component at a time, each a merge, a push and a Flux round, the
plain ones before the rendered ones; the root last. The in-cluster runner is enough for the normal case and useless
when the cluster is broken; `bin/artifact --push` from a laptop is the recovery path, as for every artifact today.

Done when: no `GitRepository` is left in the cluster, every component is `Ready` from its artifact, a merge to `main`
reaches the cluster within one interval through CI, and health is green. Rollback, per component: point its
Kustomization back at the git path; the directory is still there until the goal's last commit removes it.

## Goal 3: signed artifacts, verified

| Change | Where |
|---|---|
| The key: `vaults/operator/osl1/cosign.enc.json` as `vaults/operator/README.md` "Signing keys" describes; the public half committed as `clusters/production/cosign-osl1.yaml` | the operator makes it, one YubiKey touch per use |
| `bin/artifact --push` signs what it pushes; CI holds the private key as a repository secret, as it holds the push credential | `bin/artifact`, `.forgejo/workflows/` |
| Every `OCIRepository` gets the `verify` block that is commented out today | the pointers in `clusters/production/` |

Order matters: push every artifact signed once, then switch verification on, so no source is ever told to verify an
unsigned tag.

Done when: every `OCIRepository` is `Ready` with verification on, and a deliberately unsigned push of a test tag is
refused. Rollback: remove the `verify` block from the one source that fails; signatures do no harm unverified.

## Handover: where to pick this up

Written 2026-11-08 after the day's work, for whoever continues, person or agent. Read the audit below first, then
`artifacts/cert-manager/README.md` "Handing over from helm-controller", whose step 0 was learned the hard way today.

### State

| Component | Comes from | Note |
|---|---|---|
| zot, versitygw, www, offentlig-data, zulip, forgejo-theme, cert-manager | zot, as before | pushed with `bin/artifact <name> --push` now |
| readers, kata-containers, cnpg, occm, cinder-csi-provider | zot | moved today; `infrastructure/<name>/source.yaml` is the pointer; `bootstrap/foundation-from-git.yaml` carries occm and cinder-csi-provider at bootstrap |
| forgejo, forgejo-runners | zot | moved today, through an incident; rendered from charts vendored under `recipe/charts/`; no HelmRelease left |
| envoy, zitadel | git: a HelmRelease each, their charts from zot (`mirror/…`) | the plan's two exceptions, done |
| local-static-provisioner | git: a HelmRelease, every object marked `keep` | **step B on branch `gitless-2d`** (`684a1e3`, 2026-11-08 evening): rendered, `kubectl diff` empty against the cluster, pointer written with `release.yaml`, `repo.yaml` and `storageclass.yaml` still in place. Waits for the operator's push and merge |
| the root, `clusters/production` | git | untouched |

`bin/artifact --check` passes for every artifact on `gitless-2d`; on `main` forgejo-theme's fails, since its
renderer read the chart from `apps/forgejo/repo.yaml`, gone with `cc89f43`, fixed on the branch (`4e1effd`).
`swamp workflow run health` was green after the recovery. The `apps` Kustomization is resumed. Nothing is
suspended, nothing carries a migration annotation.

### What is left of goal 2, in order

1. **local-static-provisioner.** On `gitless-2d`, the handover in the recipe's order: `bin/artifact
   local-static-provisioner --push` from the branch; merge; `reconcile` `infrastructure` with source, then see the
   five objects and the StorageClass adopt (`kustomize.toolkit.fluxcd.io/name=local-static-provisioner` on them);
   then a second commit removes `release.yaml`, `repo.yaml` and `storageclass.yaml` from
   `infrastructure/local-static-provisioner/`, leaving `source.yaml`, and infrastructure's prune touches nothing
   relabelled. Three PVs are bound through `pg-zitadel-storage` (`zitadel-db-1..3`); a bound PV does not need its
   StorageClass object, and the adoption keeps it anyway. The chart: the index's digest for 2.8.0 is stale, the
   release asset was replaced on 2026-03-06; the tarball GitHub serves is byte-identical to the git tag's
   templates and values (the recipe comment). It is unpacked under the gitignored `recipe/charts/`, as Forgejo's is.
2. **Zitadel's pointer artifact.** `artifacts/zitadel/` holding what `apps/zitadel/` holds today, HelmRelease
   included; pointer in `apps/zitadel/source.yaml`. The HelmRelease object itself is just another manifest in the
   artifact; nothing is uninstalled. The database `Cluster` is in there: push first, `prune: disabled` on
   everything moved, as for CNPG today.
3. **The root.** `clusters/production` becomes `platform/cluster-production`; `gotk-sync.yaml`'s `Kustomization
   flux-system` sources it from an `OCIRepository`; `bootstrap.sh` becomes a from-checkout sequence (foundation,
   zot, the artifacts in dependency order, then Flux pointed at the root artifact) with no `GitRepository`. Design
   it before touching it; it is the step that changes how a rebuild works.
4. **CI.** A Forgejo Actions workflow beside `.forgejo/workflows/check.yaml` running `bin/artifact <name> --push`
   for each `artifacts/<name>/` a push to `main` changed, with the `fabrikk-ci` credential as a repository secret.
   Until then every push is an operator's, one YubiKey touch each.

Then goal 3 as written.

### How the work is done here, the parts that are not in any README

- The operator merges and pushes `main`, signed; the agent commits unsigned on a branch and types the merge
  into the operator's zmx session (`fabrikk-infra-cmd` today) without pressing enter. Check the prompt is empty
  before typing a second line, and that the shell is at the repository root: today a line typed onto a half-typed
  one ran the wrong command, and `bin/artifact` was not found from `apps/`.
- The agent's auto mode refuses cluster writes and pushes to `main`; those are typed for the operator too.
  Reads with `kubectl --context dataverket-prod-admin` work; the readers context cannot read cluster-scoped objects.
- `swamp behavior run dataverket-prod-kustomizations reconcile --arg name=<k> --arg withSource=true` is the
  reconcile; it blocks until the Kustomization is ready and holds the behavior's lock meanwhile, so do not loop it
  over many names in one command. A Kustomization waiting on `infrastructure` waits on every remote fetch
  `infrastructure` still has: none since 035, except the two HelmReleases' charts, which come from zot.
- Flux's `HelmRepository`, `HelmChart` and `OCIRepository` have no swamp type yet; `kubectl get` them.
- A push through `bin/artifact` needs a clean checkout; the revision annotation names the commit the directory is
  at. Pushing from a branch before the merge is the right order for a handover.
- Two `sops` reads at once garble the YubiKey's answer; read sequentially. `crane auth login` and `helm registry
  login` must get a throwaway `DOCKER_CONFIG`/`HELM_REGISTRY_CONFIG`, or macOS's credential helper eats the login.

## Not in this plan

- The mirror plan's intake and quarantine for images and charts; Zitadel's chart is mirrored by hand, pinned.
- The Talos mirror entries for images, which are the operator's through Omni.
- A second site's zot as an edge mirror of this one, and the overlay repository that would carry a site's values.

## Audit

### 2026-11-08, goal 1

**Status:** Done. `9a0c59f`.

| Finding | Where | Assessment |
|---|---|---|
| The chart | `helm pull` from `charts.zitadel.com` failed: the index points at a GitHub release asset, and those answered 504 all morning; fetched through GitHub's API asset endpoint instead, digest `334aa455…` equal to the index's | the chart source was the same GitHub dependency as the manifests of 035 |
| Into zot | `helm push` by you with the ci credential: `mirror/charts.zitadel.com/zitadel:10.0.4`, digest `8b2c9bab…` | zot's `**` policy already lets `fabrikk-ci` create there |
| The source | `HelmRepository zitadel-repo` `type: oci`, `oci://zot.zot.svc.cluster.local:5000/mirror/charts.zitadel.com`, `insecure: true` | the `HelmChart` reports "pulled 'zitadel' chart with version '10.0.4'" from it; the chart being byte-identical, helm-controller made no upgrade and Zitadel did not roll, release v5 of 11-06 stands |
| Health | green | done |

Not a swamp type: Flux's `HelmRepository`, `HelmChart` and `OCIRepository` state, read with `kubectl` this once; noted
for the extension.

### 2026-11-08, goal 2, with an incident

**Status:** Eleven of the eighteen components are artifacts; Forgejo's handover took the forge down for an hour.

| Finding | Where | Assessment |
|---|---|---|
| Tooling | `bin/artifact` and `share/artifact.sh` (`009a075`): render, check, push, sign, tag; the per-directory scripts retired; `prepush.sh`, `.sourceignore`, `recipe/plain-secrets` and a values file as conventions | proven first on forgejo-theme, then on every artifact since |
| The five plain components | readers, kata-containers, cnpg, occm, cinder-csi-provider, in three commits: `prune: disabled` on the live objects, the move with the pointers and the pushes, the annotations off (`e87f0fe`, `a307c77`, `975b152`, `f3c2ea5`) | adopted without a deletion; the CNPG CRDs changed owner with every database healthy. B for the foundation: `bootstrap/foundation-from-git.yaml` and the steps in `bootstrap.sh` |
| Envoy and Zitadel | charts in zot, `HelmRepository` by the Service name (`9a0c59f`, `bb2259d`); both stay HelmReleases for their hook Jobs | the two exceptions of the plan |
| Forgejo and the runner, step A | every object of both releases `keep` (`1963e23`, then the runner's patch in its existing post-renderer) | read back on every kind |
| **Forgejo, step B: the incident** | `6c2a5ad` moved `namespace.yaml`, `postgres.yaml`, the backup objects and the Secrets out of `apps/forgejo` and added the pointer in one commit; the artifact pushes typed after the merge did not run (the shell was in `apps/`); `apps` prunes | Flux garbage-collected the `forgejo` and `forgejo-runners` Namespaces and the `forgejo-postgres` Cluster, 12:57 to 13:00 CET. The guard used for the five infrastructure components, `prune: disabled` first, was not applied here. The agent's error |
| What was saved | the repositories' PV `pvc-b7554609…` patched to `Retain` by you while the Namespace terminated, its claim released after | the Cinder volume `cf90978b…` survived; the Postgres volume did not |
| Recovery | from the artifact, since git was the forge itself: `forgejo-postgres` with `bootstrap.recovery` from `hov1/forgejo-postgres-2`, archiving to `-3`; the PVC bound to the retained PV by `volumeName`; the HelmReleases and chart sources out of git; `apps` suspended until that commit was on `main` (`cc89f43`) | CNPG restored the database in about a minute; the forge answered 200 at 13:08 CET with all sixteen repositories and `main` at the last push; the runner re-registered. A base backup taken after |
| Written down | the handover recipe in `artifacts/cert-manager/README.md` gains step 0: push first, adopt, then remove; or `prune: disabled` on everything that moves | the rule the morning's first five followed and the sixth did not |

Left of goal 2: local-static-provisioner (recipe written, chart pull waits for GitHub; its `keep` is live), Zitadel's
pointer artifact, the root. Left of this incident: nothing on the cluster; the restored database's
`ScheduledBackup` runs on its schedule.
