# vaults/operator

Values only a person reads. Plain sops, encrypted to the two operators' YubiKeys (`beddari`, `linus`) and to
nothing else; the first rule in `.sops.yaml`. No process key is a recipient and there is no swamp vault config for
it, so nothing unattended can decrypt what is here. The operators can also read `vaults/infra/`, for recovery; this
folder is the one only they can read. Decision 016.

| Folder | What | Filled by |
|---|---|---|
| `break-glass/` | What tier 1 falls back on when a login mechanism fails | `docs/plans/2026-09-break-glass.md` |
| `hov1/` | The hov1 gateway's CA key (`ca.key`) and root key pair (`root`) (`backup/versitygw/`) | A person, from `backup/hov1/` on the site host |
| `osl1/` | The osl1 gateway's root key pair (`root`), for the `osl1-s3` model (`artifacts/versitygw/`); the site's artifact signing key pair (`cosign`), below | A person, from `artifacts/versitygw/versitygw-root.enc.yaml`, the source of record; a person, at a terminal, once |

One secret per file, `<name>.enc.json`. A secret's fields are its values: `root` holds `ROOT_ACCESS_KEY` and
`ROOT_SECRET_KEY`, `ca.key` holds `value`. Named after the variables a tool reads, the fields go straight into its
environment:

```sh
sops exec-env vaults/operator/hov1/root.enc.json 'swamp model method run hov1-s3 inventory'   # one touch
sops -d --extract '["value"]' vaults/operator/hov1/ca.key.enc.json                          # one touch
jq -n '{NAME: env.NAME}' |
  sops -e --filename-override vaults/operator/<path>.enc.json /dev/stdin > vaults/operator/<path>.enc.json
```

Run from the repository root: `--filename-override` is what matches the rule. `bin/check-recipients` confirms every
file here is encrypted to the two operators and nobody else.

## Signing keys

One cosign key pair per site, both halves in one file, `vaults/operator/<site>/cosign.enc.json`, with the fields
cosign reads from the environment: `COSIGN_PRIVATE_KEY`, `COSIGN_PUBLIC_KEY` and `COSIGN_PASSWORD`, the last empty
so that the YubiKey touch is the only secret. The key signs the site's artifacts, `platform/*` in zot, and Flux
verifies them before applying (decision 028). It is tier 3 with a human owner: it cannot be minted with a lifetime,
it is read by a person at `push.sh` time and by nothing unattended, and the release runner, when it exists, signs
with a key of its own that is never here. The public half also lives in plain in `clusters/production/`, as the
Secret Flux reads; keeping it in this file too is so the pair is found in one place.

Made once per site, by a person, at a terminal, never by a session:

```sh
cd "$(mktemp -d)" && COSIGN_PASSWORD= cosign generate-key-pair      # cosign.key and cosign.pub, passphrase empty
jq -n --rawfile k cosign.key --rawfile p cosign.pub '{COSIGN_PRIVATE_KEY: $k, COSIGN_PUBLIC_KEY: $p, COSIGN_PASSWORD: ""}' |
  sops -e --filename-override vaults/operator/osl1/cosign.enc.json /dev/stdin > "$OLDPWD/vaults/operator/osl1/cosign.enc.json"
kubectl create secret generic cosign-osl1 -n flux-system --from-file=cosign.pub --dry-run=client -o yaml   > "$OLDPWD/clusters/production/cosign-osl1.yaml"                # the public half, for OCIRepository.spec.verify
cd "$OLDPWD" && rm -rf "$OLDPWD"                                     # nothing of the pair stays in clear
```

Run from the repository root; the encryption needs only the recipients' public keys, and no touch. Every
`artifacts/*/push.sh` then signs what it pushed, one touch, when the file exists:

```sh
sops exec-env vaults/operator/osl1/cosign.enc.json \
  'cosign sign --yes --tlog-upload=false --key env://COSIGN_PRIVATE_KEY registry.dataverket.org/platform/<name>@sha256:...'
```

Nothing goes to the public transparency log. Verification is switched on per artifact, in its `OCIRepository`
(`spec.verify`, the block each `source.yaml` carries commented), only after that artifact has been pushed signed
once; before that the next reconcile would refuse the current tag.

A lost key is not an incident for the cluster: make a new pair, replace both files, push every artifact of the
site again. A leaked one is: replace the pair the same way, and the old public key leaves `clusters/production/`,
so nothing it signed is trusted any more. Either way the artifacts are re-pushed from a clean checkout, so the
revision annotations stay true. hov1 gets `vaults/operator/hov1/cosign.enc.json` the day it has a cluster.
