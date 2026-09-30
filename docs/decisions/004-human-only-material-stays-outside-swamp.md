---
title: "Human-only material stays outside swamp's reach"
description: "Break-glass material is plain sops outside vaults/, so nothing swamp runs can name it."
type: adr
category: security
tags:
  - break-glass
  - sops
  - credentials
status: superseded
created: 2026-09-29
updated: 2026-09-30
author: dataverket
project: plattform
related:
  - 001-credential-tiers.md
  - 016-operator-values-live-in-vaults-operator.md
---
# 004: Human-only material stays outside swamp's reach

## Status

Superseded by 016 on 2026-09-30: `break-glass/` is now `vaults/operator/break-glass/`.

## Context

Some material may only ever be read by a person: break-glass configs, recovery codes, anything that opens a door
when the usual way in is gone. The obvious home is a second swamp vault with only the operators' YubiKeys as
recipients. But a vault is a thing a model definition can name, and `vault.get("human", ...)` is a line someone
could write.

## Decision

`break-glass/` is plain sops, outside `vaults/`, encrypted to the two operators' YubiKeys and to nothing else. It
is not a swamp vault and has no vault config, so nothing swamp runs can name it at all. Its rule comes first in
`.sops.yaml`, because sops takes the first match and the general `vaults/` rule would otherwise add
`swamp-fabrikk-infra` to a human-only file.

Two rules bound what may go in it, and they hold for any store of this kind:

1. Nothing here may complete a routine login. If the everyday way into a service could be rebuilt from this
   repository plus a touch, tier 1 would be reconstructible without the mechanism it rests on.
2. Nothing here may be needed to recover what hosts it. The forge's own break-glass belongs somewhere that does
   not depend on the forge being up.

## Consequences

- Encryption needs only public keys, so a workflow may still write there. Only a touch reads.
- The store is empty until `docs/plans/2026-09-break-glass.md` fills it.
- Being unreachable by swamp is structural, not a matter of recipients, so it survives someone adding a recipient
  by mistake.

## Decision Outcome

Human-only material cannot be reached by anything this repository automates, whatever recipients a file
later gains. The property is structural rather than a matter of care.

## Related Decisions

Follows 001.

## Audit

### 2026-09-29

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| `break-glass/` created outside `vaults/` | `break-glass/` | done |
| Its rule is first in `.sops.yaml` | `.sops.yaml` | done |
| No swamp vault names it | `swamp vault list` | verified |

**Summary:** Applied 2026-09-29. The store is empty: what fills it is `docs/plans/2026-09-break-glass.md`.

**Action Required:** Fill it when the break-glass plan runs.

### 2026-09-30

**Status:** Superseded

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| `break-glass/` moved to `vaults/operator/break-glass/` | 016 | done |
| The two rules on what may go in it | `vaults/operator/break-glass/README.md` | unchanged |

**Summary:** 016 puts every sops store under `vaults/` and sets readers by recipients alone. The structural
property this record chose, that swamp cannot name the store, is given up for one layout.

**Action Required:** None here; see 016.
