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

Both charts ran as HelmReleases in `infrastructure/`; on 2026-10-06 they were handed to the artifact. The objects
are the same; what changes is which controller owns them. What was done, and what it taught, in order.

1. **Ship the artifact beside the releases.** `push.sh`, with `infrastructure/cert-manager/source.yaml` already in
   git. Both paths apply the same objects, and helm-controller's drift detection is off, so they do not fight.
   Server-side apply moves the objects' Flux labels to the `cert-manager` Kustomization. Read: every object and
   CRD labelled `kustomize.toolkit.fluxcd.io/name=cert-manager`, `prune: disabled` on the live CRDs, every
   Certificate and the ClusterIssuer `Ready`, no pod restarted. On a fresh cluster this step is
   `bootstrap/cert-manager-from-git.yaml` instead, until zot serves.
2. **Make Helm forget its objects before the HelmRelease goes.** This is the step 2026-10-06 got wrong.
   `uninstall.deletionPropagation: orphan` was set, in the belief that an orphaned uninstall leaves the objects.
   It does not: Helm's `orphan` is the Kubernetes deletion propagation, so Helm still deletes every object of the
   release and only spares their dependents. The Deployments, Services, ServiceAccounts, RBAC and the ConfigMap
   were deleted and recreated by the `cert-manager` Kustomization within seconds; the pods, orphaned, kept
   running, but their tokens belonged to the deleted ServiceAccounts, and the controller and cainjector crashed
   with `Unauthorized` until every pod was replaced. Certificates and the ClusterIssuer were never Helm's and were
   untouched; the CRDs came from git and were untouched. The right way, for the next chart, is one last upgrade of
   the HelmRelease that marks every object `keep`, so Helm's uninstall skips them all. Add to the HelmRelease:

   ```yaml
   spec:
     postRenderers:
       - kustomize:
           patches:
             - target:
                 kind: ".*"          # every object the chart renders
               patch: |-
                 apiVersion: v1
                 kind: Placeholder     # ignored: with a target, the patch applies to what the target matches
                 metadata:
                   name: placeholder
                   annotations:
                     helm.sh/resource-policy: keep
   ```

   The spec change makes helm-controller run an upgrade, which writes the annotation onto every live object.
   Read it back before going on, on every kind the chart owns, Deployments, Services, ServiceAccounts, Roles,
   RoleBindings, ConfigMaps, ClusterRoles, ClusterRoleBindings and webhook configurations:

   ```sh
   kubectl get deploy,svc,sa,cm,role,rolebinding -n <ns> \
     -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.metadata.annotations.helm\.sh/resource-policy}{"\n"}{end}'
   ```

   Every line must end in `keep`. Then step 3: at uninstall Helm reports the objects as kept and deletes only its
   release history, and the pods keep ServiceAccounts that still exist. `uninstall.deletionPropagation` is left
   at its default; it was never the right knob.
3. **Remove the Helm path.** One commit: drop the component directories and the HelmRelease, HelmRepository, CRD
   download and namespace files from `infrastructure/`, leaving a `cert-manager/` with `source.yaml` alone. The
   `infrastructure` Kustomization prunes the HelmRelease and HelmRepository objects and nothing of what the
   `cert-manager` Kustomization relabelled in step 1; the CRDs are additionally `prune: disabled`. Read again:
   every Certificate `Ready`, every pod `Ready` and, with step 2 done right, none restarted.
4. **Afterwards.** helm-controller stays for the charts still on it (envoy, zitadel, forgejo, CNPG, the static
   provisioner) until each has had this treatment; the hooks of envoy and zitadel are the known obstacle
   (`docs/research/2026-10-rendered-manifests-over-oci.md`). Record the outcome in decision 028's audit.

What can go wrong, and the way back: if Flux deletes a CRD the Certificates go with it, so step 3 is done only after
step 1 is read as healthy and the `prune: disabled` annotation is seen on the live CRDs. The way back from a bad
artifact is the same as for zot: apply `rendered/` from a checkout with `kubectl apply --server-side`.

## Bootstrap

A fresh cluster has nothing in zot and no certificate on `registry.dataverket.org` to push through, and cert-manager
is what issues that certificate. `bootstrap/cert-manager-from-git.yaml` applies this directory straight from the
repository, without prune, until the artifact is in zot; then it is removed, as zot's own bootstrap is (decision 011).
