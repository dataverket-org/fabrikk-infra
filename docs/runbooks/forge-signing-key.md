# Runbook: put the forge's signing key back

Written 2026-11-18. Not run for real yet: the first installation, at the end, uses step 2 and is the first run.

## Why

The forge signs the merge commits it makes with an instance key (decision 036). The key cannot be rotated, and its
private half is deliberately not a cluster file, so Flux cannot restore it. After a rebuild, or when the Secret is
gone, a person puts it back from the operators' store.

## What it touches

| What | Read or written | Needs |
|---|---|---|
| `vaults/operator/osl1/forgejo-signing.enc.json`, field `FORGEJO_SIGNING_KEY` | Read | A YubiKey, one touch |
| Secret `forgejo/forgejo-ssh-signing-key`, key `privateKey` | Written | `dataverket-prod-admin` (`task admin:start`) |
| The forge pod | Restarted | The same context |
| `.sops.yaml`, the cluster files, `vaults/infra/` | Never touched | |

The public half, for comparison in the proof:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAcfXj8LExrU6aA9kLpzMr9rJ3xZJzTgVIN2pqgix121
SHA256:4vCkwj+dF1F3zbrsmt3xoY/Zuew2ojWdis3/FC/40KA
```

## Steps

1. Check what is there. `NotFound` is the state this runbook is for; an existing Secret means stop and read the
   proof first.

   ```sh
   kubectl --context dataverket-prod-admin -n forgejo get secret forgejo-ssh-signing-key
   ```

2. YubiKey, one touch. Make the Secret from the operators' store. The key goes through a pipe and is never on disk
   or in an argument.

   ```sh
   sops -d --extract '["FORGEJO_SIGNING_KEY"]' vaults/operator/osl1/forgejo-signing.enc.json |
     kubectl --context dataverket-prod-admin -n forgejo create secret generic forgejo-ssh-signing-key \
       --from-file=privateKey=/dev/stdin
   ```

   It must say `secret/forgejo-ssh-signing-key created`.

3. Let the forge take it. A pod that was waiting for the Secret starts by itself within a minute or two. A running
   pod is restarted, which takes the forge down for the Cinder detach and attach:

   ```sh
   kubectl --context dataverket-prod-admin -n forgejo rollout restart deployment/forgejo
   kubectl --context dataverket-prod-admin -n forgejo rollout status deployment/forgejo --timeout=180s
   ```

## Proof

```sh
curl -s https://git.dataverket.org/api/v1/signing-key.ssh
```

prints the public half above. Then merge any pull request with the forge's button and read the merge commit:

```sh
swamp behavior run forgejo pr_get --input owner=<owner> --input name=<repo> --input index=<number>
curl -s https://git.dataverket.org/api/v1/repos/<owner>/<repo>/commits?limit=1 | jq '.[0].commit.verification'
```

`verified` is `true` and the signer is `noreply@dataverket.org`. Wrong results:

| Seen | Means |
|---|---|
| The pod stays in `ContainerCreating` or `Init` | The Secret is missing, or its key is not named `privateKey` |
| A merge answers "No private key found for public key" | The file on the volume is gone; restart the pod, the init container installs it again |
| `signing-key.ssh` prints another key | Another key was installed. Stop: every merge signed from now on is by the wrong key |

## Not part of this

- Making a new key. A new key leaves every earlier forge merge unverified; decision 036 says when that is the only
  way left.
- Putting the key in a cluster file under `artifacts/` or `apps/`, or adding a recipient anywhere.
- Running any of this from an agent's session. The copy out of `vaults/operator/` is a person's step.

## The first installation, for the record

The key was made on 2026-11-18 inside the forge pod, through swamp, so that no workstation ever held it in clear:

```sh
swamp behavior run forgejo-pods exec --input podName=<forgejo pod> --input container=forgejo \
  --input 'command:json=["ssh-keygen","-q","-t","ed25519","-N","","-C","git.dataverket.org instance signing","-f","/data/git/.ssh-signing/key"]'
```

A person copies it into the operators' store, once, no touch, since encryption needs only public keys:

```sh
kubectl --context dataverket-prod-admin -n forgejo exec deploy/forgejo -c forgejo -- cat /data/git/.ssh-signing/key |
  jq -Rs '{FORGEJO_SIGNING_KEY: .}' |
  sops -e --filename-override vaults/operator/osl1/forgejo-signing.enc.json /dev/stdin \
    > vaults/operator/osl1/forgejo-signing.enc.json
```

and makes the Secret with step 2 above, before the settings in `artifacts/forgejo/recipe/values.yaml` are pushed:
with the settings applied and no Secret, the forge's pod does not start. Making the first Secret from the operators'
copy, and not from the pod, is what tests the put-back on the first day.
