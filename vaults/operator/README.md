# vaults/operator

Values only a person reads. Plain sops, encrypted to the two operators' YubiKeys (`beddari`, `linus`) and to
nothing else; the first rule in `.sops.yaml`. No process key is a recipient and there is no swamp vault config for
it, so nothing unattended can decrypt what is here. The operators can also read `vaults/infra/`, for recovery; this
folder is the one only they can read. Decision 016.

| Folder | What | Filled by |
|---|---|---|
| `break-glass/` | What tier 1 falls back on when a login mechanism fails | `docs/plans/2026-09-break-glass.md` |
| `hov1/` | The hov1 gateway's CA key (`ca.key`) and root key pair (`root`) (`backup/versitygw/`) | A person, from `backup/hov1/` on the site host |
| `osl1/` | The osl1 gateway's root key pair (`root`), for the `osl1-s3` model (`artifacts/versitygw/`) | A person, from `artifacts/versitygw/versitygw-root.enc.yaml`, the source of record |

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
