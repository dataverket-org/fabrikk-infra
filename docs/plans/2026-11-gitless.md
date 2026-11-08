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

## Not in this plan

- The mirror plan's intake and quarantine for images and charts; Zitadel's chart is mirrored by hand, pinned.
- The Talos mirror entries for images, which are the operator's through Omni.
- A second site's zot as an edge mirror of this one, and the overlay repository that would carry a site's values.

## Audit
