# The cert-manager artifact

cert-manager, external-dns, the nordhost DNS webhook they share a credential with, and the `letsencrypt-prod`
ClusterIssuer, delivered the way zot and versitygw are, and the first artifact whose contents are rendered from
upstream charts rather than written by hand (decision 028). Git holds the pointer,
`infrastructure/cert-manager/source.yaml`; this directory is the artifact's source. `recipe/` says what to render,
`rendered/` is the result, committed, and `push.sh` ships `rendered/` and the one encrypted Secret into zot as
`platform/cert-manager-config`. Flux applies whatever the `current` tag holds, decrypting the Secret with the
cluster key. Placement is decision 027: everything on the control planes, the webhook three replicas.

## Contents

| Path | What |
|---|---|
| `recipe/kustomization.yaml` | The two charts, cert-manager v1.20.3 and external-dns 1.21.1, with their values, and the plain manifests listed below; the CRDs carry a `prune: disabled` annotation so no Kustomization ever deletes them |
| `recipe/namespace.yaml`, `recipe/clusterissuer.yaml`, `recipe/nordhost-webhook/` | Written by hand; the webhook's Deployment, RBAC, Service, APIService and its own PKI |
| `rendered/` | One file per object, named by kind and name, plus a `kustomization.yaml` listing them. Written by `render.sh`, never by hand |
| `nordhost-config.enc.yaml` | The DirectAdmin credential, sops-encrypted to the cluster key and the two operators. Never rendered: it travels next to `rendered/` and Flux decrypts it |
| `kustomization.yaml` | What Flux applies: `rendered/` and the Secret |
| `render.sh` | Renders the recipe; `--check` proves `rendered/` is true to it. Needs `kubectl` and `helm` on PATH; helm only inflates charts |
| `push.sh` | Runs the check, then pushes into zot; not part of the artifact |

## Change something

```sh
# edit recipe/, then
./render.sh                 # rewrites rendered/
git diff --stat rendered/   # the review: what changes in the cluster, object by object
git commit -a
./push.sh                   # from the committed state; refuses a dirty tree and a stale render
```

A chart upgrade is a version bump in the recipe and a render. The diff of `rendered/` shows every object the new
chart changes, which a HelmRelease never showed. The cluster reads no chart repository: `charts.jetstack.io` and
the external-dns repository are reached by the operator's machine at render time only. A chart mirror in zot,
filled by `flux mirror`, is the next step and is not done.

## What the render refuses

A `Secret`, because a value in `rendered/` is a value in git in clear; secrets travel encrypted beside it. A `Job`,
because a chart hook rendered is an ordinary Job that cannot be re-run once applied; cert-manager's start-up check
is off for that reason, and the certificate check it did is what `kubectl get certificate` shows.

## Handing over from helm-controller

Both charts ran as HelmReleases in `infrastructure/`. The objects are the same; what changes is which controller
owns them. Done in this order, each step reconciled and read before the next, nothing is deleted on the way.

1. **Prepare the releases.** The two HelmReleases carry `uninstall.deletionPropagation: orphan` (this branch), so
   when they are removed helm-controller runs an uninstall that leaves every object in place. Confirm Flux has
   applied that before anything else: `swamp model method run dataverket-prod-kustomizations list`, then the
   HelmRelease specs through the readers context.
2. **Ship the artifact next to the releases.** Push with `push.sh`; `infrastructure/cert-manager/source.yaml`
   (this branch) makes Flux apply it. Both paths now apply the same objects; helm-controller's drift detection is
   off, so it does not fight. Server-side apply moves the objects' Flux labels to the `cert-manager` Kustomization.
   Read the pods: the webhook at three replicas on the control planes, the rest on control planes, the ClusterIssuer
   `Ready`. On a fresh cluster this step is `bootstrap/cert-manager-from-git.yaml` instead, until zot serves.
3. **Remove the Helm path.** One commit: drop `cert-manager`, `nordhost-webhook`, `clusterissuer` and
   `external-dns` from `infrastructure/kustomization.yaml` except for a `cert-manager/` holding only `source.yaml`;
   delete the two `release.yaml` and `repo.yaml`, the CRD URL, `namespace.yaml`, and the moved directories. The
   `infrastructure` Kustomization prunes what it owned: the HelmReleases, which orphan their objects, and nothing of
   what the `cert-manager` Kustomization relabelled in step 2; the CRDs are additionally marked `prune: disabled`.
   Read again: every Certificate still `Ready`, no pod restarted except by the placement change itself.
4. **Afterwards.** helm-controller stays for the charts still on it (envoy, zitadel, forgejo, CNPG, the static
   provisioner) until each has had this treatment; the hooks of envoy and zitadel are the known obstacle
   (`docs/research/2026-10-rendered-manifests-over-oci.md`). Record the outcome in decision 028's audit.

What can go wrong, and the way back: if Flux deletes a CRD the Certificates go with it, so step 3 is done only after
step 2 is read as healthy and the `prune: disabled` annotation is seen on the live CRDs. The way back from a bad
artifact is the same as for zot: apply `rendered/` from a checkout with `kubectl apply --server-side`.

## Bootstrap

A fresh cluster has nothing in zot and no certificate on `registry.dataverket.org` to push through, and cert-manager
is what issues that certificate. `bootstrap/cert-manager-from-git.yaml` applies this directory straight from the
repository, without prune, until the artifact is in zot; then it is removed, as zot's own bootstrap is (decision 011).
