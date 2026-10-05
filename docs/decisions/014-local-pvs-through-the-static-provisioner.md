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
updated: 2026-10-05
author: dataverket
project: plattform
---
# 014: Talos leaves room on the system disk, and the static provisioner turns it into PVs

## Status

Accepted. The EPHEMERAL figure of 16 GiB is superseded by 019 on 2026-10-01: 14 GiB on the workers. The naming
rule, one partition per workload behind `<name>-storage`, is superseded by 025 on 2026-10-05: a slot named by tier,
under `local-fast`.

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

### 2026-10-01

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| EPHEMERAL capped, user volumes carved | `talos/dataverket-prod/workers-storage.yaml` | done: EPHEMERAL 14 GiB, not 16, and `u-pg-zitadel` 11 GiB on every worker (019) |
| Mounts published as `local` PVs | `infrastructure/local-static-provisioner/` | done: three PVs of `pg-zitadel-storage`, all bound by Zitadel's database |
| No init container for ownership | `zitadel-db` pods | done: the kubelet sets group 26 on the mount, which is what "chowns" means here; the owner stays root |

**Summary:** Applied 2026-10-01 with the worker swaps (017) and the provisioner; the layout is `docs/storage.md`. The EPHEMERAL figure is 019's.

**Action Required:** None.

### 2026-09-30

**Status:** Not implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| EPHEMERAL capped, user volumes carved | Talos machine config | not done: `fleet-volumes` shows EPHEMERAL on the whole disk (21,495 and 26,615 MiB) and no `u-` partitions |
| Mounts published as `local` PVs | `infrastructure/` | not done: no provisioner in `infrastructure/` |

**Summary:** The audit of 2026-09-29 was wrong. The mechanism arrives with the replaced workers (017) and the
provisioner.

**Action Required:** Replace the workers and install the provisioner.

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
