# Runbook: put the forge's signing key back

Written 2026-11-18. Step 2 ran for real on 2026-11-19, as the key's first installation; the forge signed its first
merge on 2026-11-20. Tested the same day on an empty volume in a local kind cluster, below; not yet run in a
real rebuild.

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

prints the public half above, and `swamp behavior run forge-signing-key health` compares the two, as the `health`
workflow does every run. Then merge any pull request with the forge's button and read the merge commit:

```sh
swamp behavior run forgejo pr_get --input owner=<owner> --input name=<repo> --input index=<number>
curl -s https://git.dataverket.org/api/v1/repos/<owner>/<repo>/commits?limit=1 | jq '.[0].commit.verification'
```

`verified` is `true` and the signer is `noreply@dataverket.org`. Wrong results:

| Seen | Means |
|---|---|
| The pod stays `Pending`, with the event `secret "forgejo-ssh-signing-key" not found` | The Secret is missing |
| The pod stays `Pending`, with the event `references non-existent secret key: privateKey` | The Secret's key has another name; delete the Secret and run step 2 as written |
| A merge answers "No private key found for public key" | The file on the volume is gone; restart the pod, the init container installs it again |
| `signing-key.ssh` prints another key | Another key was installed. Stop: every merge signed from now on is by the wrong key |

## Tested on an empty volume

On 2026-11-20, in a kind cluster on an operator's machine, with a throwaway key: the chart's init scripts and its
`init-directories` and `configure-ssh-signing` containers exactly as `artifacts/forgejo/rendered/` holds them, the
same Forgejo image, and an empty data volume, as after a rebuild.

| Step | Result |
|---|---|
| The pod with no Secret | `Pending`, event `secret "forgejo-ssh-signing-key" not found` |
| A Secret whose key is `key`, not `privateKey` | `Pending`, event `references non-existent secret key: privateKey` |
| The Secret as step 2 makes it | The pod starts by itself, with no restart, within two and a half minutes |
| The files | `/data/git/.ssh-signing` mode 700, `key` mode 600, `key.pub` derived and equal to the key's public half, all owned by uid 1000 |
| A merge | Signed, verified as `noreply@dataverket.org`; the forge serves the same key |

What the test does not cover: a Cinder volume in place of an `emptyDir`, Postgres in place of sqlite, and `sops -d
--extract` in place of `jq`, which step 2 already ran with for real on 2026-11-19.

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

A person copied it into the operators' store the same day, no touch, since encryption needs only public keys:

```sh
kubectl --context dataverket-prod-admin -n forgejo exec deploy/forgejo -c forgejo -- cat /data/git/.ssh-signing/key |
  jq -Rs '{FORGEJO_SIGNING_KEY: .}' |
  sops -e --filename-override vaults/operator/osl1/forgejo-signing.enc.json /dev/stdin \
    > vaults/operator/osl1/forgejo-signing.enc.json
```

and made the Secret with step 2 above on 2026-11-19, before the settings in `artifacts/forgejo/recipe/values.yaml`
were pushed: with the settings applied and no Secret, the forge's pod does not start. The first Secret came from
the operators' copy, not from the pod, so the put-back was tested before the key was in use. The artifact was
applied on 2026-11-20 at 09:00 UTC, and the first signed merge is `1ca7fa9` on this repository, eight minutes later.
