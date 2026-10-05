# Plan: every sops store under vaults/

Written 2026-09-30. Decision 016 moved `break-glass/` to `vaults/operator/break-glass/` and added
`vaults/operator/hov1/`. This plan is the rest: make the whole of `vaults/` follow the same rule.

## The rule

A store is a folder under `vaults/`, one secret per `<name>.enc.json`, its fields the secret's values. Its readers
are its rule in `.sops.yaml`. A folder is a swamp vault only if it has a config in `vaults/@dataverket/sops/` and
swamp's key in its rule.

## Steps

1. **Operator-only by default.** Done 2026-10-05: the general `vaults/` rule became two, `vaults/infra/` for
   `swamp-fabrikk-infra` and the operators, then a catch-all `vaults/` for the operators only. A new folder is
   unreadable by any process until someone names it; today's files kept their recipients, which
   `bin/check-recipients` confirmed, and a probe path under a new folder encrypted to the two YubiKeys alone.
2. **Check recipients on every commit.** Run `bin/check-recipients` from a git pre-commit hook and in CI. It
   already compares each file's recipients with its rule; this makes it a guard instead of a tool. CI since
   2026-10-04: `.forgejo/workflows/check.yaml` runs it on every push, on the org runner, with no secret, since
   the check reads public keys only. The pre-commit hook is not started.
3. **No vault config under vaults/operator/.** Extend `bin/check-recipients` to fail when any
   `vaults/@dataverket/sops/*.yaml` has a `secretsDir` inside `vaults/operator/`. `@dataverket/sops` encrypts to
   its own config's recipients, so such a config would write values swamp can read.
4. **Old wording.** Done 2026-09-30. The credential tiers plan (since removed), `2026-09-access-requests.md`,
   `2026-09-kubernetes-identity.md` and the finding in decision 010 name `vaults/operator/` and 016. Entries that
   record what was done on 2026-09-29 keep their history and say where the thing is now.
5. **One copy of the hov1 root key pair.** Done 2026-09-30: `vaults/operator/hov1/root.enc.json` is the copy,
   read with `sops exec-env`. The Proton Pass item and `~/.config/hov1-root.env` are deleted. Proton Pass stays a
   tier 1 mechanism; it is not a store for this repository.

## Status

| Step | State |
|---|---|
| 1 | done 2026-10-05: `vaults/infra/` rule, then operators-only catch-all |
| 2 | CI done 2026-10-04; the pre-commit hook not started |
| 3 | not started |
| 4 | done |
| 5 | done |
