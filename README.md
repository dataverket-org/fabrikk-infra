# fabrikk-infra

The infrastructure needed to stand up a fabrikk: the forge and its runners, identity, the registry, and the platform
under them (storage, gateway, certificates, DNS) on the `dataverket-prod` cluster, applied by Flux. This is the
platform baseline (L0) for the cluster that hosts the software factory. Application overlays (L2) live in `miljo`;
product manifests (L1) live next to the code in `fabrikk`. No product is deployed from here.

This repository was `flux-bootstrap` until 2026-09-17. The forge redirects the old name until it is reused.

## Layout

| Path | Applied by | Contents |
|---|---|---|
| `clusters/production/` | `flux bootstrap` | The Flux system and the two root Kustomizations below. |
| `infrastructure/` | Kustomization `infrastructure` | OpenStack cloud controller and Cinder CSI, CNPG, Envoy Gateway, cert-manager and the wildcard certificate, external-dns, Kata. |
| `apps/` | Kustomization `apps` (after `infrastructure`) | Forgejo, its runners, Zitadel, and the pointer to zot. |
| `artifacts/<name>/` | Nobody, from git | Sources of OCI config artifacts. Pushed with `artifacts/<name>/push.sh`, pulled by an `OCIRepository` declared under `apps/`. |
| `bootstrap/` | `bootstrap.sh` | What must exist before the rest can be applied: the cluster's SOPS key, and zot from git until zot serves its own config. |

## Bootstrap and recovery

`bootstrap.sh`. Every step checks state and skips what is done, so it is the fresh-cluster path, the recovery path,
and the record of both. It stops once on a new cluster, when the freshly generated SOPS recipient must be put in
`.sops.yaml` and every `*.enc.yaml` re-encrypted with a YubiKey. It needs kubectl, flux, sops, git, and a YubiKey.
The reasons behind each step are in `docs/decisions/`.

## Names

| Name | Used by | Why |
|---|---|---|
| `registry.dataverket.org` | Everything that pushes or pulls artifacts: CI, developers, other clusters, cosign | The registry's identity (TLS through the gateway, anonymous pull, push for `fabrikk-ci`) |
| `zot.zot.svc.cluster.local:5000` | Only `apps/zot/source.yaml`, this cluster fetching zot's own config | Must survive external DNS, the LoadBalancer, or the certificate being broken (decision 004) |
| `git.dataverket.org` | Flux's `GitRepository`, humans, the push mirror to codeberg.org | The source of record |

## Secrets

Two SOPS setups live here, with different readers and different recipients. `.sops.yaml` holds both, one creation
rule each, and names every recipient in its comments. Public keys only; the file is safe to commit.

| Setup | Files | Who decrypts | Recipients |
|---|---|---|---|
| Cluster files | `*.enc.yaml` under `apps/`, `artifacts/`, `infrastructure/` | Flux, on apply, with the cluster's own key | The cluster key (`flux-system/sops-age`, generated in-cluster, decision 001) and each human operator's YubiKey |
| Swamp vault | `vaults/infra.enc.json` | The swamp models in `models/`, on every run | Each human operator's YubiKey and the factory host's soft key |

**Cluster files** are Secret manifests with only `data`/`stringData` encrypted, so kind, name and namespace stay
readable and diffs stay meaningful. Flux decrypts them on apply; nothing else ever does. Charts and workloads take
secrets by reference (`existingSecret`, `secretKeyRef`, a mounted Secret), never as inline values. The humans are
recipients so that the files can be edited and re-encrypted; the factory host is not, so no unattended process can
read a cluster secret.

**The swamp vault** holds the credentials the operating models use (decision 006): the forge token, the Omni service
account keys, the registry push credential. The `@zocc/sops-age` vault type carries its own recipient list in
`vaults/@zocc/sops-age/*.yaml` (`agePublicKey`) and ignores `.sops.yaml`; every write re-encrypts the whole file to
that list. The second rule in `.sops.yaml` repeats the same recipients so that `sops vaults/infra.enc.json` from a
terminal encrypts to the same set. The factory host's soft key is a recipient so that scheduled runs decrypt
unattended; it is never a recipient of a cluster file.

**Adding an operator** is therefore two edits and two re-encryptions: their key in both rules of `.sops.yaml` and
in the vault's `agePublicKey`; `sops updatekeys` on every cluster file, with a YubiKey that is already a recipient;
and one `swamp vault put` of any key, which rewrites the vault to the new list (the provider cannot delete, so
`recipients/reencrypt` is the marker of the last such write). Removing one is the same with the key taken out.

This repository owns a credential. When the software factory needs the same value, it is copied from here into the
factory's vault, never the other way around (decision 005).

Not migrated yet: the Forgejo admin, mailer, and OAuth secrets, the Zitadel masterkey, the runner registration
token, and `cloud.conf` are still created by hand (see `apps/forgejo/*.example.yaml`). They move here one at a time.

## Gitless delivery

`apps/zot/source.yaml` is the pattern: an `OCIRepository` on the registry and a Kustomization that applies whatever
the artifact holds, decrypting with the cluster key. `artifacts/zot/` is the artifact's source, plain manifests with
the image pinned by digest; `push.sh` pushes the directory as it is, tagged with the commit and `current`.

zot hosts its own config artifact. The loop is closed by git: `bootstrap/zot-from-git.yaml` applies the same
directory straight from the repository, without prune, until zot serves its first artifact, and again whenever a bad
artifact leaves zot unable to serve (decisions 003 and 004). Nothing outside this cluster and this repository is
needed to recreate the registry. Verification with cosign is a TODO until the platform signing key exists.

## The registry

zot at `registry.dataverket.org`: anonymous pull, push for `fabrikk-ci` (`artifacts/zot/zot-htpasswd.enc.yaml`; the
plaintext is `zot-ci-credentials.enc.yaml`, the source the factory's vault copies from). One replica on a retained
Cinder volume; the zot image itself comes from ghcr.io, pinned by digest.

## Operating models (swamp)

This repository is also a swamp repository: `models/` holds the instances a human uses to operate what is deployed
here, `extensions/models/` their custom methods, `workflows/` the release runner, the forge-to-GitHub mirror and the
fleet disk survey, and `vaults/infra.enc.json` the credentials (decision 006). They came from `fabrikk` on 2026-09-18
so that the factory holds no credential for this cluster. Run them from this checkout, with `_bin` on `PATH` for the
Flux model and `omnictl` and `talosctl` on `PATH` for the Omni and Talos models:

```sh
swamp model search --json | jq '.results[].name'     # forgejo, omni, registry, runner-pods, dataverket-prod-*
swamp model method run forgejo health
swamp model method run omni discover                  # the Talos fleet, read-only
swamp workflow run fleet-volumes                      # every node's disks, partitions and EPHEMERAL usage, read-only
swamp model method run runner-pods list               # context fabrikk-readers
swamp model method run dataverket-prod-helm list      # context dataverket-prod-admin
swamp model method run registry copy --input source=<upstream>@sha256:<digest> --input name=<image> --input tag=<tag>
swamp workflow run fabrikk-runner                     # the release runner; every step is guarded by its record
```

`dataverket-prod-talos` (`@dataverket/talosctl/node`) reaches the machines through Omni's proxy; its node list and
talosconfig are the `talosconfig-dataverket-prod` record that `omni talosconfig` writes and `fleet-volumes` refreshes,
so run the workflow rather than the model's methods alone. Its `reset`, `upgrade` and `patchConfig` change machines;
`volumes`, `version` and `services` do not.

Kube contexts come from your default kubeconfig (`fabrikk-readers` for reading, `dataverket-prod-admin` for
changes); model definitions name contexts, never paths. The vault decrypts with an operator's YubiKey or the factory host's
soft key, see Secrets above; `swamp vault list-keys infra` shows what it holds.

## Decisions

`docs/decisions/`: one numbered record per decision, why and with what consequences. New shape, new record.
