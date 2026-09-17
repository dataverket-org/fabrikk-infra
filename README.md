# flux-bootstrap

Platform configuration (L0) for the `dataverket-prod` cluster, applied by Flux. This is the environment line's
platform config: storage, gateway, certificates, DNS, the forge and its runners, identity, and the registry.
Application overlays (L2) live in `miljo`; product manifests (L1) live next to the code in `fabrikk`. No product is
deployed from here.

## Layout

| Path | Applied by | Contents |
|---|---|---|
| `clusters/production/` | `flux bootstrap` | The Flux system and the two root Kustomizations below. |
| `infrastructure/` | Kustomization `infrastructure` | OpenStack cloud controller and Cinder CSI, CNPG, Envoy Gateway, cert-manager and the wildcard certificate, external-dns, Kata. |
| `apps/` | Kustomization `apps` (after `infrastructure`) | Forgejo, its runners, Zitadel, and the pointer to zot. |
| `artifacts/<name>/` | Nobody, from git | Sources of OCI config artifacts. Pushed with `artifacts/<name>/push.sh`, pulled by an `OCIRepository` declared under `apps/`. |
| `bootstrap/` | A human, once | What must exist before the rest can be applied: the cluster's SOPS key, and zot from git until zot serves its own config. |

## Bootstrap

`bootstrap.sh`: `flux bootstrap` against `git.dataverket.org/dataverket/flux-bootstrap` (codeberg.org is a push
mirror), then `bootstrap/sops-age-keygen.yaml`, a Job that generates the cluster's age key inside the cluster and
prints the recipient. The private key exists only in Secret `flux-system/sops-age`. It is never backed up: if the
cluster is lost, the attesters' YubiKeys are recipients of every encrypted file, so a new cluster gets a new key and
`sops updatekeys` re-encrypts for it.

## Secrets

Secrets are committed as `*.enc.yaml` Secret manifests, encrypted with SOPS to the recipients in `.sops.yaml` (the
cluster key plus the attesters' YubiKeys), with only `data`/`stringData` encrypted. Flux decrypts on apply; nothing
else ever decrypts them. Charts and workloads take secrets by reference (`existingSecret`, `secretKeyRef`, a mounted
Secret), never as inline values.

This repository owns a credential. When the software factory needs the same value, it is copied from here into the
factory's vault, never the other way around.

Not migrated yet: the Forgejo admin, mailer, and OAuth secrets, the Zitadel masterkey, the runner registration
token, and `cloud.conf` are still created by hand (see `apps/forgejo/*.example.yaml`). They move here one at a time.

## Gitless delivery

`apps/zot/source.yaml` is the pattern: an `OCIRepository` on the registry and a Kustomization that applies whatever
the artifact holds, decrypting with the cluster key. `artifacts/zot/` is the artifact's source, plain manifests with
the image pinned by digest; `push.sh` pushes the directory as it is, tagged with the commit and `current`.

zot hosts its own config artifact. The loop is closed by git: `bootstrap/zot-from-git.yaml` applies the same
directory straight from the repository, without prune, until zot serves its first artifact, and again whenever a bad
artifact leaves zot unable to serve. Nothing outside this cluster and this repository is needed to recreate the
registry. Verification with cosign is a TODO until the platform signing key exists.

## The registry

zot at `registry.dataverket.org`: anonymous pull, push for `fabrikk-ci` (`artifacts/zot/zot-htpasswd.enc.yaml`; the
plaintext is `zot-ci-credentials.enc.yaml`, the source the factory's vault copies from). One replica on a retained
Cinder volume; the zot image itself comes from ghcr.io, pinned by digest.
