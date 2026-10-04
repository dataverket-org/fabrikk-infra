---
title: "Workers are replaced, never changed in place"
description: "A worker's placement and disk layout arrive with a new machine; the old one is retired, not reconfigured."
type: adr
category: infrastructure
tags:
  - talos
  - openstack
  - workers
status: accepted
created: 2026-10-01
updated: 2026-10-01
author: dataverket
project: plattform
related:
  - 010-omni-is-not-the-long-term-control-plane.md
  - 014-local-pvs-through-the-static-provisioner.md
  - 019-ephemeral-is-a-fixed-14-gib-on-the-workers.md
---
# 017: Workers are replaced, never changed in place

## Status

Accepted.

## Context

Two properties of a worker are fixed when it is made. Nova honours a server group only at boot and has no call that
adds a running server to one, so placement on distinct hypervisors cannot be given to a worker that exists. Talos
sizes EPHEMERAL and provisions user volumes only when it first provisions a disk, so a layout cannot be given to a
disk that is laid out. A worker that is changed in place either does not get them or gets them by a path nobody has
tried.

## Decision

A worker is changed by replacing it. A new machine is created in the anti-affinity server group
`dataverket-prod-workers`, with the storage patch from `talos/dataverket-prod/workers-storage.yaml`, and joins; the
old one is drained, removed and deleted after it. Never fewer than three workers in the cluster, new machine first,
old machine last.

Today the two halves are the swamp workflows `worker-join` and `worker-retire`, which run through Omni. The rule
does not depend on Omni: when the workers move off it (010), the same two halves run on talosctl and OpenStack.

## Consequences

- Changing the flavor, the disk layout or anything else Talos fixes at provisioning is three swaps, one per worker.
- Placement is declared, not observed: a worker that cannot be placed on its own hypervisor fails to boot, which is
  a conversation with the provider before a `soft-anti-affinity` retreat.
- A worker holding a replica on its own disk (018) cannot hand it over. Retiring it also runs "Replacing a worker"
  in `docs/storage.md`: the replica is destroyed and CNPG joins a new one on the new worker.
- Nothing is reset in place, so no rehearsal cluster is needed for a swap: every swap is the path the workers took
  when they were made.

## Decision Outcome

Three workers on three hypervisors, each with the layout the patch states, reached on 2026-10-01 by three swaps.

## Related Decisions

The disk layout it carries is 014 and 019. The tools that run it change with 010.

## Audit

### 2026-10-01

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Three workers in `dataverket-prod-workers`, three distinct `hostId`s | `openstack-server` | done |
| The storage patch on the workers machine set | `omni-cluster`, id `500-workers-storage` | done |
| Both halves as workflows | `workflows/workflow-worker-join.yaml`, `workflow-worker-retire.yaml` | done, each run end to end |

**Summary:** Swaps 1 to 3 of the storage plan's step 4.

**Action Required:** None.
