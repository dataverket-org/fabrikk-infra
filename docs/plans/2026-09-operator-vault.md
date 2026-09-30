# Plan: every sops store under vaults/

Written 2026-09-30. Decision 016 moved `break-glass/` to `vaults/operator/break-glass/` and added
`vaults/operator/hov1/`. This plan is the rest: make the whole of `vaults/` follow the same rule.

## The rule

A store is a folder under `vaults/`, one secret per `<name>.enc.json`, its fields the secret's values. Its readers
are its rule in `.sops.yaml`. A folder is a swamp vault only if it has a config in `vaults/@dataverket/sops/` and
swamp's key in its rule.

## Steps

1. **Operator-only by default.** Replace the general `vaults/` rule with two: `^vaults/infra/` for
   `swamp-fabrikk-infra` and the operators, then a catch-all `^vaults/` for the operators only. A new folder is
   then unreadable by any process until someone names it. Today's files keep the same recipients. The operators
   approve this diff; it decides who can read what.
2. **Check recipients on every commit.** Run `bin/check-recipients` from a git pre-commit hook and in CI. It
   already compares each file's recipients with its rule; this makes it a guard instead of a tool.
3. **No vault config under vaults/operator/.** Extend `bin/check-recipients` to fail when any
   `vaults/@dataverket/sops/*.yaml` has a `secretsDir` inside `vaults/operator/`. `@dataverket/sops` encrypts to
   its own config's recipients, so such a config would write values swamp can read.
4. **Old wording.** Update what still says `break-glass/` or "outside `vaults/`":
   `docs/plans/2026-09-credential-tiers.md`, `2026-09-access-requests.md` (its "`human` sops vault" is
   `vaults/operator/`), `2026-09-kubernetes-identity.md`, and the finding in decision 010.
5. **One copy of the hov1 root key pair.** Done 2026-09-30: `vaults/operator/hov1/root.enc.json` is the copy,
   read with `sops exec-env`. The Proton Pass item and `~/.config/hov1-root.env` are deleted. Proton Pass stays a
   tier 1 mechanism; it is not a store for this repository.

## Status

| Step | State |
|---|---|
| 1 | not started |
| 2 | not started |
| 3 | not started |
| 4 | not started |
| 5 | done |
