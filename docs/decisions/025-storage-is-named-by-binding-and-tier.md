---
title: "Storage is named by binding and tier, on every kind of node"
description: "Four classes, fast, large, local-fast and local-large, mean the same on cloud, Incus and bare metal; Talos names a slot by tier and number, never by workload; volumeMode on the claim picks filesystem or block; a disk Talos does not name stays raw for Ceph."
type: adr
category: data
tags:
  - talos
  - storage
  - kubernetes
  - kata
  - rook
status: accepted
created: 2026-10-05
updated: 2026-10-05
author: dataverket
project: plattform
related:
  - 014-local-pvs-through-the-static-provisioner.md
  - 017-workers-are-replaced-never-changed-in-place.md
  - 018-one-redundancy-layer-per-kind-of-data.md
  - 019-ephemeral-is-a-fixed-14-gib-on-the-workers.md
---
# 025: Storage is named by binding and tier, on every kind of node

## Status

Accepted. Supersedes 014's naming rule, one partition per workload behind a class named `<name>-storage`; the rest
of 014 stands. Applied at the next worker replacement.

## Context

014 lays out one user volume per workload on each worker's system disk, named after the workload, `pg-zitadel`,
and publishes it behind a class of the same name. Talos applies a volume's config only while the volume is
unprovisioned, so a rename is a removal, a wipe and a new volume, and 017 makes it cost a replacement. A workload
is a runtime thing; the install-time layer was carrying its name. The class name did one job, though: a static
local PV is matched by class and size only, so the name was the reservation that kept a worker's one slot for
Zitadel's database.

The workers will not stay cloud machines with one disk. The same manifests have to run on virtual machines on
Incus, whose disks are RBD images Incus attaches, and on bare metal with NVMe and HDD side by side, where Rook
should find raw disks. Kata pods need a block device, not a mounted filesystem, from both local and attached
storage. Today's class names, `csi-cinder-sc-delete`, `csi-cinder-standard-retain`, `pg-zitadel-storage`, say
which driver and which workload, and would differ on every site.

## Decision

A workload names storage by binding and tier, and nothing else. The explainer, with diagrams, is
`docs/node-storage.md`.

- **Four classes on every site:** `fast` and `large` are attached, made on demand by the site's CSI driver and
  following the pod; `local-fast` and `local-large` are slots on a node's own disk, for the node's life. The tier
  is a Cinder volume type at osl1, an Incus pool on an Incus site, a Ceph pool over a CRUSH device class on bare
  metal. A site serves the tiers it has.
- **Talos names a slot by tier and number.** `fast-0`, `large-0`, laid out with size stated (019) and a disk
  selector that names the disk, never the workload: the kind, `system_disk`, `disk.transport == 'nvme'`,
  `disk.rotational`, where disks are never swapped, and the bay, a `/dev/disk/by-path` link in
  `disk.symlinks`, where they are. Rook selects by bay too. No Talos volume is named after a workload. The static
  provisioner publishes `fast-*` as `local-fast` and `large-*` as `local-large`.
- **Form follows volumeMode.** A filesystem slot is a `UserVolumeConfig` with xfs, published `Filesystem`. A block
  slot, `fast-block-0`, is a `RawVolumeConfig` published `Block` from its link under `/dev/disk/by-partlabel`, in a
  class of its own, `local-fast-block`, because the provisioner reads one directory in one mode per class. Attached
  classes serve both modes from one class. Kata claims `Block`.
- **A reservation is made at runtime.** When two workloads share a local class, the PV meant for one carries the
  label `dataverket.org/reserved-for: <workload>` and that workload's claim a selector on it. Setting it on a new
  worker's PVs is a step of the replacement procedure.
- **Reclaim is `Retain` everywhere.** Deleting a claim never deletes data; a person deletes the PV.
- **A disk Talos does not name stays raw.** On bare metal Rook takes it by name or filter, one set per CephCluster;
  its device classes make the pools the attached classes are named after.

## Consequences

- The rename rides on the next worker replacement (017): the Talos patch, the join workflow's default volume name,
  the provisioner's classes, the StorageClasses, and the CNPG cluster's class, which CNPG applies one instance at a
  time. The two Cinder classes become `fast` and `large`; each claim moves when its workload is next touched.
- A claim for a tier a site lacks stays Pending and says so, which is the intended behaviour.
- The replacement procedure gains a labelling step the day a second workload shares a local class.
- A replaced slot disk comes back empty at the same path and under the same PV name, so it is handled like a
  replaced node for the claims on it: destroy the instance, delete the PV, let the slot republish, rejoin. A
  swapped Ceph disk changes nothing in git; a reused one is wiped with `talosctl wipe disk` first.
- Two static classes over one directory need distinct container paths in the provisioner's configuration, and a
  Block class's path must sit at `/dev/disk/<name>`; both found on the lab run of 2026-10-05
  (`docs/research/2026-10-node-storage-lab.md`).

## Decision Outcome

A workload's manifest asks for `fast` or `local-fast` and runs unchanged on a cloud worker, an Incus VM and a
bare-metal server; a machine's disk layout says nothing about what runs on it; and a data disk reaches Ceph
untouched.

## Related Decisions

Local PVs through the static provisioner (014), whose mechanism stands; workers are replaced, never changed (017),
which is when this lands; one redundancy layer per kind of data (018); sizes stated on a shared disk (019).

## Audit

### 2026-10-05

**Status:** Not implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Slots named by tier and number | `talos/dataverket-prod/workers-storage.yaml` | not done: `pg-zitadel` on all three workers |
| Classes `local-fast`, `fast`, `large` | `infrastructure/local-static-provisioner/`, `infrastructure/cinder-csi-provider/` | not done: `pg-zitadel-storage` and the two Cinder names |
| Block slots for Kata | nowhere | not done: the runner store is a Cinder Block claim, which stays valid; the mechanism passed on the lab cluster |
| Reservation by label | the PVs | not needed: one workload uses the class |
| Raw disks left to Rook | bare-metal nodes | no such node yet |

**Summary:** Decided with the explainer and run on a lab cluster the same day, every check passing
(`docs/research/2026-10-node-storage-lab.md`); lands with the next worker replacement.

**Action Required:** Apply the changes in Consequences in one swap cycle.
