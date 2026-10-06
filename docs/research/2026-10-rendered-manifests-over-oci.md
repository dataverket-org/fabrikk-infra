# Research: rendered manifests, shipped as OCI artifacts

Written 2026-10-01. A report, not a plan and not a decision. It describes the pattern in general, what a chart
processor in front of `miljo` would look like, how secrets are delivered, and what follows for this repository
and for Dataverket's plans. It judges by Dataverket's own rule: maintenance cost is the number of times you *must*
touch the code, and the simplest design is also the cheapest.

`2026-10-render-toolchain.md` proposes the tools. It replaces two things said here: the chart recipe becomes a
`kustomization.yaml`, not a `HelmRelease`, and the rendered output is committed to git.

## The short answer

Do it. The product side already works this way: the `delivery` skill in `fabrikk` and the README of `miljo` say
`release = render(L1 @ commit, L2 @ version)`, "never join in the cluster" and "no cluster reads this
repository". This repository, the L0 baseline, is the only layer that still joins in the cluster, and upstream
Helm charts are the only input the join cannot take yet. A small chart processor closes both gaps with one
mechanism. Secrets stay with Flux and SOPS, unchanged, in an artifact of their own.

## The pattern in general

One function, four stages, the same for every layer:

| Stage | What happens | Where |
|---|---|---|
| Pin | Every input is named by digest: chart, image, remote manifest, overlay version | The factory |
| Render | Helm and Kustomize run once. The output is plain objects | The factory |
| Check | Schema validation, policy, a diff against what runs now | The factory |
| Ship | `flux push artifact`, sign, move a channel tag to the digest | The registry |

The cluster does one thing: verify the signature and apply. It templates nothing, substitutes nothing, and reads
no host but its registry. Promotion and rollback are moving a tag between digests that already exist. Flux calls
the shipping half gitless GitOps, generally available since Flux 2.6; this cluster runs 2.9, which adds
`flux mirror` (copies images, charts and config artifacts between registries, with signature checks and a minimum
age) and `flux schema validate`. The rendering half was named by Akuity for Argo CD, and Akuity lists its costs
plainly: a pipeline to maintain, growth with apps times environments, and no fit with tools that decrypt secrets
while rendering.

## A chart processor: an upstream chart becomes a base

`miljo` expects a kustomize base per product, `<product>/deploy/base/`, and an overlay per environment that says
`resources: [../base]` and patches the fields the base declares tunable. Dataverket's own Go services produce
that base directly. An upstream chart does not, and most of what Dataverket runs is upstream: Identitet is
Zitadel, Sentral is NATS, and everything in `infrastructure/` here. A processor that turns a chart into a base
lets all of it go through the join that already exists, with `miljo` unchanged.

| Step | What the processor does |
|---|---|
| 1. Recipe | Reads one file per chart: chart reference and digest, namespace, values, Kubernetes version. A `HelmRelease` already holds all of this, so it can stay as the authoring format; nothing new to learn |
| 2. Fetch | Pulls the chart from Dataverket's registry, where `flux mirror` put it. No outside host at render time |
| 3. Render | `helm template`, with CRDs, for the stated Kubernetes version |
| 4. Split | CRDs into their own directory, applied first. Images listed, mirrored, and rewritten to digests |
| 5. Refuse | Stops if two renders differ, if a Secret with generated content appears, or if a hook is not on the recipe's allow list |
| 6. Emit | Writes `base/` with a `kustomization.yaml`, and the chart's digest into `release.json` |

After step 6 a chart is a product like any other. `environments/<env>/<product>/` patches it, the join renders
it, the artifact is signed, UAT runs against it.

Two rules keep the processor small, and they are the difference between a tool and a second Helm:

- **Values belong to the base, patches to the environment.** Helm values are set once, in the recipe, and say
  what the software *is*. What differs between environments is a kustomize patch in `miljo`, on a field the
  base declares tunable. No values file per environment, so the linter that guards L2 keeps working.
- **No chart-specific code.** The processor refuses; it does not repair. A chart that fails step 5 is fixed in
  its recipe, kept as a `HelmRelease` under a named exception, or written as plain manifests as decision 012
  did for zot.

For L0 this repository is both sides: the recipes are its L1, and `clusters/<name>/` would hold the overlay per
cluster. That replaces the `postBuild.substituteFrom` that decision 013 plans for a second cluster.

In this repository the processor would be a swamp workflow that the release runner runs.

## Prior art, and what it teaches

Others have built these four stages before. None was tried here; this is from their documentation.

| Tool | What it is | What it has that we do not |
|---|---|---|
| Kapitan | An inventory of *targets* (one per environment) built from shared *classes*, compiled to plain files by Helm, Kustomize, Jsonnet and others | Per-target rendering as the normal case; secret references in the output |
| Carvel | Small tools in a row: `vendir` fetches and locks, `ytt` renders, `kbld` turns images into digests, `imgpkg` ships a bundle | A lock file for every input; a bundle that knows its own images |
| kpt | Rendered YAML is the source, changed in place by functions that mutate or validate | An argument against parameters |
| Holos | The rendered manifests pattern in CUE: generators, transformers, validators | A validator that stops Helm from rendering a Secret |
| Timoni | A Helm replacement in CUE, modules shipped as OCI, by a Flux maintainer | Nothing for upstream charts, which stay Helm charts |

Six lessons:

1. **One render per cluster is ordinary.** It is how Kapitan always works: a target is a small file of facts, and
   compiling fifty targets is the tool's normal run. So the Plattform question is not whether to render per
   cluster but who runs the render and signs it.
2. **The cost is in the language for those facts.** Kapitan's own documentation says its inventory "might be
   overwhelming", and kpt was written against "excessive parameterization". Classes that inherit from classes are
   where these systems get hard to read. Dataverket has already chosen the plain form: a kustomize overlay on
   fields a schema declares tunable. Keep per-cluster facts flat, with no inheritance.
3. **Generate a secret once, not on every render.** Kapitan can create a key or password the first time a
   reference is compiled, store it encrypted, and reuse it after. That is the right answer to charts like
   Zitadel's that make keys while rendering: the value is made once and lives in the SOPS store.
4. **A rendered secret reference should change when the secret does.** Kapitan's compiled output holds
   `?{gpg:path:ec3d54de}`, a name and a short hash, never the value. With secrets in their own artifact, a
   rotated secret changes nothing in the baseline, so nothing restarts. A hash of the encrypted file as an
   annotation on the workload gives the same effect. Kapitan needs a webhook in the cluster (Tesoro) to resolve
   its references; Flux with SOPS already fills that role.
5. **An artifact should list its images, and moving it should not rewrite it.** `imgpkg copy` moves a bundle
   and every image it names in one step, then rewrites the references. `release.json` already lists image
   digests, so `flux mirror` can do the first half. For the second, a registry mirror in the Talos machine config
   lets an operator serve the same names from its own registry, so the artifact and its signature stay as signed.
6. **Where the rendered output lives decides how it is reviewed.** Kapitan, Holos and Akuity commit it to git,
   because the diff in a pull request is the main benefit. `miljo` says rendered output exists only in the
   artifact. That is fine, but then the check stage must post `flux diff artifact` to the pull request, or the
   benefit is lost.

Two smaller points. `helm template` does not set `metadata.namespace` on what it renders, as Kapitan's
documentation warns, so step 3 must. And none of these tools has an answer for Helm hooks.

Adopting Kapitan itself is not the lesson. It brings a Python tool, an inventory language, and secret backends
(GPG, cloud KMS, Vault) that do not include age. Its ideas fit in a processor of a few hundred lines.

## What the charts here do when rendered

I rendered all six charts with the values in this repository, twice each:

| Chart | Lines | Objects | Helm hooks | Same output twice |
|---|---|---|---|---|
| external-dns 1.21.1 | 313 | 6 | 0 | yes |
| local-static-provisioner 2.8.0 | 161 | 5 | 0 | yes |
| forgejo 17.1.5 | 841 | 10 | 1 | yes |
| cert-manager v1.20.3 | 1 526 | 47 | 4 (the start-up check Job) | yes |
| envoy gateway-helm v1.8.2 | 58 414 | 39 | 7 (the certificate Job, before install and upgrade) | yes |
| zitadel 10.0.4 | 834 | 14 | 9 (init and setup Jobs, before install and upgrade) | no, until fixed |

The Zitadel chart makes a key pair while it renders, so the output differs each time and would carry a private
key in clear text. Naming an existing Secret in the values (`login.loginServiceKeySecretName`) removes it: the
render is then the same twice and holds no Secret. This is step 5 doing its job, and the fix is one line in the
recipe.

Hooks are the harder case. Only helm-controller runs them; rendered, a hook Job is an ordinary Job that cannot be
changed once it exists. Envoy and Zitadel depend on theirs.

## Secrets

Yes: Flux and SOPS deliver them exactly as today. Nothing in the pattern changes who decrypts or with which key.
zot already proves it. `artifacts/zot/` holds two `*.enc.yaml` files, they travel inside the OCI artifact as
ciphertext, and the Flux `Kustomization` decrypts them on apply with the cluster's own key (decision 003).

What changes is where the encrypted files sit, and three rules follow:

1. **Rendered manifests name secrets, never hold them.** This repository already works so: charts take
   `existingSecret` and `secretKeyRef`. The processor's refusal in step 5 enforces it.
2. **Encrypted files do not pass through the renderer.** They are copied as they are, one Secret per file. SOPS
   signs each file, and a renderer that merges or reorders files can break that. The renderer needs no key and
   never sees a clear value, so the factory still holds no credential for the cluster.
3. **Secrets get their own artifact, one per cluster.** Every cluster has its own age key, so encrypted files
   are per cluster by nature, while a rendered baseline should serve many. Two artifacts, two `Kustomization`
   objects:

| Artifact | Contents | Decryption | Who can use it |
|---|---|---|---|
| `platform/baseline` | Rendered objects, no Secret | None configured | Any cluster; safe to mirror, as the `delivery` checklist asks |
| `clusters/<name>/secrets` | Only `*.enc.yaml`, encrypted to that cluster and the operators | SOPS, the cluster's key | That cluster alone |

The baseline `Kustomization` depends on the secrets one. The registry allows anonymous pull, so the ciphertext
is public, which is the same exposure as the mirror of this repository today. The operator rules are untouched:
recipients are still set in `.sops.yaml` by a person.

For products, `miljo` says "secrets, in any encoding: never in git", so their secrets are an L0 matter: the
cluster's secrets artifact creates the Secret, and the product's rendered manifests name it.

One clear-text value exists today: the first-login password in `apps/zitadel/release.yaml`. Rendered, it would
sit in a public artifact.

## Outcomes for this repository

**Goes away:** the cluster's dependency on the forge that it deploys itself, and the forge token; seven outside
hosts in the reconcile path (`charts.zitadel.com`, `charts.jetstack.io`, `code.forgejo.org`, `docker.io`,
`kubernetes-sigs.github.io`, `github.com`, `raw.githubusercontent.com`); helm-controller, once the last chart is
rendered; guessing in review, because `flux diff artifact` shows the objects that change.

**Is added:** the processor and its recipes; `helm` and `cosign` in the `Brewfile`; a signing key and the
decision who holds it. With verification on, whoever signs decides what the cluster runs. A key on the operators'
YubiKeys keeps every baseline change a deliberate act; a process key makes it unattended and puts cluster admin in
a file. That is a decision for a person.

**Needs care:** the registry lives in the cluster it feeds. Decision 011 solves that for zot alone; for the whole
baseline the loop is wider, since zot needs the Cinder CSI driver that would come from zot. A running cluster is
not affected. A new or broken one is, and there rendered output helps: it is plain YAML, so the way back is to
render locally and `kubectl apply --server-side`. The better answer is a second registry outside the cluster, at
the hov1 site, filled by `flux mirror`.

## Judged for simplicity

| | Parts in the cluster | Parts in the repository | When you must touch it |
|---|---|---|---|
| Today | Four Flux controllers, a forge token, seven outside hosts | Authored YAML | When an outside host changes or breaks; on every chart upgrade, without seeing its effect |
| Rendered and shipped | Two controllers, one registry, one public key | Recipes, the processor, the signing key | On every chart upgrade, with the effect in the diff; on every Kubernetes minor |

The pattern moves complexity from the running cluster to the factory, where a person can read, test and review
it. The total is not smaller on day one. It gets smaller with each cluster and each upstream chart after the
first, because each adds a recipe or an overlay and nothing else. The processor is the risk: it stays simple only
while it refuses and does not repair.

## Outcomes for Dataverket's plans

What the pattern means for the Talos control plane without Omni, for Sentral and Identitet, for Maskin and for
Plattform is a question about the products, not about this cluster, and lives in the `org` repository as
`docs/forskning/2026-10-rendered-artifacts-for-the-products.md`. One item from it returns here as step 6 below:
per-cluster rendering has to be settled before Plattform designs on top of it.

## A possible order

1. Decide who signs the baseline.
2. Move the encrypted files into a secrets artifact for this cluster. Small, and it proves the split.
3. Build the processor on the four charts that render cleanly, and ship them with the plain manifests.
4. Settle the hooks of envoy and zitadel, by exception or by work, and record it as a decision.
5. Prove the inline-manifest bootstrap on the lab cluster, and a registry at the hov1 site.
6. Settle per-cluster rendering before Plattform designs on top of it.

## Not verified

- Whether an encrypted Secret survives `kustomize build`; rule 2 avoids the question.
- That `cosign` from Homebrew signs with a YubiKey without a custom build.
- How Talos handles a changed inline manifest on an existing cluster.
- Whether the hook Jobs of envoy and zitadel behave as plain Jobs; I counted them, I did not apply them.
- The renders used Helm's default Kubernetes version, not this cluster's.

## Sources

- `fabrikk/.agents/skills/delivery/SKILL.md`, `miljo/README.md`, decisions 003, 010 to 013, and
  `docs/plans/2026-10-talosctl-over-omni.md`
- `org/docs/arrangement/2026-09-24-blug/foredrag.md`, for the cost principle and the product layers
- Akuity, The Rendered Manifests Pattern: <https://akuity.io/blog/the-rendered-manifests-pattern>
- Kapitan: <https://kapitan.dev/latest/>, its references <https://kapitan.dev/latest/references/> and Tesoro
  <https://github.com/kapicorp/tesoro>
- Carvel imgpkg: <https://carvel.dev/imgpkg/>; kpt rationale: <https://kpt.dev/guides/rationale/>; Holos:
  <https://github.com/holos-run/holos>; Timoni: <https://github.com/stefanprodan/timoni>
- Flux Kustomization, decryption: <https://fluxcd.io/flux/components/kustomize/kustomizations/>
- Flux 2.9: <https://fluxcd.io/blog/2026/06/flux-v2.9.0/>
- Flux Mirror: <https://fluxcd.io/blog/2026/08/flux-mirror/>
- Gitless GitOps, Flux Operator: <https://fluxoperator.dev/gitless-gitops/>
- Flux D2 reference architecture: <https://control-plane.io/posts/d2-reference-architecture-guide/>
