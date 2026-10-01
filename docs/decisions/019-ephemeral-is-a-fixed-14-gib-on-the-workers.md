---
title: "EPHEMERAL is a fixed 14 GiB on the workers"
description: "Volume sizes on a shared system disk are stated with minSize equal to maxSize; 14 GiB EPHEMERAL on m5.large workers, 32 GiB at most anywhere."
type: adr
category: data
tags:
  - talos
  - storage
status: accepted
created: 2026-10-01
updated: 2026-10-01
author: dataverket
project: plattform
related:
  - 014-local-pvs-through-the-static-provisioner.md
  - 017-workers-are-replaced-never-changed-in-place.md
---
# 019: EPHEMERAL is a fixed 14 GiB on the workers

## Status

Accepted. Supersedes 014's figure of 16 GiB for the cloud workers; the rest of 014 stands.

## Context

014 capped EPHEMERAL at 16 GiB so user volumes fit beside it. Provisioning the first new worker on 2026-10-01 showed
three things 014 did not know. Only 26,615 MiB of a 30 GiB `m5.large` disk is free for volumes after the Talos
partitions and the space Talos leaves unallocated, so 16 GiB and an 11 GiB user volume do not fit. Talos creates a
partition as large as `maxSize` allows, the whole free disk without one, and `grow` only decides later growth. And
Talos does not promise which volume it lays out first: `pg-zitadel` went first all three times.

## Decision

On a disk that EPHEMERAL shares with user volumes, every volume states its size with `minSize` equal to `maxSize`.

| Node | EPHEMERAL | User volumes |
|---|---|---|
| `m5.large` worker, 30 GiB disk | 14 GiB | `u-pg-zitadel` 11 GiB |
| Anything else | 32 GiB at most | as the node's role needs |

The patch is `talos/dataverket-prod/workers-storage.yaml`, on the workers machine set.

## Consequences

- At 14 GiB the busiest worker measured before the change would sit at 60 percent, with image collection from 80;
  the kubelet thresholds in the same patch turn that into a budget.
- About 1 GiB of the disk is left unused, the price of stating sizes rather than letting one volume take the rest.
- Changing a size is three swaps (017): a laid-out disk keeps its layout.
- On a node with a data disk beside its system disk, user volumes go on that disk and may grow, since nothing
  shares it.

## Decision Outcome

Every worker has EPHEMERAL at 14,336 MiB and `u-pg-zitadel` at 11 GiB, whichever Talos laid out first.

## Related Decisions

Supersedes 014's EPHEMERAL figure. Applied through 017.

## Audit

### 2026-10-01

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| EPHEMERAL 14 GiB and `u-pg-zitadel` 11 GiB, `minSize` equal to `maxSize` | `talos/dataverket-prod/workers-storage.yaml` | done |
| The layout on every worker | `worker-join`'s layout check, `fleet-volumes` | done on wrkr-4, wrkr-5, wrkr-6 |

**Summary:** Found and fixed during swap 1 of the storage plan's step 4.

**Action Required:** None.
