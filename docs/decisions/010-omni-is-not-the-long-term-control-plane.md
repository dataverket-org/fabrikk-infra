---
title: "Omni is not the long-term control plane"
description: "Omni is a single point of failure and not part of future designs, so the replacement starts now."
type: adr
category: architecture
tags:
  - omni
  - talos
  - break-glass
  - sovereignty
status: accepted
created: 2026-09-29
updated: 2026-09-29
author: dataverket
project: plattform
related:
  - 001-credential-tiers.md
  - 004-human-only-material-stays-outside-swamp.md
---
# 010: Omni is not the long-term control plane

## Status

Accepted

## Context

Every administrative path into `dataverket-prod` runs through Omni: the kubeconfig and the talosconfig are
Omni-proxied, both service account keys are minted by it, and the login behind all of it is an Omni browser login.
The nodes carry only private addresses and a SideroLink address on Omni's own overlay, so there is no route to
them that Omni is not part of. Omni is a single point of failure for administrative access, and 001 sharpened that
by removing the long-lived Operator key from the vault.

## Decision

Omni is not part of future designs. Dataverket will build its own, and the work that has to exist either way
starts now rather than after: a route to the machines that we own, and an administrative credential that depends
on nobody. That is `docs/plans/2026-09-break-glass.md`, a WireGuard interface in the Talos machine config and an
`os:admin` talosconfig signed from the cluster's own CA.

Sidero's own break-glass is enabled per account on request and is not being pursued, because it leaves the last
resort in someone else's hands.

## Consequences

- A replacement must mint credentials with a lifetime on the authority of a human login. If it cannot, tier 2
  falls back to permanent keys and 001 loses its compensating control. That is the first requirement to settle,
  before the replacement is designed. 015 is where Dataverket first meets it, for Kubernetes.
- Using an `os:admin` certificate taints the cluster until the Talos CA is rotated, which invalidates the stored
  talosconfig and obliges a re-mint. The obligation lasts only as long as Omni manages the cluster.
- A second way in is a standing risk taken against a hypothetical outage. While Omni is still here, that is a real
  cost and the plan states it.

## Decision Outcome

Work that has to exist after Omni either way is started while Omni is still here to build it with.

## Related Decisions

Follows 001.

## Audit

### 2026-09-29

**Status:** Pending

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Route and credential designed | `docs/plans/2026-09-break-glass.md` | written |
| WireGuard overlay | - | not built |
| `os:admin` talosconfig | `vaults/operator/break-glass/` | not minted |

**Summary:** Decision recorded 2026-09-29. Nothing is built: Omni remains the only administrative path into the
cluster.

**Action Required:** Run the break-glass plan. Settle first whether a replacement can mint credentials with a
lifetime on the authority of a human login, which is what tier 2 depends on.
