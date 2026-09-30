---
title: "Talos leaves room on the system disk, and the static provisioner turns it into PVs"
description: "EPHEMERAL is capped so user volumes fit on the system disk, published as local PVs."
type: adr
category: data
tags:
  - talos
  - storage
  - kubernetes
  - cinder
status: accepted
created: 2026-09-19
updated: 2026-09-30
author: dataverket
project: plattform
---
# 014: Talos leaves room on the system disk, and the static provisioner turns it into PVs

## Status

Accepted

## Context

Every node has one disk. By default Talos gives all of it to EPHEMERAL, and the only way to get storage for
workloads is a Cinder volume per claim. Talos can carve user volumes out of the system disk, but only from space
EPHEMERAL has not taken, and Kubernetes has to be shown those partitions as PersistentVolumes.

## Decision

Talos does not get the whole disk. EPHEMERAL is capped, 16 GiB on the cloud workers and 32 GiB at most anywhere,
and the rest is for `UserVolumeConfig` partitions, one per workload, mounted under `/var/mnt/<name>`. The
`sig-storage-local-static-provisioner` publishes each mount as a `local` PV behind a StorageClass named
`<name>-storage`.

`local` and not `hostPath`, because the kubelet chowns a `local` PV for the pod's `fsGroup`, so non-root databases
need no init container.

## Consequences

- A PV lives on one node. What uses it replicates itself across nodes (CNPG) or is disposable.
- Growing a volume means a new partition or a Cinder volume, not a bigger flavor.
- Anything that needs snapshots, clones or shared access is a CSI question, and Cinder stays installed for it.

## Decision Outcome

Storage for a workload costs a partition rather than a Cinder volume, and a non-root database needs no
init container to own its directory.

## Audit

### 2026-09-30

**Status:** Not implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| EPHEMERAL capped, user volumes carved | Talos machine config | not done: `fleet-volumes` shows EPHEMERAL on the whole disk (21,495 and 26,615 MiB) and no `u-` partitions |
| Mounts published as `local` PVs | `infrastructure/` | not done: no provisioner in `infrastructure/` |

**Summary:** The audit of 2026-09-29 was wrong. The mechanism arrives with the replaced workers, steps 4 and 5 of
`docs/plans/2026-09-storage-building-blocks.md`.

**Action Required:** Steps 4 and 5 of the storage plan.

### 2026-09-29

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| EPHEMERAL capped, user volumes carved | Talos machine config | done |
| Mounts published as `local` PVs | `infrastructure/` | done |

**Summary:** In place since 2026-09-19. `swamp model method run dataverket-prod-talos volumes` reports each node's
layout.

**Action Required:** None.
