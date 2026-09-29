---
title: "Credentials are held in three tiers"
description: "A credential's tier follows from whether it is minted and expiring, not from how much it can do."
type: adr
category: security
tags:
  - credentials
  - tiers
  - sops
  - omni
status: accepted
created: 2026-09-29
updated: 2026-09-29
author: dataverket
project: plattform
related:
  - 002-two-sops-stores-one-reader-each.md
  - 004-human-only-material-stays-outside-swamp.md
---
# 001: Credentials are held in three tiers

## Status

Accepted

## Context

Three kinds of consumer read secrets here: a human operator, swamp and the agents that drive it on the swamp host,
and Flux in the cluster. With no rule for what may live where, credentials landed wherever was convenient: a
year-long Omni key in the vault that could mint cluster admin, a hand-made kubeconfig that never expired, model
definitions reaching into the vault on every run.

## Decision

A credential's tier follows from whether it is minted and expiring, not from how much it can do.

| Tier | What | Lifetime |
|---|---|---|
| 1 | What processes hold: the swamp vault, the Flux files, the cluster's live Secrets | Permanent |
| 2 | What the CLIs read by name: kube and talos contexts, a `clouds.yaml` entry, service account key files | Minted, always expiring |
| 3 | How a human turns their own login into tier 2. No credentials of its own, only mechanisms | The working day |

Five invariants follow:

1. A tier 3 secret is never on disk. A value may live in this repository only if reading it requires one of the
   mechanisms; a reference to where a value lives may always.
2. Tier 2 always expires. Anything permanent is tier 1 with a named human owner instead.
3. Tier 2 never enters the swamp vault, which would put the key to tier 1 inside tier 1.
4. Agents reach tier 2 by using it, never by reading the value.
5. Tier 1 is read by machines. A human reaches it through a tier 2 credential or a YubiKey.

## Consequences

- Both Omni service account keys left the vault; they are minted per session instead.
- Model definitions name a context or a file, never a value.
- Unattended work is read-only until a machine identity exists under `swamp serve`. No nightly job may change a
  cluster.
- The cluster's `system:masters` kubeconfig is tier 2. The Talos PKI behind it is tier 1 with a human owner.
- Steps and status: `docs/plans/2026-09-credential-tiers.md`. The request model that generalises tier 3:
  `docs/plans/2026-09-access-requests.md`.

## Decision Outcome

Every credential in the repository now has one answer to "where does this live and how long does it last".
A reviewer can tell a tier 2 file from a tier 1 value by looking at it, and a definition that carries a value is
visibly wrong rather than merely unusual.

## Related Decisions

Governs 002, 003, 004, 009, 010.

## Audit

### 2026-09-29

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Both Omni keys removed from the vault | `vaults/infra/omni/` | done |
| Definitions name a context or a key file | `models/@dataverket/` | done |
| No vault read during a model run | `swamp vault audit-trail --action get` | verified |

**Summary:** Applied 2026-09-29. `omni discover` and `dataverket-prod-talos version` both ran with the audit trail
recording no vault read at all.

**Action Required:** None. The request model in `docs/plans/2026-09-access-requests.md` generalises tier 3 when it
is written.
