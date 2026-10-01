# Research: the simplest toolchain for rendered manifests

Written 2026-10-01. A proposal, not a decision. It follows `2026-10-rendered-manifests-over-oci.md` and changes two
things in it: the recipe for a chart is a `kustomization.yaml`, not a `HelmRelease`, and the rendered output is
committed to git, because the diff of it is to be the change control.

## The proposal in one paragraph

Kustomize is the only renderer. A component is a directory with a `kustomization.yaml`; manifests written by hand
are its `resources`, an upstream chart is a `helmCharts` entry in the same file, and an environment is an overlay
of patches. The output is written to `rendered/<env>/`, one file per object, and committed. A pull request that
changes `rendered/qa/` *is* the promotion to qa, and its diff is what is reviewed. After merge that directory is
pushed as an OCI artifact, signed, and applied by Flux. Secrets are not rendered; Flux decrypts them with SOPS
as the last step. There is no program of our own to write.

## The tools

Five Go binaries. Three are in the `Brewfile` already.

| Tool | Does | New here |
|---|---|---|
| `kubectl kustomize --enable-helm` | Renders everything: plain manifests, charts, overlays | no |
| `helm` | Called by kustomize to inflate a chart. Never used directly | yes |
| `flux` | `push artifact`, `tag artifact`, `diff artifact`, `mirror`, `schema validate` | no |
| `cosign` | Signs the artifact | yes |
| `sops` with `age` | Encrypts secrets; Flux decrypts in the cluster | no |

In the cluster: source-controller and kustomize-controller. No helm-controller. The glue is tasks in the
`Taskfile` (decision 008), a few lines each.

## The layout

```
base/<component>/kustomization.yaml    resources: hand-written files, and/or helmCharts: an upstream chart
environments/<env>/kustomization.yaml  resources: ../../base/<component>, and this environment's patches
rendered/<env>/                        one file per object; written by the render, never by hand
secrets/<cluster>/*.enc.yaml           never rendered, never merged
```

A chart and a hand-written manifest look the same from outside, which is the point:

```yaml
# base/external-dns/kustomization.yaml
namespace: external-dns
resources:
  - namespace.yaml              # written by hand
helmCharts:
  - name: external-dns
    repo: oci://registry.dataverket.org/charts   # our mirror, filled by flux mirror
    version: 1.21.1
    releaseName: external-dns
    namespace: external-dns
    includeCRDs: true
    skipTests: true
    kubeVersion: "1.34.0"
    valuesInline:
      policy: sync
```

## The four commands

```sh
# render: the whole environment, one file per object
kubectl kustomize --enable-helm environments/$ENV -o rendered/$ENV/

# check, on every pull request: the committed render is true, holds no Secret, and is valid
kubectl kustomize --enable-helm environments/$ENV -o "$tmp/" && diff -r "$tmp" rendered/$ENV
! grep -rl '^kind: Secret' rendered/$ENV
flux schema validate rendered/$ENV

# ship, after merge
flux push artifact oci://registry.dataverket.org/platform/config-$ENV:$rev --path rendered/$ENV --reproducible \
  --source "$repo" --revision "main@sha1:$rev"
cosign sign registry.dataverket.org/platform/config-$ENV@$digest
flux tag artifact oci://registry.dataverket.org/platform/config-$ENV:$rev --tag current
```

The cluster has two pairs of `OCIRepository` and `Kustomization`. One verifies the signature and applies
`config-<env>` with no decryption configured. The other applies `secrets/<cluster>` with SOPS, and the first
depends on it.

## Change control is the rendered diff

| Step | Pull request contains | What the reviewer reads |
|---|---|---|
| Change | `base/` or `environments/dev/`, and `rendered/dev/` | The intent, and its exact effect on dev |
| Promote to qa | `rendered/qa/` only | Every object that will change in qa, and nothing else |
| Promote to prod | `rendered/prod/` only | The same, for prod |

- The promotion is one command, `task render ENV=qa`, and a pull request. No source file changes in it, so the
  diff is pure effect. The merge is the approval and the record, signed like every commit here.
- An environment may be *behind*: `rendered/qa/` differs from what the source would render now. That difference
  is the list of what waits for promotion, and `task render:pending` can print it any day.
- `diff -r rendered/dev rendered/qa` shows what differs between two environments by intent. It should be short
  and it should rarely change.
- A chart upgrade, a new Kubernetes version in `kubeVersion`, and an upgrade of `helm` or `kustomize` itself are
  all changes to the render, so all three arrive as a reviewable diff.
- `flux diff artifact oci://…/config-qa:current --path rendered/qa` proves that what the registry serves is what
  git holds.

## What I tested

With `kubectl` 1.37.1 (kustomize 5.8.1) and `helm` 4.3.0, in a scratch directory:

- A chart and a hand-written Deployment in one tree, two environments with one patch each. `diff -r` between the
  two rendered directories showed exactly one line, the patched `replicas`.
- Two renders give the same bytes.
- A chart from an OCI registry works (`forgejo` 17.1.5).
- `skipHooks: true` works: Zitadel renders to 4 objects and no Job, against 13 objects and 3 Jobs without it.

## What it costs

- **A rule in `miljo` changes.** It says rendered output lives only in the signed artifact. Here it also lives in
  git, and the artifact is a copy of it.
- **Size.** Envoy's CRDs are 58 000 lines, once. After that the diffs are small, and one file per object keeps
  them readable.
- **Tool versions are part of the render.** They must be pinned where the check runs, or the check fails for no
  reason anyone can see.
- **Hooks are still hand work.** With `skipHooks` the chart's Jobs are gone and must be written as plain
  manifests in `base/`, which this layout allows. Whether Zitadel's setup Job can run beside the rollout and not
  before it is not tested.
- **Promotion renders from the current source.** If qa must get exactly what dev ran, the promotion renders at
  the commit dev shipped, which is recorded on the artifact.

## Not chosen

- **A program of our own.** The three refusals from the first report are now two lines of shell in the check.
- **Holos, Kapitan, Timoni, ytt.** Each adds a language. Kustomize is already what `miljo` and Flux speak.
- **`HelmRelease` as the recipe.** It needs something to read it outside the cluster. Kustomize reads its own file.
- **A diff posted as a comment.** A comment is not a record; a commit is.

## Not verified

- `flux schema validate` and `cosign`; neither is installed here.
- That kustomize takes a chart from zot by the same `oci://` form as from `code.forgejo.org`.
- Kustomize pins a chart by version, not by digest. The committed render shows any change, but does not prevent it.
