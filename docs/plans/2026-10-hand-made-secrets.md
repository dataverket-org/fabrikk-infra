# Plan: the hand-made Secrets move into the cluster store

Written 2026-10-05. Four Secrets in the cluster were created by hand and exist nowhere in git, which `bootstrap.sh`
lists under "still created by hand". A rebuild from git (decision 021) stops at each of them until a person
recreates it from wherever the value is. Each moves into the cluster-files store, a sops-encrypted `*.enc.yaml`
beside the manifests that read it, encrypted to the cluster key and the two operators (decision 002), applied by
Flux like every other Secret. `nordhost-config` goes first.

## The four, in order

| Secret | Namespace | Read by | Where it goes | Origin of the value |
|---|---|---|---|---|
| `nordhost-config` | `cert-manager` | `nordhost-webhook`, external-dns's webhook sidecar | `infrastructure/nordhost-webhook/nordhost-config.enc.yaml` | DirectAdmin login keys a person mints; the file is the source of record |
| `cloud-config` | `kube-system` | the cloud controller manager, the Cinder CSI controller | `infrastructure/occm/cloud-config.enc.yaml` | An OpenStack application credential, minted for the cluster |
| `forgejo-admin`, `forgejo-mailer`, `forgejo-zitadel-oauth-secret` | `forgejo` | the forge | `apps/forgejo/*.enc.yaml`, replacing the `*.example.yaml` | The forge's install values, Nordhost's mail login, Zitadel's client secret |
| `org-dataverket-runner-secret` | `forgejo-runners` | the org runner | `apps/forgejo-runners/org-dataverket-runner/runner-secret.enc.yaml` | A registration token the forge issues; `runner_registration_token` on the forgejo model mints one |

## The procedure, per Secret

1. **Extract into the store without a clear copy on disk**: the live Secret's `data`, decoded, piped straight into
   `sops --encrypt --filename-override <path>` from the repository root, so the cluster-files rule applies. Only
   `data`/`stringData` are encrypted; name and namespace stay readable.
2. **List it** in the directory's `kustomization.yaml`, run `bin/check-recipients`, commit.
3. **Flux adopts it.** kustomize-controller applies with server-side apply and takes the fields from the hand-made
   object; the Secret keeps its name, so nothing that mounts it changes and no pod restarts. Check: the Secret
   carries the `kustomize.toolkit.fluxcd.io/name` label, and the pods that read it are unchanged.
4. **Shorten the list** in `bootstrap.sh` and the README's "not migrated yet" sentence.

From then on a rotation is a `sops` edit of the file with a YubiKey, a commit, and for a reader that loads the
value once at start, a rollout restart. The example files under `apps/forgejo/` go when their Secrets are in.

## What is assumed and must be checked

- Server-side apply adopts the hand-made object without a conflict. If it refuses, the hand-made Secret is deleted
  in the same minute Flux applies; the readers hold their mounted copy until their next restart.
- `cloud-config` is `cloud.conf`, an INI with the application credential; it encrypts like any other `data` key.

## Status

| Secret | State |
|---|---|
| `nordhost-config` | moved 2026-10-05 |
| `cloud-config` | not started |
| the three forge Secrets | not started |
| the runner token | not started |
