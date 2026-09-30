# vaults/operator

Values only a person reads. Plain sops, encrypted to the two operators' YubiKeys (`beddari`, `linus`) and to
nothing else; the first rule in `.sops.yaml`. No process key is a recipient and there is no swamp vault config for
it, so nothing unattended can decrypt what is here. The operators can also read `vaults/infra/`, for recovery; this
folder is the one only they can read. Decision 016.

| Folder | What | Filled by |
|---|---|---|
| `break-glass/` | What tier 1 falls back on when a login mechanism fails | `docs/plans/2026-09-break-glass.md` |
| `hov1/` | The hov1 gateway's CA key and root key pair (`backup/versitygw/`) | A person, from `backup/hov1/` on the site host |

One value per file, `<name>.enc.json` holding `{"value": ...}`, the same shape as `vaults/infra/`:

```sh
sops -d --extract '["value"]' vaults/operator/hov1/ca.key.enc.json      # a touch, every time
jq -n --rawfile v <file> '{value: $v}' |
  sops -e --filename-override vaults/operator/<path>.enc.json /dev/stdin > vaults/operator/<path>.enc.json
```

Run from the repository root: `--filename-override` is what matches the rule. `bin/check-recipients` confirms every
file here is encrypted to the two operators and nobody else.
