# Runbook: a second swamp host

Written 2026-10-28 for the second operator's host, ahead of the shared S3 datastore on osl1. Not yet run. It
applies to any host that runs swamp here and has no key file of its own, which on 2026-10-28 is every host: the
key made with the vault on 2026-09-20 is on none of them.

## Why

Swamp on a host reads `vaults/infra/` unattended on every model run, with a process key the vault config names by
file name. One key per decrypting process, and a host is a process (decision 002, audit of 2026-10-28): a second
host gets a key of its own, generated there, under the same file name as every swamp host. The first host's key is
never copied. The alternative, the first key wrapped into `vaults/operator/` for the second host to fetch, was
declined because two hosts on one key cannot be revoked apart, and the key would become material at rest in the
repository.

## What it touches

| | |
|---|---|
| Reads | `vaults/infra/`, nine `*.enc.json`, the swamp vault `infra` |
| Never reads | The cluster files under `apps/`, `artifacts/`, `infrastructure/`; anything under `vaults/operator/` |
| File on the host | `~/.config/sops/age/swamp-fabrikk-infra.txt`, mode 0600. The rule is `swamp-<repo>.txt`: one static name per repository, the same on every host, never a host or an owner in it. The vault config names the key by this file name, which is why it cannot vary |
| Listed as | `swamp-fabrikk-infra.<host>` in `.sops.yaml`, the host's short name after the dot, as `hostname -s` prints it. The entry without a host is the key made with the vault on 2026-09-20, whose holder is to be confirmed. The public key is what tells hosts apart |
| Touches | The operator's YubiKey, once per vault file in step 4. Everything else is public keys only |
| Needs | `age`, `sops`, `yq`; a checkout on `main` with `task hooks` run once |

Who decrypts what, once step 6 is pushed:

| Key | Lives | Cluster files | `vaults/infra/` | `vaults/operator/` |
|---|---|---|---|---|
| `cluster-dataverket-prod` | Secret `flux-system/sops-age`, in the cluster | unattended | | |
| `swamp-fabrikk-infra` | key file on the host that made it, to be confirmed | | unattended | |
| `swamp-fabrikk-infra.<host>` | key file on this host, step 1 | | unattended | |
| `beddari` | YubiKey | touch | touch | touch |
| `linus` | YubiKey | touch | touch | touch |

No process key reads `vaults/operator/`, and no swamp key reads a cluster file.

## Steps

1. **Generate the key on the swamp host**, as the user that runs swamp. Nothing of this file ever leaves the host.

   ```sh
   mkdir -p ~/.config/sops/age
   age-keygen -o ~/.config/sops/age/swamp-fabrikk-infra.txt
   chmod 0600 ~/.config/sops/age/swamp-fabrikk-infra.txt
   age-keygen -y ~/.config/sops/age/swamp-fabrikk-infra.txt     # the public key, age1...
   ```

   Do not append it to `keys.txt`. That file holds only YubiKey identities, so that `sops` from a terminal always
   asks for a touch; the vault type loads this file by name only when a swamp model runs.

2. **Name the key in `.sops.yaml`.** Three edits, all public: the entry in the `identities` block beside the first
   host's, a line in the header comment, and the alias in the `vaults/infra/` rule and no other.

   ```diff
    identities:
      cluster-dataverket-prod: &cluster_dataverket_prod age1g3x9w...
      swamp-fabrikk-infra: &swamp_fabrikk_infra age15d64a...
   +  swamp-fabrikk-infra.<host>: &swamp_fabrikk_infra_<host> age1<your public key>
      beddari: &beddari age1yubikey1q0d8...
      linus: &linus age1yubikey1qwta...

      # vaults/infra/: the swamp vault, read unattended by the swamp host's key.
      - path_regex: vaults/infra/.*\.enc\.json(\.plain\.tmp)?$
        key_groups:
          - age:
              - *swamp_fabrikk_infra
   +          - *swamp_fabrikk_infra_<host>
              - *beddari
              - *linus
   ```

   In the header comment the `swamp-fabrikk-infra.<host>` entry already describes the key; under its `(no host)`
   line add one for the new host in the same shape:

   ```diff
    #     (no host)            age15d64...         made 2026-09-20 with the vault; ...
   +#     .<host>              age1...             <owner>'s host, since <date>
   ```

3. **Add it to the vault config.** The `@dataverket/sops` vault encrypts to its own config and ignores
   `.sops.yaml`, so the two lists must be equal. The file is `vaults/@dataverket/sops/29f189c7-19fa-432e-af77-c21ef1f6d75d.yaml`;
   `agePublicKey` is one comma-separated string.

   ```diff
     agePublicKey: >-
   -    age1yubikey1q0d8...,age15d64a...,age1yubikey1qwta...
   +    age1yubikey1q0d8...,age15d64a...,age1<your public key>,age1yubikey1qwta...
   ```

4. **Re-encrypt the vault files.** Needs the operator's YubiKey. The operator is already a recipient, so
   `sops updatekeys` unwraps each file's data key and wraps it for the new recipient too. PIN once, then one touch
   per file. Only `vaults/infra/`: the cluster files and `vaults/operator/` keep their recipients.

   ```sh
   find vaults/infra -name '*.enc.json' -exec sops updatekeys -y {} \;
   ```

5. **Check.**

   ```sh
   bin/check-recipients
   git diff --stat        # .sops.yaml, the vault config, nine files under vaults/infra/
   ```

   The check must end with `Every encrypted file matches its rule in .sops.yaml, and every vault config its rule`.
   If it names a file, a recipient list does not match its rule: fix the config or the rule, never the file by hand.

6. **Commit and push.** The pre-commit hook runs the same check. The message says what was added and why, as
   decision 002 asks of any change of readers.

   ```sh
   git add .sops.yaml vaults/@dataverket/sops vaults/infra
   git commit -m 'feat(vaults): swamp-fabrikk-infra.<host> reads vaults/infra

   A process key for swamp on <host>, so the operating models read the
   vault unattended there as well. One key per host (decision 002, audit
   of 2026-10-28); the key is a recipient of vaults/infra/ only.'
   git push
   ```

## Proof

On the new host, a model that reads the vault runs without a touch prompt, and the audit trail records the read:

```sh
swamp vault list-keys infra
swamp model method run forgejo health
swamp vault audit-trail --vault infra | tail -3
```

A touch prompt means the key file is not where the vault config looks, or `SOPS_AGE_KEY_FILE` is exported in that
shell and wins over the name.

## Not part of this

- Adding the key to the cluster-files rule or the `vaults/operator/` rule. Those stay as they are.
- Copying the key from the first host. A second host is a second process and gets a second key.
- Editing the README. Its Secrets section already describes one key per host under one file name.
- Joining the datastore. That is one key copy, in the README's Operating models section, and needs this done first.
