---
title: "Values only a person reads live in vaults/operator/"
description: "Every sops store is a folder under vaults/; who reads a folder is set by its recipients, and vaults/operator/ is the operators' alone."
type: adr
category: security
tags:
  - sops
  - break-glass
  - credentials
status: accepted
created: 2026-09-30
updated: 2026-09-30
author: dataverket
project: plattform
related:
  - 001-credential-tiers.md
  - 002-two-sops-stores-one-reader-each.md
  - 004-human-only-material-stays-outside-swamp.md
---
# 016: Values only a person reads live in vaults/operator/

## Status

Accepted. Supersedes 004.

## Context

The hov1 gateway's CA key and root key pair existed only on the site host's disk. They need a copy that survives
the host and that both operators can read, and nothing unattended needs them. The only human-only store was
`break-glass/`, outside `vaults/` by decision 004 and scoped to login fallback. A second store beside it, for a
different purpose, would make two places to look for the same kind of value.

## Decision

A sops store is a folder under `vaults/` with secrets in it, one secret per file; a secret's fields are its values.
A swamp vault's secrets have one field, `value`, which is what `@dataverket/sops` reads. Who reads a folder is set by its
rule in `.sops.yaml`, not by its name or place.

| Folder | Read by | Swamp vault config |
|---|---|---|
| `vaults/infra/` | `swamp-fabrikk-infra`, and the operators for recovery | Yes |
| `vaults/operator/` | `beddari`, `linus`, and nothing else | No |

`vaults/operator/` holds `break-glass/`, moved from the repository root, and `hov1/`. Its rule is first in
`.sops.yaml`. What 004 said about what may go in `break-glass/` still holds.

## Consequences

- A vault definition could now name `vaults/operator/`. It still could not read it: no process key is a
  recipient. The protection is the recipient list, where 004 had it in the location too.
- `@dataverket/sops` encrypts to its own config's recipients, not to `.sops.yaml`. A definition pointed at
  `vaults/operator/` by mistake would write values swamp can read. `bin/check-recipients` finds that, so it has to
  run on every commit to be a guard (`docs/plans/2026-09-operator-vault.md`).
- One place to look for any stored value, and one file shape for all of them.
- Making every other part of `vaults/` follow this (a human-only default for new folders, the older plans'
  wording) is `docs/plans/2026-09-operator-vault.md`.

## Decision Outcome

Every sops value in the repository is under `vaults/`, and a folder's readers are one rule in `.sops.yaml`.

## Related Decisions

Follows 001 and 002. Supersedes 004.

## Audit

### 2026-09-30

**Status:** Pending

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| `break-glass/` moved under `vaults/operator/`, rule moved | `.sops.yaml`, `vaults/operator/` | done |
| hov1 CA key and root key pair copied, each checked against the original | `vaults/operator/hov1/` | done |
| `bin/check-recipients` on every commit | `docs/plans/2026-09-operator-vault.md` | pending |

**Summary:** Break-glass moved, the hov1 values copied by an operator on 2026-09-30.

**Action Required:** Run `bin/check-recipients` on every commit (`docs/plans/2026-09-operator-vault.md`).

### 2026-09-30 (later the same day)

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| One secret per file, not one value: the root key pair is one file with two fields | `vaults/operator/hov1/root.enc.json` | done, checked against the original |

**Summary:** Wording only. A secret whose parts are used together is one file, so `sops exec-env` supplies it in
one touch. Who reads what is unchanged.

**Action Required:** None.

### 2026-10-05

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| `bin/check-recipients` on every push | `.forgejo/workflows/check.yaml` | done since 2026-10-04, on the org runner, public keys only |
| Operator-only is the default under `vaults/` | `.sops.yaml`, the last two rules | done 2026-10-05: `vaults/infra/` names the swamp key; any other folder encrypts to the operators alone |
| A new folder probed before commit | `vaults/probe/x.enc.json`, never written | two recipients, both YubiKeys |

**Summary:** The 2026-09-30 action is closed by CI, and a folder under `vaults/` is now operator-only by its place
as well as by its rule.

**Action Required:** None. The pre-commit hook and the check on vault configs are the operator-vault plan's steps 2
and 3.
